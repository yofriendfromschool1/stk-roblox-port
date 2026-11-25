# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract ONE contiguous road.jpg patch from STK .spm and emit a .glb + Luau probe.

Reads binary SPMN layout per `src/graphics/sp_mesh_loader.cpp:L87-L441 (STK 1.5)`,
applies `S = diag(1, 1, -1)` (det(S) = -1) at `METERS_PER_STUD = 1.0`, and
reverses triangle winding via `flip_triangle_winding` before emitting:
  1. Binary glTF 2.0 `.glb` (`build/probes/sandtrack_road_patch.glb`)
  2. Pure-Luau triangle/vertex data module (`src/shared/track/SandtrackRoadProbeData.lua`)
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .coords import STUDS_PER_METER, flip_triangle_winding, stk_to_rbx_normal
from .xml_parser import parse_quads_xml

Vec3 = tuple[float, float, float]


@dataclass
class RoadPatch:
    vertices: list[Vec3]
    normals: list[Vec3]
    triangles: list[tuple[int, int, int]]
    size_studs: Vec3
    seed_stk_center_m: Vec3


def _unpack_10bit_signed(val: int) -> float:
    val &= 0x3FF
    return (val - 1024) / 511.0 if val >= 512 else val / 511.0


def _read_spm_submesh(
    spm_path: Path, target_texture: str = "road.jpg"
) -> tuple[list[Vec3], list[Vec3], list[int]]:
    data = spm_path.read_bytes()
    if len(data) < 28 or data[:2] != b"SP":
        raise ValueError(f"{spm_path.name}: invalid SPM header")

    header_byte = data[2]
    type_code = header_byte & ~0x08
    if type_code == 1:
        raise ValueError(f"{spm_path.name}: SPMA skinned meshes unsupported in road_probe")
    flags = data[3]
    read_normal = bool(flags & 0x01)
    read_vcolor = bool(flags & 0x02)
    read_tangent = bool(flags & 0x04)

    off = 28  # 4 header + 24 AABB floats
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
    for _ in range(sec_count):
        sub_count = struct.unpack_from("<H", data, off)[0]
        off += 2
        for _ in range(sub_count):
            vc, ic, mid = struct.unpack_from("<IIH", data, off)
            off += 10
            tex1, tex2 = mats[mid]
            uv1, uv2 = len(tex1) > 0, len(tex2) > 0

            vs: list[Vec3] = []
            ns: list[Vec3] = []
            for _ in range(vc):
                px, py, pz = struct.unpack_from("<fff", data, off)
                off += 12
                vs.append((px, py, pz))
                if read_normal:
                    pn = struct.unpack_from("<I", data, off)[0]
                    off += 4
                    ns.append(
                        (
                            _unpack_10bit_signed(pn),
                            _unpack_10bit_signed(pn >> 10),
                            _unpack_10bit_signed(pn >> 20),
                        )
                    )
                else:
                    ns.append((0.0, 1.0, 0.0))
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

            if tex1.lower() == target_texture.lower():
                return vs, ns, idxs

    raise ValueError(f"{spm_path.name}: no submesh found for texture '{target_texture}'")


def _tri_area(a: Vec3, b: Vec3, c: Vec3) -> float:
    e1 = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    e2 = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
    cx = e1[1] * e2[2] - e1[2] * e2[1]
    cy = e1[2] * e2[0] - e1[0] * e2[2]
    cz = e1[0] * e2[1] - e1[1] * e2[0]
    return 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)


