# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for tools/stk2rbx XML parsing, mesh inspection, coords, and Rojo emission."""

from __future__ import annotations

import json
import math
import struct
import tempfile
import unittest
from pathlib import Path

from unittest.mock import patch

from tools.stk2rbx.cli import _svn_assets_url, convert_track, main as cli_main
from tools.stk2rbx.coords import (
    STUDS_PER_METER,
    flip_triangle_winding,
    quad_to_rbx_transform,
    stk_heading_to_rbx_matrix,
    stk_hpr_to_rbx_matrix,
    stk_to_rbx_normal,
    stk_to_rbx_pos,
    stk_to_rbx_size,
)
from tools.stk2rbx.mesh_inspect import audit_mesh
from tools.stk2rbx.road_probe import RoadPatch, extract_contiguous_road_patch, write_glb
from tools.stk2rbx.xml_parser import (
    parse_graph_and_quads,
    parse_materials_xml,
    parse_scene_xml,
    parse_track_xml,
)


def _mat3_det(m: list[list[float]]) -> float:
    return (
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    )


def _mat3_mul_vec(m: list[list[float]], v: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    )


def _irr_rotate_vect_ref(
    rot_deg: tuple[float, float, float], v: tuple[float, float, float]
) -> tuple[float, float, float]:
    """Direct transcription of Irrlicht CMatrix4::setRotationRadians + rotateVect
    (lib/irrlicht/include/matrix4.h:L828-L855, L1104-L1110).
    """
    rx, ry, rz = (math.radians(a) for a in rot_deg)
    cr, sr = math.cos(rx), math.sin(rx)
    cp, sp = math.cos(ry), math.sin(ry)
    cy, sy = math.cos(rz), math.sin(rz)
    m0, m1, m2 = cp * cy, cp * sy, -sp
    m4, m5, m6 = sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp
    m8, m9, m10 = cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp
    return (
        v[0] * m0 + v[1] * m4 + v[2] * m8,
        v[0] * m1 + v[1] * m5 + v[2] * m9,
        v[0] * m2 + v[1] * m6 + v[2] * m10,
    )


def _write_synthetic_spm(
    path: Path,
    num_verts: int,
    num_tris: int,
    skinned: bool = False,
    bounds_m: tuple[float, float, float] = (10.0, 2.0, 10.0),
) -> None:
    """Build a valid STK .spm (SPMN or SPMA) binary mesh for testing."""
    buf = bytearray()
    buf.extend(b"SP")
    header_byte = (1 << 3) | (1 if skinned else 2)
    buf.append(header_byte)
    buf.append(0x07)  # normal + vcolor + tangent
    buf.extend(struct.pack("<6f", 0.0, 0.0, 0.0, *bounds_m))
    buf.extend(struct.pack("<H", 1))  # 1 material
    tex = b"sand.png"
    buf.append(len(tex))
    buf.extend(tex)
    buf.append(0)  # no tex2

    buf.extend(struct.pack("<H", 1))  # 1 sector
    buf.extend(struct.pack("<H", 1))  # 1 submesh
    indices_count = num_tris * 3
    buf.extend(struct.pack("<IIH", num_verts, indices_count, 0))

    for i in range(num_verts):
        px = bounds_m[0] if i % 2 == 1 else 0.0
        py = bounds_m[1] if i == 1 else 0.0
        pz = bounds_m[2] if i == 2 else 0.0
        buf.extend(struct.pack("<fff", px, py, pz))
        buf.extend(struct.pack("<I", 0x1FF << 10))  # packed normal
        if i % 2 == 0:
            buf.append(128)  # white vcolor shorthand (1 byte)
        else:
            buf.extend(bytes([255, 200, 100, 50]))  # ci + rgb (4 bytes)
        buf.extend(struct.pack("<I", 0))  # uv1
        buf.extend(struct.pack("<I", 0))  # tangent
        if skinned:
            buf.extend(struct.pack("<4h4H", 0, -1, -1, -1, 15360, 0, 0, 0))

    idx_fmt = "<3H" if num_verts > 255 else "<3B"
    for t in range(num_tris):
        i0 = t % num_verts
        i1 = (t + 1) % num_verts
        i2 = (t + 2) % num_verts
        buf.extend(struct.pack(idx_fmt, i0, i1, i2))

    path.write_bytes(bytes(buf))


def _write_synthetic_b3d(path: Path, num_verts: int, num_tris: int) -> None:
    """Build a minimal Blitz3D .b3d mesh."""
    vrts_payload = bytearray(struct.pack("<iii", 1, 1, 2))  # normal + 1 uv2d
    for i in range(num_verts):
        vrts_payload.extend(struct.pack("<8f", float(i), 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0))
    vrts_chunk = b"VRTS" + struct.pack("<I", len(vrts_payload)) + vrts_payload

    tris_payload = bytearray(struct.pack("<i", 0))
    for t in range(num_tris):
        tris_payload.extend(struct.pack("<3i", t % num_verts, (t + 1) % num_verts, (t + 2) % num_verts))
    tris_chunk = b"TRIS" + struct.pack("<I", len(tris_payload)) + tris_payload

    mesh_payload = struct.pack("<i", 0) + vrts_chunk + tris_chunk
    mesh_chunk = b"MESH" + struct.pack("<I", len(mesh_payload)) + mesh_payload

    node_payload = b"root\x00" + struct.pack("<10f", 0, 0, 0, 1, 1, 1, 1, 0, 0, 0) + mesh_chunk
    node_chunk = b"NODE" + struct.pack("<I", len(node_payload)) + node_payload

    texs_payload = b"track.png\x00" + struct.pack("<ii5f", 1, 2, 0, 0, 1, 1, 0)
    texs_chunk = b"TEXS" + struct.pack("<I", len(texs_payload)) + texs_payload

    brus_payload = struct.pack("<i", 1) + b"mat\x00" + struct.pack("<5f3i", 1, 1, 1, 1, 0, 1, 0, 0)
    brus_chunk = b"BRUS" + struct.pack("<I", len(brus_payload)) + brus_payload

    body = struct.pack("<i", 1) + texs_chunk + brus_chunk + node_chunk
    path.write_bytes(b"BB3D" + struct.pack("<I", len(body)) + body)


