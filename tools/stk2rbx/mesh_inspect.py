# SPDX-License-Identifier: GPL-3.0-or-later
"""Binary mesh inspector (.spm and .b3d) & Roblox per-mesh cap auditor.

Follows exact STK 1.5 binary layouts:
  - SPM: src/graphics/sp_mesh_loader.cpp:L87-L441 (STK 1.5)
  - B3D: src/graphics/b3d_mesh_loader.cpp:L446-L810 (STK 1.5)
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO

from .coords import STUDS_PER_METER

# Roblox 3D Importer / BasePart limits
ROBLOX_HARD_TRI_CAP: int = 20_000
ROBLOX_SOFT_TRI_CAP: int = 10_000
ROBLOX_MAX_PART_SIZE_STUDS: float = 2048.0
ROBLOX_MAX_SUBMESHES_PER_IMPORT: int = 200


@dataclass
class SubmeshStats:
    submesh_index: int
    material_id: int
    texture_1: str
    texture_2: str
    vertex_count: int
    triangle_count: int
    bbox_min_m: tuple[float, float, float]
    bbox_max_m: tuple[float, float, float]

    @property
    def exceeds_20k(self) -> bool:
        return self.triangle_count > ROBLOX_HARD_TRI_CAP

    @property
    def exceeds_10k(self) -> bool:
        return self.triangle_count > ROBLOX_SOFT_TRI_CAP

    @property
    def size_studs(self) -> tuple[float, float, float]:
        return (
            round((self.bbox_max_m[0] - self.bbox_min_m[0]) * STUDS_PER_METER, 4),
            round((self.bbox_max_m[1] - self.bbox_min_m[1]) * STUDS_PER_METER, 4),
            round((self.bbox_max_m[2] - self.bbox_min_m[2]) * STUDS_PER_METER, 4),
        )

    @property
    def exceeds_2048_studs(self) -> bool:
        return any(s > ROBLOX_MAX_PART_SIZE_STUDS for s in self.size_studs)


@dataclass
class MeshAudit:
    file_name: str
    file_size_bytes: int
    mesh_format: str  # "SPMN" | "SPMA" | "SPMS" | "B3D"
    vertex_count: int
    triangle_count: int
    submesh_count: int
    material_count: int
    bbox_min_m: tuple[float, float, float]
    bbox_max_m: tuple[float, float, float]
    submeshes: list[SubmeshStats] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def size_m(self) -> tuple[float, float, float]:
        return (
            round(self.bbox_max_m[0] - self.bbox_min_m[0], 4),
            round(self.bbox_max_m[1] - self.bbox_min_m[1], 4),
            round(self.bbox_max_m[2] - self.bbox_min_m[2], 4),
        )

    @property
    def size_studs(self) -> tuple[float, float, float]:
        return (
            round((self.bbox_max_m[0] - self.bbox_min_m[0]) * STUDS_PER_METER, 4),
            round((self.bbox_max_m[1] - self.bbox_min_m[1]) * STUDS_PER_METER, 4),
            round((self.bbox_max_m[2] - self.bbox_min_m[2]) * STUDS_PER_METER, 4),
        )

    @property
    def max_submesh_triangles(self) -> int:
        return max((s.triangle_count for s in self.submeshes), default=0)

    @property
    def exceeds_20k_whole(self) -> bool:
        return self.triangle_count > ROBLOX_HARD_TRI_CAP

    @property
    def exceeds_10k_whole(self) -> bool:
        return self.triangle_count > ROBLOX_SOFT_TRI_CAP

    @property
    def exceeds_20k_any_submesh(self) -> bool:
        return any(s.exceeds_20k for s in self.submeshes)

    @property
    def exceeds_10k_any_submesh(self) -> bool:
        return any(s.exceeds_10k for s in self.submeshes)

    @property
    def exceeds_2048_studs(self) -> bool:
        return any(s > ROBLOX_MAX_PART_SIZE_STUDS for s in self.size_studs)

    @property
    def exceeds_200_submeshes(self) -> bool:
        return self.submesh_count > ROBLOX_MAX_SUBMESHES_PER_IMPORT


def _read_exact(f: BinaryIO, n: int) -> bytes:
    data = f.read(n)
    if len(data) != n:
        raise EOFError(f"Unexpected EOF: wanted {n} bytes, got {len(data)}")
    return data


def _update_bbox(
    bmin: list[float], bmax: list[float], x: float, y: float, z: float
) -> None:
    if x < bmin[0]:
        bmin[0] = x
    if y < bmin[1]:
        bmin[1] = y
    if z < bmin[2]:
        bmin[2] = z
    if x > bmax[0]:
        bmax[0] = x
    if y > bmax[1]:
        bmax[1] = y
    if z > bmax[2]:
        bmax[2] = z


def parse_spm(path: Path) -> MeshAudit:
    """Parse a SuperTuxKart .spm mesh (src/graphics/sp_mesh_loader.cpp:L87-L441)."""
    file_size = path.stat().st_size
    with path.open("rb") as f:
        magic = _read_exact(f, 2)
        if magic != b"SP":
            raise ValueError(f"{path.name}: expected 'SP' header, got {magic!r}")

        header_byte = _read_exact(f, 1)[0]
        version = header_byte >> 3
        if version != 1:
            raise ValueError(f"{path.name}: unsupported SPM version {version}")

        type_code = header_byte & ~0x08
        if type_code == 0:
            raise ValueError(f"{path.name}: SPMS space-partitioned mesh unsupported")
        mesh_format = "SPMA" if type_code == 1 else "SPMN"
        is_skinned = mesh_format == "SPMA"

        flags_byte = _read_exact(f, 1)[0]
        read_normal = bool(flags_byte & 0x01)
        read_vcolor = bool((flags_byte >> 1) & 0x01)
        read_tangent = bool((flags_byte >> 2) & 0x01)

        # Header 6-float AABB (skip, compute exact AABB from vertex positions)
        _read_exact(f, 24)

        mat_count = struct.unpack("<H", _read_exact(f, 2))[0]
        materials: list[tuple[str, str]] = []
        for _ in range(mat_count):
            t1_len = _read_exact(f, 1)[0]
            t1 = _read_exact(f, t1_len).decode("utf-8", errors="replace") if t1_len > 0 else ""
            t2_len = _read_exact(f, 1)[0]
            t2 = _read_exact(f, t2_len).decode("utf-8", errors="replace") if t2_len > 0 else ""
            materials.append((t1, t2))

        sector_count = struct.unpack("<H", _read_exact(f, 2))[0]
        submeshes: list[SubmeshStats] = []
        g_min = [float("inf"), float("inf"), float("inf")]
        g_max = [float("-inf"), float("-inf"), float("-inf")]
        total_verts = 0
        total_tris = 0

        for _ in range(sector_count):
            mat_size = struct.unpack("<H", _read_exact(f, 2))[0]
            for _ in range(mat_size):
                v_count, i_count, mat_id = struct.unpack("<IIH", _read_exact(f, 10))
                if mat_id >= len(materials):
                    raise ValueError(f"{path.name}: invalid mat_id {mat_id}")
                tex1, tex2 = materials[mat_id]
                uv_one = len(tex1) > 0
                uv_two = len(tex2) > 0

                s_min = [float("inf"), float("inf"), float("inf")]
                s_max = [float("-inf"), float("-inf"), float("-inf")]

                for _ in range(v_count):
                    px, py, pz = struct.unpack("<fff", _read_exact(f, 12))
                    _update_bbox(s_min, s_max, px, py, pz)
                    _update_bbox(g_min, g_max, px, py, pz)
                    if read_normal:
                        _read_exact(f, 4)
                    if read_vcolor:
                        ci = _read_exact(f, 1)[0]
                        if ci != 128:
                            _read_exact(f, 3)
                    if uv_one:
                        _read_exact(f, 4)
                        if uv_two:
                            _read_exact(f, 4)
                        if read_tangent:
                            _read_exact(f, 4)
                    if is_skinned:
                        _read_exact(f, 16)

                idx_size = 2 if v_count > 255 else 1
                _read_exact(f, i_count * idx_size)

                tri_count = i_count // 3
                total_verts += v_count
                total_tris += tri_count
                submeshes.append(
                    SubmeshStats(
                        submesh_index=len(submeshes),
                        material_id=mat_id,
                        texture_1=tex1,
                        texture_2=tex2,
                        vertex_count=v_count,
                        triangle_count=tri_count,
                        bbox_min_m=(s_min[0], s_min[1], s_min[2]),
                        bbox_max_m=(s_max[0], s_max[1], s_max[2]),
                    )
                )

    if total_verts == 0:
        g_min = [0.0, 0.0, 0.0]
        g_max = [0.0, 0.0, 0.0]

    notes: list[str] = []
    if len(submeshes) > 1:
        notes.append(f"Multi-material mesh ({len(submeshes)} submeshes): split per material for Roblox SurfaceAppearance")
    return MeshAudit(
        file_name=path.name,
        file_size_bytes=file_size,
        mesh_format=mesh_format,
        vertex_count=total_verts,
        triangle_count=total_tris,
        submesh_count=len(submeshes),
        material_count=len(materials),
        bbox_min_m=(g_min[0], g_min[1], g_min[2]),
        bbox_max_m=(g_max[0], g_max[1], g_max[2]),
        submeshes=submeshes,
        notes=notes,
    )


def _read_cstr(buf: bytes, pos: int) -> tuple[str, int]:
    end = buf.index(0, pos)
    return buf[pos:end].decode("utf-8", errors="replace"), end + 1


def parse_b3d(path: Path) -> MeshAudit:
    """Parse a Blitz3D .b3d mesh (src/graphics/b3d_mesh_loader.cpp:L446-L810)."""
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"BB3D":
        raise ValueError(f"{path.name}: expected 'BB3D' header")

    root_len = struct.unpack_from("<I", data, 4)[0]
    root_end = min(len(data), 8 + root_len)
    pos = 12  # skip BB3D + len + version(4)

    textures: list[str] = []
    brushes: list[tuple[str, int]] = []
    submeshes: list[SubmeshStats] = []
    g_min = [float("inf"), float("inf"), float("inf")]
    g_max = [float("-inf"), float("-inf"), float("-inf")]
    total_verts = 0
    total_tris = 0

    def walk_node(end_pos: int, p: int) -> None:
        nonlocal total_verts, total_tris
        _, p = _read_cstr(data, p)
        p += 40  # pos(3f) + scale(3f) + rot(4f)
        while p < end_pos:
            tag = data[p : p + 4]
            clen = struct.unpack_from("<I", data, p + 4)[0]
            cstart = p + 8
            cend = cstart + clen
            if tag == b"NODE":
                walk_node(cend, cstart)
            elif tag == b"MESH":
                walk_mesh(cend, cstart)
            p = cend

    def walk_mesh(end_pos: int, p: int) -> None:
        nonlocal total_verts, total_tris
        _ = struct.unpack_from("<i", data, p)[0]  # default brush_id
        p += 4
        m_min = [float("inf"), float("inf"), float("inf")]
        m_max = [float("-inf"), float("-inf"), float("-inf")]
        mesh_verts = 0
        while p < end_pos:
            tag = data[p : p + 4]
            clen = struct.unpack_from("<I", data, p + 4)[0]
            cstart = p + 8
            cend = cstart + clen
            if tag == b"VRTS":
                flags, tc_sets, tc_size = struct.unpack_from("<iii", data, cstart)
                stride = 3 + (3 if flags & 1 else 0) + (4 if flags & 2 else 0) + tc_sets * tc_size
                vp = cstart + 12
                while vp + stride * 4 <= cend:
                    px, py, pz = struct.unpack_from("<fff", data, vp)
                    _update_bbox(m_min, m_max, px, py, pz)
                    _update_bbox(g_min, g_max, px, py, pz)
                    mesh_verts += 1
                    total_verts += 1
                    vp += stride * 4
            elif tag == b"TRIS":
                brush_id = struct.unpack_from("<i", data, cstart)[0]
                tri_count = max(0, (clen - 4) // 12)
                total_tris += tri_count
                tex_name = ""
                if 0 <= brush_id < len(brushes):
                    tex_id = brushes[brush_id][1]
                    if 0 <= tex_id < len(textures):
                        tex_name = textures[tex_id]
                bmin_t = (m_min[0], m_min[1], m_min[2]) if mesh_verts > 0 else (0.0, 0.0, 0.0)
                bmax_t = (m_max[0], m_max[1], m_max[2]) if mesh_verts > 0 else (0.0, 0.0, 0.0)
                submeshes.append(
                    SubmeshStats(
                        submesh_index=len(submeshes),
                        material_id=brush_id,
                        texture_1=tex_name,
                        texture_2="",
                        vertex_count=mesh_verts,
                        triangle_count=tri_count,
                        bbox_min_m=bmin_t,
                        bbox_max_m=bmax_t,
                    )
                )
            p = cend

    while pos < root_end:
        tag = data[pos : pos + 4]
        clen = struct.unpack_from("<I", data, pos + 4)[0]
        cstart = pos + 8
        cend = cstart + clen
        if tag == b"TEXS":
            tp = cstart
            while tp < cend:
                tname, tp = _read_cstr(data, tp)
                textures.append(tname)
                tp += 28  # flags, blend, pos(2f), scale(2f), rot(1f)
        elif tag == b"BRUS":
            n_tex = struct.unpack_from("<i", data, cstart)[0]
            bp = cstart + 4
            while bp < cend:
                bname, bp = _read_cstr(data, bp)
                bp += 28  # rgba(4f), shininess(1f), blend(1i), fx(1i)
                first_tex = -1
                if n_tex > 0:
                    first_tex = struct.unpack_from("<i", data, bp)[0]
                    bp += 4 * n_tex
                brushes.append((bname, first_tex))
        elif tag == b"NODE":
            walk_node(cend, cstart)
        pos = cend

    if total_verts == 0:
        g_min = [0.0, 0.0, 0.0]
        g_max = [0.0, 0.0, 0.0]

    return MeshAudit(
        file_name=path.name,
        file_size_bytes=len(data),
        mesh_format="B3D",
        vertex_count=total_verts,
        triangle_count=total_tris,
        submesh_count=len(submeshes),
        material_count=len(brushes),
        bbox_min_m=(g_min[0], g_min[1], g_min[2]),
        bbox_max_m=(g_max[0], g_max[1], g_max[2]),
        submeshes=submeshes,
    )


def audit_mesh(path: Path) -> MeshAudit:
    """Inspect a .spm or .b3d mesh file and return triangle/bounds audit."""
    ext = path.suffix.lower()
    if ext == ".spm":
        return parse_spm(path)
    if ext == ".b3d":
        return parse_b3d(path)
    raise ValueError(f"Unsupported mesh extension '{path.suffix}' for {path.name}")