def extract_contiguous_road_patch(
    spm_path: Path,
    quads_path: Optional[Path] = None,
    max_triangles: int = 64,
    target_texture: str = "road.jpg",
) -> RoadPatch:
    """Extract one contiguous local-origin road patch transformed to Roblox coords."""
    verts, normals, raw_indices = _read_spm_submesh(spm_path, target_texture=target_texture)

    seed_target = (0.0, 0.0, 0.0)
    if quads_path is not None and quads_path.exists():
        quads, _, _ = parse_quads_xml(quads_path)
        if quads:
            seed_target = quads[0].center

    # Keep only non-degenerate triangles (`area >= 1e-4 m^2`), connecting across UV seam splits via rounded position
    valid_tris: list[tuple[int, int, int]] = []
    tri_centroids: list[Vec3] = []
    pos_to_tris: dict[tuple[float, float, float], list[int]] = defaultdict(list)

    def _pos_key(p: Vec3) -> tuple[float, float, float]:
        return (round(p[0], 3), round(p[1], 3), round(p[2], 3))

    for k in range(0, len(raw_indices) - 2, 3):
        i0, i1, i2 = raw_indices[k], raw_indices[k + 1], raw_indices[k + 2]
        if i0 == i1 or i1 == i2 or i0 == i2:
            continue
        p0, p1, p2 = verts[i0], verts[i1], verts[i2]
        if _tri_area(p0, p1, p2) < 1e-4:
            continue
        t_idx = len(valid_tris)
        valid_tris.append((i0, i1, i2))
        tri_centroids.append(
            (
                (p0[0] + p1[0] + p2[0]) / 3.0,
                (p0[1] + p1[1] + p2[1]) / 3.0,
                (p0[2] + p1[2] + p2[2]) / 3.0,
            )
        )
        for pt in (p0, p1, p2):
            pos_to_tris[_pos_key(pt)].append(t_idx)

    if not valid_tris:
        raise ValueError(f"No valid non-degenerate triangles in '{target_texture}'")

    seed_tri = min(
        range(len(valid_tris)),
        key=lambda t: (tri_centroids[t][0] - seed_target[0]) ** 2
        + (tri_centroids[t][1] - seed_target[1]) ** 2
        + (tri_centroids[t][2] - seed_target[2]) ** 2,
    )

    # BFS over adjacent triangles sharing at least 1 spatial vertex
    chosen: list[int] = []
    visited = {seed_tri}
    queue: deque[int] = deque([seed_tri])
    while queue and len(chosen) < max_triangles:
        cur = queue.popleft()
        chosen.append(cur)
        for v in valid_tris[cur]:
            for nb in pos_to_tris[_pos_key(verts[v])]:
                if nb not in visited:
                    visited.add(nb)
                    queue.append(nb)

    # Compact used vertices, transform STK (+Z) -> Roblox (-Z) via S = diag(1, 1, -1),
    # and flip triangle winding so outward normals stay outward (+Y).
    remap: dict[int, int] = {}
    rbx_verts_raw: list[Vec3] = []
    rbx_normals: list[Vec3] = []
    flat_stk_indices: list[int] = []

    for t_idx in chosen:
        for orig_v in valid_tris[t_idx]:
            if orig_v not in remap:
                remap[orig_v] = len(rbx_verts_raw)
                vx, vy, vz = verts[orig_v]
                rbx_verts_raw.append(
                    (vx * STUDS_PER_METER, vy * STUDS_PER_METER, -vz * STUDS_PER_METER)
                )
                rbx_normals.append(stk_to_rbx_normal(*normals[orig_v]))
            flat_stk_indices.append(remap[orig_v])

    flipped = flip_triangle_winding(flat_stk_indices)
    rbx_tris: list[tuple[int, int, int]] = [
        (flipped[k], flipped[k + 1], flipped[k + 2]) for k in range(0, len(flipped), 3)
    ]

    xs = [v[0] for v in rbx_verts_raw]
    ys = [v[1] for v in rbx_verts_raw]
    zs = [v[2] for v in rbx_verts_raw]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    min_z, max_z = min(zs), max(zs)
    cx = 0.5 * (min_x + max_x)
    cz = 0.5 * (min_z + max_z)

    local_verts = [
        (round(v[0] - cx, 5), round(v[1] - min_y, 5), round(v[2] - cz, 5))
        for v in rbx_verts_raw
    ]

    # Verify outward winding consistency for 100% of patch triangles
    for i0, i1, i2 in rbx_tris:
        p0, p1, p2 = local_verts[i0], local_verts[i1], local_verts[i2]
        e1 = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
        e2 = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
        fn = (
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        )
        n_avg = (
            (rbx_normals[i0][0] + rbx_normals[i1][0] + rbx_normals[i2][0]) / 3.0,
            (rbx_normals[i0][1] + rbx_normals[i1][1] + rbx_normals[i2][1]) / 3.0,
            (rbx_normals[i0][2] + rbx_normals[i1][2] + rbx_normals[i2][2]) / 3.0,
        )
        dot = fn[0] * n_avg[0] + fn[1] * n_avg[1] + fn[2] * n_avg[2]
        if dot <= 0.0:
            raise AssertionError(f"Triangle {(i0, i1, i2)} inverted after flip_triangle_winding: dot={dot}")
        if fn[1] <= 0.0:
            raise AssertionError(f"Road patch triangle {(i0, i1, i2)} does not face upward (+Y): fn={fn}")

    size_studs = (round(max_x - min_x, 4), round(max_y - min_y, 4), round(max_z - min_z, 4))
    return RoadPatch(
        vertices=local_verts,
        normals=rbx_normals,
        triangles=rbx_tris,
        size_studs=size_studs,
        seed_stk_center_m=tri_centroids[seed_tri],
    )


