# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for tools/stk2rbx XML parsing, mesh inspection, coords, and Rojo emission."""

from __future__ import annotations

import json
import math
import struct
import tempfile
import unittest
from pathlib import Path

from tools.stk2rbx.cli import convert_track
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
from tools.stk2rbx.xml_parser import parse_graph_and_quads, parse_scene_xml, parse_track_xml


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
        pos = stk_to_rbx_pos(0.28, 0.56, 2.8)
        self.assertEqual(pos, [1.0, 2.0, -10.0])

        clamped, raw, exceeds = stk_to_rbx_size(700.0, 1.0, 2.0)
        self.assertTrue(exceeds)
        self.assertAlmostEqual(raw[0], 700.0 * STUDS_PER_METER, places=2)
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

            _write_synthetic_spm(tdir / "track.spm", num_verts=300, num_tris=25000, skinned=False, bounds_m=(600.0, 10.0, 20.0))
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


if __name__ == "__main__":
    unittest.main()