class TestStk2Rbx(unittest.TestCase):
    def test_coords_and_orientation(self) -> None:
        pos = stk_to_rbx_pos(1.0, 2.0, 10.0)
        self.assertEqual(pos, [1.0, 2.0, -10.0])

        clamped, raw, exceeds = stk_to_rbx_size(2500.0, 1.0, 2.0)
        self.assertTrue(exceeds)
        self.assertAlmostEqual(raw[0], 2500.0 * STUDS_PER_METER, places=2)
        self.assertEqual(clamped[0], 2048.0)

        mat = stk_hpr_to_rbx_matrix(45.0, 15.0, -10.0)
        self.assertAlmostEqual(_mat3_det(mat), 1.0, places=5)

        # Verify S * R_irr * S equivalence for asymmetric Irrlicht XYZ rotations
        for hpr in [(30.0, 45.0, -20.0), (-90.0, 131.4, 5.7)]:
            r_rbx = stk_hpr_to_rbx_matrix(*hpr)
            self.assertAlmostEqual(_mat3_det(r_rbx), 1.0, places=5)
            v_stk = (0.3, -0.7, 1.2)
            v_rot_stk = _irr_rotate_vect_ref(hpr, v_stk)
            expected_rbx = (v_rot_stk[0], v_rot_stk[1], -v_rot_stk[2])
            actual_rbx = _mat3_mul_vec(r_rbx, (v_stk[0], v_stk[1], -v_stk[2]))
            for a, b in zip(actual_rbx, expected_rbx):
                self.assertAlmostEqual(a, b, places=5)

        # Verify <start h="90"/> rotates Roblox forward (0, 0, -1) to (+1, 0, 0)
        h90 = stk_heading_to_rbx_matrix(90.0)
        self.assertAlmostEqual(_mat3_det(h90), 1.0, places=5)
        fwd90 = _mat3_mul_vec(h90, (0.0, 0.0, -1.0))
        self.assertAlmostEqual(fwd90[0], 1.0, places=5)
        self.assertAlmostEqual(fwd90[1], 0.0, places=5)
        self.assertAlmostEqual(fwd90[2], 0.0, places=5)

        qpos, qmat, qsize = quad_to_rbx_transform(
            (-2.0, 0.0, 0.0),
            (2.0, 0.0, 0.0),
            (2.0, 0.0, 4.0),
            (-2.0, 0.0, 4.0),
        )
        self.assertAlmostEqual(_mat3_det(qmat), 1.0, places=5)
        self.assertAlmostEqual(qpos[2], -2.0 * STUDS_PER_METER, places=2)
        self.assertEqual(qsize[1], 0.5)

        # LookVector (-col2) must align with Quad 0 -> Quad 1 direction
        pos0, mat0, _ = quad_to_rbx_transform((-2.0, 0.0, 0.0), (2.0, 0.0, 0.0), (2.0, 0.0, 4.0), (-2.0, 0.0, 4.0))
        pos1, _, _ = quad_to_rbx_transform((-2.0, 0.0, 4.0), (2.0, 0.0, 4.0), (2.0, 0.0, 8.0), (-2.0, 0.0, 8.0))
        look0 = (-mat0[0][2], -mat0[1][2], -mat0[2][2])
        step01 = (pos1[0] - pos0[0], pos1[1] - pos0[1], pos1[2] - pos0[2])
        self.assertGreater(look0[0] * step01[0] + look0[1] * step01[1] + look0[2] * step01[2], 0.0)

    def test_winding_flip_and_normal_transform(self) -> None:
        # Triangle in STK (+X right, +Y up, +Z forward) whose (p1-p0)x(p2-p0) points +Y
        verts_stk = [(0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.0, 0.0, 0.0)]
        n_stk = (0.0, 1.0, 0.0)
        indices = [0, 1, 2]

        def face_normal(vs: list[tuple[float, float, float]], idx: list[int]) -> tuple[float, float, float]:
            a, b, c = vs[idx[0]], vs[idx[1]], vs[idx[2]]
            e1 = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
            e2 = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
            return (
                e1[1] * e2[2] - e1[2] * e2[1],
                e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0],
            )

        n_raw = face_normal(verts_stk, indices)
        self.assertGreater(n_raw[0] * n_stk[0] + n_raw[1] * n_stk[1] + n_raw[2] * n_stk[2], 0.0)

        verts_rbx = [(x, y, -z) for (x, y, z) in verts_stk]
        n_rbx = stk_to_rbx_normal(*n_stk)

        # Without flipping winding, Z-reflection turns outward normal inward!
        unflipped = face_normal(verts_rbx, indices)
        self.assertLess(unflipped[0] * n_rbx[0] + unflipped[1] * n_rbx[1] + unflipped[2] * n_rbx[2], 0.0)

        # With flip_triangle_winding, face normal aligns with transformed vertex normal
        flipped_indices = flip_triangle_winding(indices)
        self.assertEqual(flipped_indices, [0, 2, 1])
        flipped = face_normal(verts_rbx, flipped_indices)
        self.assertGreater(flipped[0] * n_rbx[0] + flipped[1] * n_rbx[1] + flipped[2] * n_rbx[2], 0.0)

    def test_upstream_graph_and_item_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp)
            # Graph with two paths from 0 -> 3: 0->1->3 (10m) vs 0->2->3 (18m)
            (tdir / "quads.xml").write_text(
                "<quads>"
                '<quad p0="-1 0 0" p1="1 0 0" p2="1 0 2" p3="-1 0 2"/>'
                '<quad p0="-1 0 5" p1="1 0 5" p2="1 0 7" p3="-1 0 7"/>'
                '<quad p0="9 0 9" p1="11 0 9" p2="11 0 11" p3="9 0 11"/>'
                '<quad p0="-1 0 10" p1="1 0 10" p2="1 0 12" p3="-1 0 12"/>'
                "</quads>",
                encoding="utf-8",
            )
            (tdir / "graph.xml").write_text(
                "<graph>"
                '<edge from="0" to="1"/><edge from="1" to="3"/>'
                '<edge from="0" to="2"/><edge from="2" to="3"/>'
                '<edge from="3" to="0"/>'
                "</graph>",
                encoding="utf-8",
            )
            (tdir / "scene.xml").write_text('<scene><item x="0" y="5" z="0"/></scene>', encoding="utf-8")

            graph = parse_graph_and_quads(tdir / "quads.xml", tdir / "graph.xml")
            self.assertEqual(graph.min_height_testing, -1.0)
            self.assertEqual(graph.max_height_testing, 5.0)
            expected_long = math.hypot(10.0, 9.0) + math.hypot(10.0, 1.0)
            self.assertAlmostEqual(graph.quads[3].distance_from_start, expected_long, places=4)

            scene = parse_scene_xml(tdir / "scene.xml")
            self.assertTrue(scene.items[0].drop)

    @unittest.skipUnless(
        Path(r"C:\dev\stk-assets\tracks\sandtrack").exists(),
        "sandtrack upstream assets not fetched",
    )
    def test_sandtrack_driveline_forward_direction(self) -> None:
        sdir = Path(r"C:\dev\stk-assets\tracks\sandtrack")
        graph = parse_graph_and_quads(sdir / "quads.xml", sdir / "graph.xml")
        self.assertEqual(len(graph.quads), 303)
        for q in graph.quads:
            pos, mat, _ = quad_to_rbx_transform(*q.points)
            nxt = graph.quads[q.successors[0]]
            npos, _, _ = quad_to_rbx_transform(*nxt.points)
            look = (-mat[0][2], -mat[1][2], -mat[2][2])
            step = (npos[0] - pos[0], npos[1] - pos[1], npos[2] - pos[2])
            dot = look[0] * step[0] + look[1] * step[1] + look[2] * step[2]
            self.assertGreater(dot, 0.0, f"Quad_{q.index:03d} LookVector opposed successor step")

    @unittest.skipUnless(
        Path(r"C:\dev\stk-assets\tracks\sandtrack\sandtrack_track.spm").exists(),
        "sandtrack_track.spm upstream asset not fetched",
    )
    def test_sandtrack_spm_winding_audit(self) -> None:
        spm_path = Path(r"C:\dev\stk-assets\tracks\sandtrack\sandtrack_track.spm")
        data = spm_path.read_bytes()
        off = 4
        flags = data[3]
        read_normal = bool(flags & 1)
        read_vcolor = bool(flags & 2)
        read_tangent = bool(flags & 4)
        self.assertTrue(read_normal)
        off += 24
        mat_count = struct.unpack_from("<H", data, off)[0]
        off += 2
        mats: list[tuple[str, str]] = []
        for _ in range(mat_count):
            l1 = data[off]
            off += 1
            t1 = data[off : off + l1].decode("utf-8", errors="replace")
            off += l1
            l2 = data[off]
            off += 1
            t2 = data[off : off + l2].decode("utf-8", errors="replace")
            off += l2
            mats.append((t1, t2))
        sec_count = struct.unpack_from("<H", data, off)[0]
        off += 2
        self.assertEqual(sec_count, 1)
        sub_count = struct.unpack_from("<H", data, off)[0]
        off += 2

        def _s10(v: int) -> float:
            v &= 0x3FF
            return (v - 1024) / 511.0 if v >= 512 else v / 511.0

        all_three_verts_opposed = 0
        non_degenerate_zero_dot = 0
        road_non_deg_neg = 0

        for _ in range(sub_count):
            vc, ic, mid = struct.unpack_from("<IIH", data, off)
            off += 10
            tex = mats[mid][0]
            uv1, uv2 = len(mats[mid][0]) > 0, len(mats[mid][1]) > 0
            vs: list[tuple[float, float, float]] = []
            ns: list[tuple[float, float, float]] = []
            for _ in range(vc):
                px, py, pz = struct.unpack_from("<fff", data, off)
                off += 12
                vs.append((px, py, pz))
                pn = struct.unpack_from("<I", data, off)[0]
                off += 4
                ns.append((_s10(pn), _s10(pn >> 10), _s10(pn >> 20)))
                if read_vcolor:
                    ci = data[off]
                    off += 1
                    if ci != 128:
                        off += 3
                if uv1:
                    off += 4
                    if uv2:
                        off += 4
                    if read_tangent:
                        off += 4

            idx_fmt = "<I" if vc > 65535 else ("<H" if vc > 255 else "<B")
            sz = struct.calcsize(idx_fmt)
            idxs = [struct.unpack_from(idx_fmt, data, off + k * sz)[0] for k in range(ic)]
            off += ic * sz

            flipped = flip_triangle_winding(idxs)
            for t in range(0, len(flipped), 3):
                # Test in Roblox RH frame after S = diag(1, 1, -1) and flip_triangle_winding
                i0, i1, i2 = flipped[t], flipped[t + 1], flipped[t + 2]
                p0 = (vs[i0][0], vs[i0][1], -vs[i0][2])
                p1 = (vs[i1][0], vs[i1][1], -vs[i1][2])
                p2 = (vs[i2][0], vs[i2][1], -vs[i2][2])
                e1 = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
                e2 = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
                cx = e1[1] * e2[2] - e1[2] * e2[1]
                cy = e1[2] * e2[0] - e1[0] * e2[2]
                cz = e1[0] * e2[1] - e1[1] * e2[0]
                area = 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)
                n_avg = stk_to_rbx_normal(
                    (ns[i0][0] + ns[i1][0] + ns[i2][0]) / 3.0,
                    (ns[i0][1] + ns[i1][1] + ns[i2][1]) / 3.0,
                    (ns[i0][2] + ns[i1][2] + ns[i2][2]) / 3.0,
                )
                d = cx * n_avg[0] + cy * n_avg[1] + cz * n_avg[2]
                if d == 0.0 and area >= 1e-6:
                    non_degenerate_zero_dot += 1
                if d < 0.0 and area >= 1e-5:
                    if tex == "road.jpg":
                        road_non_deg_neg += 1
                    n_verts = [stk_to_rbx_normal(*ns[idx]) for idx in (i0, i1, i2)]
                    if all(cx * nv[0] + cy * nv[1] + cz * nv[2] < 0.0 for nv in n_verts):
                        all_three_verts_opposed += 1

        self.assertEqual(non_degenerate_zero_dot, 0)
        self.assertEqual(road_non_deg_neg, 0)
        self.assertEqual(all_three_verts_opposed, 0)

    def test_glb_writer_header_and_json_chunk(self) -> None:
        patch = RoadPatch(
            vertices=[(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, -1.0)],
            normals=[(0.0, 1.0, 0.0), (0.0, 1.0, 0.0), (0.0, 1.0, 0.0)],
            triangles=[(0, 1, 2)],
            size_studs=(1.0, 0.0, 1.0),
            seed_stk_center_m=(0.0, 0.0, 0.0),
        )
        with tempfile.TemporaryDirectory() as tmp:
            glb_path = Path(tmp) / "probe.glb"
            write_glb(patch, glb_path)
            raw = glb_path.read_bytes()
            magic, version, total_len = struct.unpack_from("<III", raw, 0)
            self.assertEqual(magic, 0x46546C67)
            self.assertEqual(version, 2)
            self.assertEqual(total_len, len(raw))
            jlen, jtype = struct.unpack_from("<II", raw, 12)
            self.assertEqual(jtype, 0x4E4F534A)
            doc = json.loads(raw[20 : 20 + jlen].decode("utf-8"))
            self.assertEqual(doc["meshes"][0]["primitives"][0]["indices"], 2)

    @unittest.skipUnless(
        Path(r"C:\dev\stk-assets\tracks\sandtrack\sandtrack_track.spm").exists(),
        "sandtrack_track.spm upstream asset not fetched",
    )
    def test_sandtrack_road_probe_patch(self) -> None:
        sdir = Path(r"C:\dev\stk-assets\tracks\sandtrack")
        patch = extract_contiguous_road_patch(
            sdir / "sandtrack_track.spm", quads_path=sdir / "quads.xml", max_triangles=64
        )
        self.assertEqual(len(patch.triangles), 64)
        self.assertTrue(all(s < 2048.0 for s in patch.size_studs))

    def test_xml_and_mesh_pipeline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tdir = Path(tmp) / "testtrack"
            tdir.mkdir()

            (tdir / "track.xml").write_text(
                '<track name="Test Sand" designer="Tester" version="7" default-number-of-laps="3"/>',
                encoding="utf-8",
            )
            (tdir / "quads.xml").write_text(
                '<quads>'
                '<quad p0="-5 0 0" p1="5 0 0" p2="5 0 10" p3="-5 0 10"/>'
                '<quad p0="0:3" p1="0:2" p2="5 0 20" p3="-5 0 20"/>'
                "</quads>",
                encoding="utf-8",
            )
            (tdir / "graph.xml").write_text(
                '<graph><node-list from-quad="0" to-quad="1"/><edge-loop from="0" to="1"/></graph>',
                encoding="utf-8",
            )
            (tdir / "scene.xml").write_text(
                '<scene>'
                '<track model="track.spm" xyz="0 0 0" hpr="0 0 0">'
                '<static-object model="palm.b3d" xyz="5 0 5" hpr="0 0 0" scale="1 1 1" interaction="physics-only"/>'
                '</track>'
                '<object id="palm" type="movable" model="palm.b3d" xyz="10 0 10" hpr="0 90 0" scale="1 1 1"/>'
                '<checks><check-line kind="lap" p1="-5 0 0" p2="5 0 0" active="true"/></checks>'
                '<item x="1.4" y="0" z="2.8"/>'
                '<start position="0" xyz="0 0 2" h="0"/>'
                "</scene>",
                encoding="utf-8",
            )

            _write_synthetic_spm(tdir / "track.spm", num_verts=300, num_tris=25000, skinned=False, bounds_m=(2500.0, 10.0, 20.0))
            _write_synthetic_b3d(tdir / "palm.b3d", num_verts=6, num_tris=4)

            tinfo = parse_track_xml(tdir / "track.xml")
            self.assertEqual(tinfo.name, "Test Sand")
            graph = parse_graph_and_quads(tdir / "quads.xml", tdir / "graph.xml")
            self.assertEqual(len(graph.quads), 2)
            self.assertEqual(graph.quads[1].successors, [0])
            self.assertAlmostEqual(graph.lap_length, 20.0, places=3)

            scene = parse_scene_xml(tdir / "scene.xml")
            self.assertEqual(len(scene.checks), 1)
            self.assertEqual(len(scene.items), 1)
            self.assertAlmostEqual(scene.items[0].xyz[0], 1.4, places=4)
            self.assertEqual(len(scene.objects), 2)

            spm_audit = audit_mesh(tdir / "track.spm")
            self.assertEqual(spm_audit.mesh_format, "SPMN")
            self.assertEqual(spm_audit.triangle_count, 25000)
            self.assertTrue(spm_audit.exceeds_20k_whole)
            self.assertTrue(spm_audit.exceeds_2048_studs)
            self.assertGreater(spm_audit.submeshes[0].max_triangle_extent_m, 0.0)
            self.assertEqual(
                _svn_assets_url("tracks/sandtrack", "18627"),
                "https://svn.code.sf.net/p/supertuxkart/code/!svn/bc/18627/stk-assets/tracks/sandtrack",
            )

            b3d_audit = audit_mesh(tdir / "palm.b3d")
            self.assertEqual(b3d_audit.mesh_format, "B3D")
            self.assertEqual(b3d_audit.triangle_count, 4)

            out_model = Path(tmp) / "testtrack.model.json"
            out_report = Path(tmp) / "report.json"
            report = convert_track(tdir, out_model, out_report, revision="12345")
            self.assertTrue(out_model.exists())
            self.assertTrue(out_report.exists())
            self.assertEqual(report["mesh_formats_found"], ["B3D", "SPMN"])
            self.assertEqual(len(report["cap_violations"]), 1)

            # Verify materials.xml parser against sandtrack's 7 materials
            mats_xml = Path(tmp) / "materials.xml"
            mats_xml.write_text(
                "<materials>"
                '<material name="oasis-water.png" shader="displace" ignore="Y"/>'
                '<material name="pyramidwall.jpg" high-adhesion="Y"/>'
                '<material name="road.jpg" normal-map="road_nm.png"/>'
                '<material name="sand.png" slowdown-time="1.50" max-speed="0.50"/>'
                '<material name="seabed.jpg" reset="Y"/>'
                '<material name="transparence2.png" collision-detect="Y" collision-reaction="reset"/>'
                '<material name="water_light.png" surface="Y" falling-effect="Y"/>'
                "</materials>",
                encoding="utf-8",
            )
            mats = {m.name: m for m in parse_materials_xml(mats_xml)}
            self.assertEqual(len(mats), 7)
            self.assertTrue(mats["oasis-water.png"].ignore)
            self.assertTrue(mats["pyramidwall.jpg"].high_adhesion)
            self.assertAlmostEqual(mats["sand.png"].max_speed_fraction, 0.5)
            self.assertAlmostEqual(mats["sand.png"].slowdown_time, 1.5)
            self.assertTrue(mats["seabed.jpg"].reset)
            self.assertEqual(mats["transparence2.png"].collision_reaction, "reset")
            self.assertTrue(mats["water_light.png"].falling_effect)
            self.assertTrue(mats["water_light.png"].reset)

            model_doc = json.loads(out_model.read_text(encoding="utf-8"))
            folders = {c["Name"]: c for c in model_doc["Children"]}
            for qpart in folders["Driveline"]["Children"]:
                props = qpart["Properties"]
                self.assertFalse(props["CanCollide"])
                self.assertFalse(props["CanTouch"])
                self.assertTrue(props["CanQuery"])
                self.assertEqual(props["Transparency"], 1.0)
            for cpart in folders["Checkpoints"]["Children"]:
                props = cpart["Properties"]
                self.assertFalse(props["CanCollide"])
                self.assertFalse(props["CanTouch"])
                self.assertTrue(props["CanQuery"])
                self.assertEqual(props["Transparency"], 1.0)

    def test_spm_writer_roundtrip_and_winding(self) -> None:
        from tools.stk2rbx.road_probe import _read_spm_submesh
        from tools.stk2rbx.spm_writer import SpmSubmesh, build_box_geometry, write_spmn

        v1, i1 = build_box_geometry((0.0, -1.0, 0.0), (20.0, 2.0, 40.0), (0.0, 0.0, 0.0))
        v2, i2 = build_box_geometry((28.0, 4.18, 45.0), (16.0, 1.0, 36.0), (0.0, 0.0, 35.0))
        self.assertEqual(len(v1), 24)
        self.assertEqual(len(i1), 36)
        self.assertEqual(len(v2), 24)
        self.assertEqual(len(i2), 36)

        with tempfile.TemporaryDirectory() as tmp:
            spm_path = Path(tmp) / "test_arena.spm"
            write_spmn(
                spm_path,
                [
                    SpmSubmesh(texture_1="road.jpg", vertices=v1, indices=i1),
                    SpmSubmesh(texture_1="pyramidwall.jpg", vertices=v2, indices=i2),
                ],
            )
            audit = audit_mesh(spm_path)
            self.assertEqual(audit.mesh_format, "SPMN")
            self.assertEqual(audit.vertex_count, 48)
            self.assertEqual(audit.triangle_count, 24)
            self.assertEqual(audit.submesh_count, 2)

            for tex in ("road.jpg", "pyramidwall.jpg"):
                vs, ns, idxs = _read_spm_submesh(spm_path, target_texture=tex)
                for k in range(0, len(idxs), 3):
                    a, b, c = vs[idxs[k]], vs[idxs[k + 1]], vs[idxs[k + 2]]
                    e1 = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
                    e2 = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
                    cr = (
                        e1[1] * e2[2] - e1[2] * e2[1],
                        e1[2] * e2[0] - e1[0] * e2[2],
                        e1[0] * e2[1] - e1[1] * e2[0],
                    )
                    n = ns[idxs[k]]
                    self.assertGreater(cr[0] * n[0] + cr[1] * n[1] + cr[2] * n[2], 0.0)

    def test_arena_spec_dual_emit_parity(self) -> None:
        from tools.stk2rbx.arena_emit import DEFAULT_SPEC_PATH, emit_roblox_luau, emit_stk_track, load_arena_spec

        spec = load_arena_spec(DEFAULT_SPEC_PATH)
        self.assertEqual(len(spec["boxes"]), 13)
        self.assertEqual(len(spec["materials"]), 7)
        self.assertEqual(len(spec["items"]), 10)
        self.assertEqual(len(spec["driveline"]["points"]), 48)
        self.assertTrue(spec["driveline"]["closed_loop"])

        with tempfile.TemporaryDirectory() as tmp:
            luau_out = Path(tmp) / "GreyboxArenaData.lua"
            stk_out = Path(tmp) / "openkart_arena"
            emit_roblox_luau(spec, luau_out)
            emit_stk_track(spec, stk_out)

            luau_src = luau_out.read_text(encoding="utf-8")
            for box in spec["boxes"]:
                self.assertIn(f'name = "{box["name"]}"', luau_src)
            self.assertIn("drivelineClosedLoop = true", luau_src)
            self.assertIn("{ x = 0.0, z = 6.0 }", luau_src)
            self.assertIn("{ x = 115.0, z = -49.0 }", luau_src)
            # Check STK +Z=72.5 -> Roblox -Z=-72.5 on SandPatch
            self.assertIn("pos = { 0.0, -0.098, -72.5 }", luau_src)
            # Check items parity in Luau (STK +Z -> Roblox -Z)
            self.assertIn('itemType = "small-nitro"', luau_src)
            self.assertIn('itemType = "big-nitro"', luau_src)
            self.assertIn('itemType = "item"', luau_src)
            self.assertIn('itemType = "banana"', luau_src)
            self.assertIn("pos = { -6.0, 0.5, -24.0 }", luau_src)

            spm_path = stk_out / "openkart_arena_track.spm"
            audit = audit_mesh(spm_path)
            self.assertEqual(audit.mesh_format, "SPMN")
            self.assertEqual(audit.triangle_count, 13 * 12)
            for fname in ("track.xml", "materials.xml", "quads.xml", "graph.xml", "scene.xml", "sand.png", "road.jpg"):
                self.assertTrue((stk_out / fname).exists(), f"Missing {fname}")
            quads_xml = (stk_out / "quads.xml").read_text(encoding="utf-8")
            graph_xml = (stk_out / "graph.xml").read_text(encoding="utf-8")
            self.assertEqual(quads_xml.count("<quad "), 48)
            self.assertIn('<edge-loop from="0" to="47"/>', graph_xml)
            scene_xml = (stk_out / "scene.xml").read_text(encoding="utf-8")
            self.assertIn('<small-nitro x="-4.0" y="0.4" z="12.0"/>', scene_xml)
            self.assertIn('<big-nitro x="4.0" y="0.4" z="18.0"/>', scene_xml)
            self.assertIn('<item x="0.0" y="0.5" z="24.0"/>', scene_xml)
            self.assertIn('<banana x="-14.0" y="0.35" z="16.0"/>', scene_xml)

    def test_kart_emitter_synthetic_spma_assembly(self) -> None:
        from tools.stk2rbx.kart_emit import convert_kart

        with tempfile.TemporaryDirectory() as tmp:
            kdir = Path(tmp) / "tux"
            kdir.mkdir()
            (kdir / "kart.xml").write_text(
                '<kart name="Tux" version="3" model-file="tux.spm" type="medium">'
                "<wheels>"
                '<front-left position="-0.32 0.11 0.41" model="wheel-front-left.spm"/>'
                '<front-right position="0.32 0.11 0.41" model="wheel-front-right.spm"/>'
                '<rear-left position="-0.36 0.14 -0.34" model="wheel-rear-left.spm"/>'
                '<rear-right position="0.36 0.14 -0.34" model="wheel-rear-right.spm"/>'
                "</wheels>"
                "<nitro-emitter>"
                '<nitro-emitter-a position="0.2 0.36 -0.58"/>'
                '<nitro-emitter-b position="-0.2 0.36 -0.58"/>'
                "</nitro-emitter>"
                "</kart>",
                encoding="utf-8",
            )
            # Build a 2-submesh SPMA main mesh (tuxkart.png + tux_body.png) with 1-bone armature trailer
            buf = bytearray()
            buf.extend(b"SP")
            buf.append((1 << 3) | 1)  # v1 SPMA
            buf.append(0x01)  # read_normal only
            buf.extend(struct.pack("<6f", -0.4, 0.1, -0.7, 0.4, 0.8, 0.7))
            buf.extend(struct.pack("<H", 2))
            for tex in (b"tuxkart.png", b"tux_body.png"):
                buf.append(len(tex))
                buf.extend(tex)
                buf.append(0)
            buf.extend(struct.pack("<H", 1))  # 1 sector
            buf.extend(struct.pack("<H", 2))  # 2 submeshes
            # Submesh 0: tuxkart.png (Body)
            buf.extend(struct.pack("<IIH", 3, 3, 0))
            for px, py, pz in ((-0.4, 0.1, 0.7), (0.4, 0.1, 0.7), (0.0, 0.1, -0.7)):
                buf.extend(struct.pack("<3f", px, py, pz))
                buf.extend(struct.pack("<I", 0x1FF << 10))
                buf.extend(struct.pack("<ee", 0.0, 0.0))
                buf.extend(struct.pack("<4h4H", 0, -1, -1, -1, 15360, 0, 0, 0))
            buf.extend(struct.pack("<3B", 0, 1, 2))
            # Submesh 1: tux_body.png (Driver)
            buf.extend(struct.pack("<IIH", 3, 3, 1))
            for px, py, pz in ((-0.15, 0.2, 0.2), (0.15, 0.2, 0.2), (0.0, 0.8, -0.1)):
                buf.extend(struct.pack("<3f", px, py, pz))
                buf.extend(struct.pack("<I", 0x1FF << 10))
                buf.extend(struct.pack("<ee", 0.0, 0.0))
                buf.extend(struct.pack("<4h4H", 0, -1, -1, -1, 15360, 0, 0, 0))
            buf.extend(struct.pack("<3B", 0, 1, 2))
            # Minimal valid SPMA armature trailer (1 joint, 1 keyframe at frame 20)
            buf.extend(struct.pack("<BH", 1, 20))
            buf.extend(struct.pack("<HH", 1, 1))
            buf.append(3)
            buf.extend(b"Car")
            buf.extend(struct.pack("<10f", 0, 0, 0, 0, 0, 0, 1, 1, 1, 1))
            buf.extend(struct.pack("<h", -1))
            buf.extend(struct.pack("<H", 1))
            buf.extend(struct.pack("<H10f", 20, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1))
            (kdir / "tux.spm").write_bytes(bytes(buf))

            from tools.stk2rbx.spm_writer import SpmSubmesh, build_box_geometry, write_spmn

            for wf, r in (
                ("wheel-front-left.spm", 0.11),
                ("wheel-front-right.spm", 0.11),
                ("wheel-rear-left.spm", 0.14),
                ("wheel-rear-right.spm", 0.14),
            ):
                wv, wi = build_box_geometry((0.0, 0.0, 0.0), (0.2, r * 2.0, r * 2.0), (0.0, 0.0, 0.0))
                write_spmn(kdir / wf, [SpmSubmesh(texture_1="wheel.png", vertices=wv, indices=wi)])

            out_dir = Path(tmp) / "out"
            out_model = out_dir / "tux.model.json"
            out_glb_dir = out_dir / "glb"
            report = convert_kart(kdir, out_model, out_glb_dir, revision="18627")

            raw_glb = (out_glb_dir / "tux_assembly.glb").read_bytes()
            magic, version, total_len = struct.unpack_from("<III", raw_glb, 0)
            self.assertEqual(magic, 0x46546C67)
            self.assertEqual(version, 2)
            self.assertEqual(total_len, len(raw_glb))
            jlen, _ = struct.unpack_from("<II", raw_glb, 12)
            gltf = json.loads(raw_glb[20 : 20 + jlen].decode("utf-8"))
            node_map = {n["name"]: n for n in gltf["nodes"]}
            for expected in ("Tux", "Body", "Driver", "WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"):
                self.assertIn(expected, node_map)
            # STK +Z forward -> Roblox -Z forward at METERS_PER_STUD = 1.0
            self.assertEqual(node_map["WheelFrontLeft"]["translation"], [-0.32, 0.11, -0.41])
            self.assertEqual(node_map["WheelRearRight"]["translation"], [0.36, 0.14, 0.34])
            self.assertEqual(report["body_driver_combined_bounds_studs"]["size"], [0.8, 0.7, 1.4])

            model_doc = json.loads(out_model.read_text(encoding="utf-8"))
            child_names = {c["Name"] for c in model_doc["Children"]}
            self.assertEqual(
                child_names,
                {"ChassisRoot", "Body", "Driver", "WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"},
            )

    @unittest.skipUnless(
        Path(r"C:\dev\stk-assets\karts\tux\kart.xml").exists()
        and Path(r"C:\dev\stk-code\data\official_karts.xml").exists(),
        "tux upstream assets or official_karts.xml not present",
    )
    def test_tux_mesh_bounds_match_official_karts_xml(self) -> None:
        import xml.etree.ElementTree as ET
        from tools.stk2rbx.kart_emit import convert_kart, parse_kart_xml

        official_root = ET.parse(r"C:\dev\stk-code\data\official_karts.xml").getroot()
        tux_entry = next(el for el in official_root.findall("kart") if el.get("name") == "tux")
        expected_w = float(tux_entry.get("width", "0"))
        expected_h = float(tux_entry.get("height", "0"))
        expected_l = float(tux_entry.get("length", "0"))

        kdir = Path(r"C:\dev\stk-assets\karts\tux")
        spec = parse_kart_xml(kdir / "kart.xml")
        with tempfile.TemporaryDirectory() as tmp:
            out_model = Path(tmp) / "tux.model.json"
            out_glb_dir = Path(tmp) / "glb"
            report = convert_kart(kdir, out_model, out_glb_dir, revision="18627")

            bounds = report["body_driver_combined_bounds_studs"]
            w, h, length = bounds["size"]
            # At METERS_PER_STUD = 1.0, emitted Body+Driver mesh bounds match official_karts.xml within 2 mm
            self.assertAlmostEqual(w, expected_w, delta=0.002)
            self.assertAlmostEqual(h, expected_h, delta=0.002)
            self.assertAlmostEqual(length, expected_l, delta=0.002)
            # And exact KartModel::loadModels 3-decimal truncation (kart_model.cpp:L775-L777)
            self.assertEqual(bounds["truncated_3dp"], [expected_w, expected_h, expected_l])

            # Check wheel radii vs kart.xml vertical wheel centers (wheel bottoms touch Y = 0)
            parts_by_name = {p["node_name"]: p for p in report["parts"]}
            for wheel in spec.wheels:
                p = parts_by_name[wheel.node_name]
                self.assertAlmostEqual(p["wheel_radius_studs"], wheel.position_m[1], delta=0.001)
                self.assertAlmostEqual(p["origin_studs"][2], -wheel.position_m[2], delta=1e-4)

            arm = report["armature"]
            self.assertIsNotNone(arm)
            self.assertEqual(arm["bind_frame"], 20)
            self.assertEqual(arm["joint_used"], 16)
            self.assertEqual(arm["keyframe_count"], 60)

    def test_item_mesh_bounds_match_source_spm(self) -> None:
        from tools.stk2rbx.item_emit import AUTHORITATIVE_ITEMS, convert_items
        from tools.stk2rbx.spm_writer import SpmSubmesh, SpmVertex, build_box_geometry, write_spmn

        def make_synthetic_manifest(items_dir: Path, out_manifest: Path) -> Path:
            items_map: dict[str, Any] = {}
            for item_def in AUTHORITATIVE_ITEMS:
                if item_def.spm_file == "gift-box.spm":
                    parts = {
                        "Box": {"meshId": "rbxassetid://1001", "textureId": "", "importFlipY180": True},
                        "Ribbon": {"meshId": "rbxassetid://1002", "textureId": "", "importFlipY180": True},
                    }
                elif item_def.spm_file == "nitrotank-big.spm":
                    parts = {
                        "Barrel": {"meshId": "rbxassetid://1003", "textureId": "", "importFlipY180": True},
                        "Logo": {"meshId": "rbxassetid://1004", "textureId": "", "importFlipY180": True},
                    }
                elif item_def.spm_file == "nitrotank-small.spm":
                    parts = {
                        "Bottle": {"meshId": "rbxassetid://1005", "textureId": "", "importFlipY180": True},
                        "Logo": {"meshId": "rbxassetid://1006", "textureId": "", "importFlipY180": True},
                    }
                else:
                    parts = {"Main": {"meshId": "rbxassetid://1000", "textureId": "", "importFlipY180": True}}
                items_map[item_def.item_id] = {"parts": parts}
            out_manifest.write_text(json.dumps({"items": items_map}), encoding="utf-8")
            return out_manifest

        # 1) Synthetic multi-submesh SPMN roundtrip check (no primitive Part fallback)
        with tempfile.TemporaryDirectory() as tmp:
            mdir = Path(tmp) / "models"
            mdir.mkdir()
            for item_def in AUTHORITATIVE_ITEMS:
                if item_def.spm_file == "gift-box.spm":
                    v0, i0 = build_box_geometry((0.0, 0.45, 0.0), (0.88, 0.70, 0.88))
                    v1, i1 = build_box_geometry((0.0, 0.58, 0.0), (0.90, 0.99, 0.90))
                    write_spmn(
                        mdir / item_def.spm_file,
                        [
                            SpmSubmesh("gift-box.png", v0, i0),
                            SpmSubmesh("gift-loop.png", v1, i1),
                        ],
                    )
                elif item_def.spm_file == "nitrotank-big.spm":
                    v0, i0 = build_box_geometry((0.0, 0.5, 0.0), (0.81, 1.39, 1.39))
                    v1, i1 = build_box_geometry((0.0, 0.5, 0.0), (0.80, 0.86, 0.86))
                    write_spmn(
                        mdir / item_def.spm_file,
                        [
                            SpmSubmesh("stk_mod_nitroBarrel.png", v0, i0),
                            SpmSubmesh("stk_mod_nitroLogo.png", v1, i1),
                        ],
                    )
                elif item_def.spm_file == "nitrotank-small.spm":
                    v0, i0 = build_box_geometry((0.0, 0.4, 0.0), (0.40, 0.72, 0.72))
                    v1, i1 = build_box_geometry((0.0, 0.4, 0.0), (0.28, 0.58, 0.58))
                    write_spmn(
                        mdir / item_def.spm_file,
                        [
                            SpmSubmesh("stk_mod_nitroBottle.png", v0, i0),
                            SpmSubmesh("stk_mod_nitroLogo.png", v1, i1),
                        ],
                    )
                else:
                    vs, idxs = build_box_geometry((0.0, 0.5, 0.0), (0.6, 1.0, 0.6))
                    write_spmn(mdir / item_def.spm_file, [SpmSubmesh("placeholder.png", vs, idxs)])

            manifest_path = make_synthetic_manifest(mdir, Path(tmp) / "manifest.json")
            rep = convert_items(
                models_dir=mdir,
                out_glb_dir=Path(tmp) / "glbs",
                out_models_dir=Path(tmp) / "rbx_items",
                report_path=Path(tmp) / "items-report.json",
                out_bounds_lua=Path(tmp) / "ItemBoundsData.lua",
                assets_manifest_path=manifest_path,
                revision="test",
            )
            self.assertEqual(rep["item_count"], len(AUTHORITATIVE_ITEMS))
            gb = next(it for it in rep["items"] if it["item_id"] == "gift-box")
            self.assertEqual(len(gb["subparts"]), 2)
            self.assertAlmostEqual(gb["subparts"][0]["size_studs"][0], 0.88, delta=0.001)
            self.assertAlmostEqual(gb["subparts"][1]["size_studs"][1], 0.99, delta=0.001)
            for item_def in AUTHORITATIVE_ITEMS:
                rbxmx = (Path(tmp) / "rbx_items" / f"{item_def.item_id}.rbxmx").read_text(encoding="utf-8")
                self.assertIn('class="MeshPart"', rbxmx)
                self.assertNotIn('class="Part"', rbxmx)

        # 2) Upstream STK 1.5 models bounds audit when installed
        stk_models = Path(r"C:\Program Files\SuperTuxKart 1.5\data\models")
        manifest_file = Path("assets/items/roblox_assets.json")
        if stk_models.is_dir() and manifest_file.is_file():
            with tempfile.TemporaryDirectory() as tmp:
                rep = convert_items(
                    models_dir=stk_models,
                    out_glb_dir=Path(tmp) / "glbs",
                    out_models_dir=Path(tmp) / "rbx_items",
                    report_path=Path(tmp) / "items-report.json",
                    out_bounds_lua=Path(tmp) / "ItemBoundsData.lua",
                    assets_manifest_path=manifest_file,
                    revision="18627",
                )
                by_id = {it["item_id"]: it for it in rep["items"]}
                for item_def in AUTHORITATIVE_ITEMS:
                    audit = audit_mesh(stk_models / item_def.spm_file)
                    emitted = by_id[item_def.item_id]
                    for ax in range(3):
                        src_size = (audit.bbox_max_m[ax] - audit.bbox_min_m[ax]) * STUDS_PER_METER
                        self.assertAlmostEqual(emitted["size_studs"][ax], src_size, delta=0.001)

                    # Also verify every exported GLB file accessor bounds match its subpart size
                    self.assertEqual(len(emitted["subparts"]), len(audit.submeshes))
                    for sp, src_sub in zip(emitted["subparts"], audit.submeshes):
                        glb_path = Path(tmp) / "glbs" / sp["glb_file"]
                        data = glb_path.read_bytes()
                        jlen = struct.unpack_from("<I", data, 12)[0]
                        gltf = json.loads(data[20 : 20 + jlen].decode("utf-8"))
                        pos_acc = next(a for a in gltf["accessors"] if a.get("type") == "VEC3" and "min" in a)
                        for ax in range(3):
                            glb_size = pos_acc["max"][ax] - pos_acc["min"][ax]
                            src_sub_size = (src_sub.bbox_max_m[ax] - src_sub.bbox_min_m[ax]) * STUDS_PER_METER
                            self.assertAlmostEqual(glb_size, sp["size_studs"][ax], delta=0.001)
                            self.assertAlmostEqual(glb_size, src_sub_size, delta=0.001)

    def test_fetch_models_delegates_to_svn_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "models"
            with patch(
                "tools.stk2rbx.cli._fetch_svn_dir",
                return_value=("18627", ["banana.spm", "gift-box.spm", "nitrotank-big.spm", "nitrotank-small.spm"]),
            ) as mock_fetch:
                rc = cli_main(["fetch-models", "--dest", str(dest), "--revision", "18627", "--include-media"])
            self.assertEqual(rc, 0)
            mock_fetch.assert_called_once_with("models", dest, revision="18627", include_media=True)


if __name__ == "__main__":
    unittest.main()