def write_glb(patch: RoadPatch, out_glb: Path) -> None:
    """Write binary glTF 2.0 (.glb) containing POSITION, NORMAL, and uint16 INDICES."""
    pos_bytes = bytearray()
    norm_bytes = bytearray()
    bmin = [float("inf"), float("inf"), float("inf")]
    bmax = [float("-inf"), float("-inf"), float("-inf")]

    for v, n in zip(patch.vertices, patch.normals):
        pos_bytes.extend(struct.pack("<3f", *v))
        norm_bytes.extend(struct.pack("<3f", *n))
        for axis in range(3):
            if v[axis] < bmin[axis]:
                bmin[axis] = v[axis]
            if v[axis] > bmax[axis]:
                bmax[axis] = v[axis]

    idx_bytes = bytearray()
    for i0, i1, i2 in patch.triangles:
        idx_bytes.extend(struct.pack("<3H", i0, i1, i2))
    while len(idx_bytes) % 4 != 0:
        idx_bytes.append(0)

    bin_blob = bytes(pos_bytes) + bytes(norm_bytes) + bytes(idx_bytes)
    while len(bin_blob) % 4 != 0:
        bin_blob += b"\x00"

    v_count = len(patch.vertices)
    i_count = len(patch.triangles) * 3
    pos_len = len(pos_bytes)
    norm_len = len(norm_bytes)
    idx_len = i_count * 2

    gltf = {
        "asset": {"version": "2.0", "generator": "OpenKart-stk2rbx-road_probe"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "SandtrackRoadProbe"}],
        "meshes": [
            {
                "name": "SandtrackRoadProbe",
                "primitives": [
                    {
                        "attributes": {"POSITION": 0, "NORMAL": 1},
                        "indices": 2,
                        "mode": 4,
                    }
                ],
            }
        ],
        "buffers": [{"byteLength": len(bin_blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": pos_len, "target": 34962},
            {"buffer": 0, "byteOffset": pos_len, "byteLength": norm_len, "target": 34962},
            {"buffer": 0, "byteOffset": pos_len + norm_len, "byteLength": idx_len, "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": v_count,
                "type": "VEC3",
                "min": [round(x, 6) for x in bmin],
                "max": [round(x, 6) for x in bmax],
            },
            {
                "bufferView": 1,
                "componentType": 5126,
                "count": v_count,
                "type": "VEC3",
            },
            {
                "bufferView": 2,
                "componentType": 5123,
                "count": i_count,
                "type": "SCALAR",
            },
        ],
    }

    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(json_bytes) % 4 != 0:
        json_bytes += b" "

    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_blob)
    header = struct.pack("<III", 0x46546C67, 2, total_len)
    json_chunk = struct.pack("<II", len(json_bytes), 0x4E4F534A) + json_bytes
    bin_chunk = struct.pack("<II", len(bin_blob), 0x004E4942) + bin_blob

    out_glb.parent.mkdir(parents=True, exist_ok=True)
    out_glb.write_bytes(header + json_chunk + bin_chunk)


