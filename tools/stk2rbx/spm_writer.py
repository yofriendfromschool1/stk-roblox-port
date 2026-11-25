# SPDX-License-Identifier: GPL-3.0-or-later
"""Binary SuperTuxKart .spm (SPMN v1) mesh writer for test tracks & primitives.

Follows exact STK 1.5 binary layout:
  - Header & submeshes: src/graphics/sp_mesh_loader.cpp:L87-L441 (STK 1.5)
  - Normal/UV packing:  lib/graphics_engine/include/mini_glm.hpp:L127-L291 (STK 1.5)
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

Vec3 = tuple[float, float, float]
Vec2 = tuple[float, float]
Rgb = tuple[int, int, int]


@dataclass
class SpmVertex:
    pos: Vec3
    normal: Vec3
    uv: Vec2
    color_rgb: Rgb | None = None


@dataclass
class SpmSubmesh:
    texture_1: str
    vertices: list[SpmVertex]
    indices: list[int]
    texture_2: str = ""


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _normalize(v: Vec3) -> Vec3:
    mag = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if mag < 1e-9:
        return (0.0, 1.0, 0.0)
    return (v[0] / mag, v[1] / mag, v[2] / mag)


def pack_normal_1010102(nx: float, ny: float, nz: float, extra_w: int = -1) -> int:
    """Pack a unit vector into 2_10_10_10_REV (MiniGLM::normalizedSignedFloatsTo1010102, mini_glm.hpp:L246-L291)."""
    ux, uy, uz = _normalize((nx, ny, nz))
    packed = 0
    for shift, comp in ((0, ux), (10, uy), (20, uz)):
        v = max(-1.0, min(1.0, comp))
        part = int(v * 511.0 + 0.5) if v > 0.0 else int(v * 512.0 - 0.5)
        packed |= (part & 0x3FF) << shift
    w_part = extra_w if extra_w >= 0 else 0
    packed |= (w_part & 0x3) << 30
    return packed


def pack_uv_f16(u: float, v: float) -> bytes:
    """Pack texture UV coordinates as IEEE-754 float16 pairs (sp_mesh_loader.cpp:L391)."""
    return struct.pack("<ee", u, v)


def _rotate_xyz(v: Vec3, rot_deg: Sequence[float]) -> Vec3:
    rx, ry, rz = (math.radians(a) for a in rot_deg)
    cx, sx = math.cos(rx), math.sin(rx)
    cy, sy = math.cos(ry), math.sin(ry)
    cz, sz = math.cos(rz), math.sin(rz)

    # Apply X, then Y, then Z rotation around local box axes
    x1, y1, z1 = v[0], v[1] * cx - v[2] * sx, v[1] * sx + v[2] * cx
    x2, y2, z2 = x1 * cy + z1 * sy, y1, -x1 * sy + z1 * cy
    return (x2 * cz - y2 * sz, x2 * sz + y2 * cz, z2)


def build_box_geometry(
    pos: Sequence[float],
    size: Sequence[float],
    rot_deg: Sequence[float] = (0.0, 0.0, 0.0),
    color_rgb: Rgb | None = None,
    uv_scale: float = 0.25,
) -> tuple[list[SpmVertex], list[int]]:
    """Build 24 vertices / 12 outward-wound triangles for an oriented box in STK space."""
    hx, hy, hz = 0.5 * size[0], 0.5 * size[1], 0.5 * size[2]

    # 6 faces: (local_normal, corners_in_local_space, u_span, v_span)
    faces: list[tuple[Vec3, list[Vec3], float, float]] = [
        ((0.0, 1.0, 0.0), [(-hx, hy, -hz), (hx, hy, -hz), (hx, hy, hz), (-hx, hy, hz)], size[0], size[2]),
        ((0.0, -1.0, 0.0), [(-hx, -hy, hz), (hx, -hy, hz), (hx, -hy, -hz), (-hx, -hy, -hz)], size[0], size[2]),
        ((1.0, 0.0, 0.0), [(hx, -hy, -hz), (hx, hy, -hz), (hx, hy, hz), (hx, -hy, hz)], size[2], size[1]),
        ((-1.0, 0.0, 0.0), [(-hx, -hy, hz), (-hx, hy, hz), (-hx, hy, -hz), (-hx, -hy, -hz)], size[2], size[1]),
        ((0.0, 0.0, 1.0), [(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)], size[0], size[1]),
        ((0.0, 0.0, -1.0), [(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)], size[0], size[1]),
    ]

    vertices: list[SpmVertex] = []
    indices: list[int] = []

    for local_n, local_corners, uspan, vspan in faces:
        base = len(vertices)
        world_n = _normalize(_rotate_xyz(local_n, rot_deg))
        uvs: list[Vec2] = [
            (0.0, 0.0),
            (uspan * uv_scale, 0.0),
            (uspan * uv_scale, vspan * uv_scale),
            (0.0, vspan * uv_scale),
        ]
        for lc, uv in zip(local_corners, uvs):
            rc = _rotate_xyz(lc, rot_deg)
            wp = (pos[0] + rc[0], pos[1] + rc[1], pos[2] + rc[2])
            vertices.append(SpmVertex(pos=wp, normal=world_n, uv=uv, color_rgb=color_rgb))

        for tri in ((base + 0, base + 1, base + 2), (base + 0, base + 2, base + 3)):
            p0 = vertices[tri[0]].pos
            p1 = vertices[tri[1]].pos
            p2 = vertices[tri[2]].pos
            if _dot(_cross(_sub(p1, p0), _sub(p2, p0)), world_n) < 0.0:
                indices.extend((tri[0], tri[2], tri[1]))
            else:
                indices.extend(tri)

    return vertices, indices


def write_spmn(path: Path, submeshes: Sequence[SpmSubmesh]) -> None:
    """Serialize submeshes into an STK 1.5 SPMN binary file (sp_mesh_loader.cpp:L87-L441)."""
    if not submeshes:
        raise ValueError("Cannot write empty SPM mesh with 0 submeshes")

    g_min = [float("inf"), float("inf"), float("inf")]
    g_max = [float("-inf"), float("-inf"), float("-inf")]

    materials: list[tuple[str, str]] = []
    mat_index: dict[tuple[str, str], int] = {}
    for sub in submeshes:
        if len(sub.vertices) == 0 or len(sub.indices) == 0:
            raise ValueError(f"Submesh '{sub.texture_1}' has empty geometry")
        if len(sub.vertices) > 65535:
            raise ValueError(
                f"Submesh '{sub.texture_1}' exceeds STK 65535 vertex limit ({len(sub.vertices)})"
            )
        if len(sub.indices) % 3 != 0:
            raise ValueError(f"Submesh '{sub.texture_1}' index count must be a multiple of 3")
        key = (sub.texture_1, sub.texture_2)
        if key not in mat_index:
            mat_index[key] = len(materials)
            materials.append(key)
        for v in sub.vertices:
            for axis in range(3):
                if v.pos[axis] < g_min[axis]:
                    g_min[axis] = v.pos[axis]
                if v.pos[axis] > g_max[axis]:
                    g_max[axis] = v.pos[axis]

    buf = bytearray()
    buf.extend(b"SP")
    buf.append((1 << 3) | 2)  # version = 1, type = 2 (SPMN)
    buf.append(0x03)  # flags: read_normal=1, read_vcolor=1, read_tangent=0 (quickTangent)
    buf.extend(struct.pack("<6f", *g_min, *g_max))

    buf.extend(struct.pack("<H", len(materials)))
    for tex1, tex2 in materials:
        b1 = tex1.encode("utf-8")
        b2 = tex2.encode("utf-8")
        if len(b1) > 255 or len(b2) > 255:
            raise ValueError(f"Texture name exceeds 255 bytes: {tex1!r}, {tex2!r}")
        buf.append(len(b1))
        buf.extend(b1)
        buf.append(len(b2))
        buf.extend(b2)

    buf.extend(struct.pack("<H", 1))  # sector_count = 1
    buf.extend(struct.pack("<H", len(submeshes)))

    for sub in submeshes:
        mat_id = mat_index[(sub.texture_1, sub.texture_2)]
        has_uv1 = len(sub.texture_1) > 0
        has_uv2 = len(sub.texture_2) > 0
        buf.extend(struct.pack("<IIH", len(sub.vertices), len(sub.indices), mat_id))

        for v in sub.vertices:
            buf.extend(struct.pack("<fff", *v.pos))
            buf.extend(struct.pack("<I", pack_normal_1010102(*v.normal)))
            if v.color_rgb is None:
                buf.append(128)
            else:
                buf.extend(bytes((255, int(v.color_rgb[0]) & 0xFF, int(v.color_rgb[1]) & 0xFF, int(v.color_rgb[2]) & 0xFF)))
            if has_uv1:
                buf.extend(pack_uv_f16(*v.uv))
                if has_uv2:
                    buf.extend(pack_uv_f16(0.0, 0.0))

        idx_fmt = "<H" if len(sub.vertices) > 255 else "<B"
        for idx in sub.indices:
            buf.extend(struct.pack(idx_fmt, idx))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(buf))