def write_luau_probe_module(patch: RoadPatch, out_lua: Path, revision: str = "18627") -> None:
    """Emit a pure-Luau frozen data module for runtime EditableMesh probe loading."""
    lines = [
        "--!strict",
        "-- src/shared/track/SandtrackRoadProbeData.lua",
        "-- SPDX-License-Identifier: GPL-3.0-or-later",
        f"-- Extracted from stk-assets/tracks/sandtrack/sandtrack_track.spm (rev {revision}, submesh road.jpg).",
        "-- Transformed via S = diag(1, 1, -1) (det = -1) at METERS_PER_STUD = 1.0 with flip_triangle_winding.",
        "",
        "local vertices: { { number } } = {",
    ]
    for vx, vy, vz in patch.vertices:
        lines.append(f"\t{{ {vx:.5f}, {vy:.5f}, {vz:.5f} }},")
    lines.append("}")
    lines.append("")
    lines.append("local triangles: { { number } } = {")
    for i0, i1, i2 in patch.triangles:
        lines.append(f"\t{{ {i0 + 1}, {i1 + 1}, {i2 + 1} }},")
    lines.append("}")
    lines.append("")
    lines.extend(
        [
            "local SandtrackRoadProbeData = {",
            '\tsourceTrack = "sandtrack",',
            f'\tsourceRevision = "{revision}",',
            '\tsourceMaterial = "road.jpg",',
            f"\tsizeStuds = {{ {patch.size_studs[0]:.4f}, {patch.size_studs[1]:.4f}, {patch.size_studs[2]:.4f} }},",
            "\tvertices = table.freeze(vertices),",
            "\ttriangles = table.freeze(triangles),",
            "}",
            "",
            "return table.freeze(SandtrackRoadProbeData)",
            "",
        ]
    )

    out_lua.parent.mkdir(parents=True, exist_ok=True)
    out_lua.write_text("\n".join(lines), encoding="utf-8")


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Extract ONE road.jpg thin-mesh collision probe.")
    parser.add_argument(
        "--track-dir",
        type=Path,
        default=Path(r"C:\dev\stk-assets\tracks\sandtrack"),
        help="Local upstream track directory",
    )
    parser.add_argument(
        "--out-glb",
        type=Path,
        default=Path("build/probes/sandtrack_road_patch.glb"),
        help="Output binary glTF 2.0 path",
    )
    parser.add_argument(
        "--out-luau",
        type=Path,
        default=Path("src/shared/track/SandtrackRoadProbeData.lua"),
        help="Output Luau data module path",
    )
    parser.add_argument("--max-tris", type=int, default=64, help="Triangle budget for single patch")
    args = parser.parse_args(argv)

    spm_path = args.track_dir / "sandtrack_track.spm"
    quads_path = args.track_dir / "quads.xml"
    patch = extract_contiguous_road_patch(
        spm_path, quads_path=quads_path, max_triangles=args.max_tris, target_texture="road.jpg"
    )
    write_glb(patch, args.out_glb)
    write_luau_probe_module(patch, args.out_luau)
    print(
        f"Road probe exported: tris={len(patch.triangles)}, verts={len(patch.vertices)}, "
        f"size_studs={patch.size_studs} -> {args.out_glb}, {args.out_luau}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
