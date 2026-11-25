# SPDX-License-Identifier: GPL-3.0-or-later
"""Coordinate frame and metric-to-stud conversions between STK 1.5 and Roblox.

STK uses +X right, +Y up, +Z forward in SI meters.
Roblox uses +X right, +Y up, -Z forward in studs (1 stud = 1.0 m).
"""

from __future__ import annotations

import math
from typing import Iterable, Sequence

METERS_PER_STUD: float = 1.0
STUDS_PER_METER: float = 1.0 / METERS_PER_STUD
MIN_PART_SIZE_STUDS: float = 0.2
MAX_PART_SIZE_STUDS: float = 2048.0

Vec3 = tuple[float, float, float]
Mat3 = list[list[float]]


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _norm(v: Vec3) -> float:
    return math.sqrt(_dot(v, v))


def _normalize(v: Vec3, fallback: Vec3 = (0.0, 1.0, 0.0)) -> Vec3:
    length = _norm(v)
    if length < 1e-9:
        return fallback
    return (v[0] / length, v[1] / length, v[2] / length)


def stk_to_rbx_pos(x: float, y: float, z: float) -> list[float]:
    """Convert STK metric coordinates (+Z forward) to Roblox studs (-Z forward)."""
    return [
        round(x * STUDS_PER_METER, 4),
        round(y * STUDS_PER_METER, 4),
        round(-z * STUDS_PER_METER, 4),
    ]


def stk_to_rbx_vec_dir(x: float, y: float, z: float) -> Vec3:
    """Convert a unitless/direction vector from STK (+Z fwd) to Roblox (-Z fwd)."""
    return (x, y, -z)


def stk_to_rbx_normal(nx: float, ny: float, nz: float) -> Vec3:
    """Transform a surface normal from STK (+Z fwd) to Roblox (-Z fwd).

    S = diag(1, 1, -1) is an improper reflection (det(S) = -1) converting
    left-handed Irrlicht to right-handed Roblox. For uniform scaling paired
    with S, (S^-1)^T = S, so reflecting Z and re-normalizing preserves unit
    normals while triangle winding must be reversed via flip_triangle_winding.
    """
    return _normalize((nx, ny, -nz), (0.0, 1.0, 0.0))


def flip_triangle_winding(indices: Sequence[int]) -> list[int]:
    """Reverse triangle index winding (i0, i1, i2) -> (i0, i2, i1).

    S = diag(1, 1, -1) has det(S) = -1 (an improper reflection), which flips
    triangle orientation when converting left-handed Irrlicht coordinates to
    right-handed Roblox coordinates. Winding reversal is therefore mandatory
    and must never be removed, or meshes will render inside-out.
    """
    if len(indices) % 3 != 0:
        raise ValueError(f"Expected multiple of 3 triangle indices, got {len(indices)}")
    flipped: list[int] = []
    for i in range(0, len(indices), 3):
        flipped.append(int(indices[i]))
        flipped.append(int(indices[i + 2]))
        flipped.append(int(indices[i + 1]))
    return flipped


def stk_to_rbx_size(
    sx: float,
    sy: float,
    sz: float,
    min_studs: float = MIN_PART_SIZE_STUDS,
    max_studs: float = MAX_PART_SIZE_STUDS,
) -> tuple[list[float], list[float], bool]:
    """Scale STK meter extents to Roblox studs and clamp to BasePart limits.

    Returns (clamped_studs, raw_studs, exceeds_2048).
    """
    raw = [
        round(abs(sx) * STUDS_PER_METER, 4),
        round(abs(sy) * STUDS_PER_METER, 4),
        round(abs(sz) * STUDS_PER_METER, 4),
    ]
    exceeds = any(v > max_studs for v in raw)
    clamped = [
        round(max(min_studs, min(max_studs, v)), 4)
        for v in raw
    ]
    return clamped, raw, exceeds


def _mat3_mul(a: Mat3, b: Mat3) -> Mat3:
    return [
        [
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]
            for j in range(3)
        ]
        for i in range(3)
    ]


def stk_hpr_to_rbx_matrix(rot_x_deg: float, rot_y_deg: float, rot_z_deg: float) -> Mat3:
    """Convert STK XML `hpr` degrees (Irrlicht XYZ Euler) to a Roblox 3x3 basis.

    Despite the attribute name `hpr`, STK passes the three values directly into
    `irr::core::vector3df(X, Y, Z)` and calls `ISceneNode::setRotation`
    (`src/tracks/track_object_presentation.cpp:L76, L137` (STK 1.5)). Irrlicht
    `CMatrix4::setRotationRadians` (`lib/irrlicht/include/matrix4.h:L828-L855`)
    builds R_irr = Rz(Z) * Ry(Y) * Rx(X) acting on column vectors via
    `rotateVect` (`matrix4.h:L1104-L1110`).
    Because the coordinate reflection S = diag(1, 1, -1) (det(S) = -1) is
    applied twice in the similarity transform R_rbx = S * R_irr * S, the
    resulting orientation matrix R_rbx has det(R_rbx) = det(S)^2 * det(R_irr)
    = (-1)^2 * (+1) = +1 (a proper RH orientation basis), while position/mesh
    vertices transformed once by S require triangle winding reversal.
    """
    rx_rad = math.radians(rot_x_deg)
    ry_rad = math.radians(rot_y_deg)
    rz_rad = math.radians(rot_z_deg)

    cr, sr = math.cos(rx_rad), math.sin(rx_rad)
    cp, sp = math.cos(ry_rad), math.sin(ry_rad)
    cy, sy = math.cos(rz_rad), math.sin(rz_rad)

    rx = [[1.0, 0.0, 0.0], [0.0, cr, -sr], [0.0, sr, cr]]
    ry = [[cp, 0.0, sp], [0.0, 1.0, 0.0], [-sp, 0.0, cp]]
    rz = [[cy, -sy, 0.0], [sy, cy, 0.0], [0.0, 0.0, 1.0]]
    r_irr = _mat3_mul(rz, _mat3_mul(ry, rx))

    # Similarity transform S * R_irr * S: S = diag(1, 1, -1) has det(S) = -1,
    # applied on both sides so R_rbx has det = (-1)^2 * (+1) = +1.
    r_rbx = [
        [r_irr[0][0], r_irr[0][1], -r_irr[0][2]],
        [r_irr[1][0], r_irr[1][1], -r_irr[1][2]],
        [-r_irr[2][0], -r_irr[2][1], r_irr[2][2]],
    ]
    return [[round(val, 6) for val in row] for row in r_rbx]


def stk_heading_to_rbx_matrix(heading_deg: float) -> Mat3:
    """Convert an STK <start h="..."/> Y-axis heading angle to Roblox 3x3 basis.

    Mirrors `src/tracks/track.cpp:L777-L798, L2465-L2474` (STK 1.5).
    """
    return stk_hpr_to_rbx_matrix(0.0, heading_deg, 0.0)


def _basis_from_axes(right: Vec3, up: Vec3, back: Vec3) -> Mat3:
    """Build column-major Roblox orientation matrix [right | up | back] (det = +1)."""
    return [
        [round(right[0], 6), round(up[0], 6), round(back[0], 6)],
        [round(right[1], 6), round(up[1], 6), round(back[1], 6)],
        [round(right[2], 6), round(up[2], 6), round(back[2], 6)],
    ]


def quad_to_rbx_transform(
    p0: Iterable[float],
    p1: Iterable[float],
    p2: Iterable[float],
    p3: Iterable[float],
) -> tuple[list[float], Mat3, list[float]]:
    """Compute Roblox position, orientation, and slab size for an STK quad.

    In STK quads.xml: p0--p1 is the entry edge, p3--p2 is the exit edge.
    """
    q0 = tuple(float(v) for v in p0)
    q1 = tuple(float(v) for v in p1)
    q2 = tuple(float(v) for v in p2)
    q3 = tuple(float(v) for v in p3)

    cx = 0.25 * (q0[0] + q1[0] + q2[0] + q3[0])
    cy = 0.25 * (q0[1] + q1[1] + q2[1] + q3[1])
    cz = 0.25 * (q0[2] + q1[2] + q2[2] + q3[2])

    # Midpoints in STK coordinates
    front_mid = (0.5 * (q2[0] + q3[0]), 0.5 * (q2[1] + q3[1]), 0.5 * (q2[2] + q3[2]))
    back_mid = (0.5 * (q0[0] + q1[0]), 0.5 * (q0[1] + q1[1]), 0.5 * (q0[2] + q1[2]))
    left_mid = (0.5 * (q0[0] + q3[0]), 0.5 * (q0[1] + q3[1]), 0.5 * (q0[2] + q3[2]))
    right_mid = (0.5 * (q1[0] + q2[0]), 0.5 * (q1[1] + q2[1]), 0.5 * (q1[2] + q2[2]))

    fwd_stk = (front_mid[0] - back_mid[0], front_mid[1] - back_mid[1], front_mid[2] - back_mid[2])
    side_stk = (right_mid[0] - left_mid[0], right_mid[1] - left_mid[1], right_mid[2] - left_mid[2])

    length_m = max(_norm(fwd_stk), 0.2)
    width_m = max(_norm(side_stk), 0.2)

    # Convert directions to Roblox (+X right, +Y up, -Z forward)
    fwd_rbx = _normalize(stk_to_rbx_vec_dir(*fwd_stk), (0.0, 0.0, -1.0))
    side_rbx = _normalize(stk_to_rbx_vec_dir(*side_stk), (1.0, 0.0, 0.0))

    # Build orthonormal right-handed basis: back = -fwd, right = up x back
    back_rbx = (-fwd_rbx[0], -fwd_rbx[1], -fwd_rbx[2])
    up_rbx = _normalize(_cross(back_rbx, side_rbx), (0.0, 1.0, 0.0))
    # Ensure up points generally +Y (swap if quad winding was flipped)
    if up_rbx[1] < 0.0:
        up_rbx = (-up_rbx[0], -up_rbx[1], -up_rbx[2])
    right_rbx = _normalize(_cross(up_rbx, back_rbx), (1.0, 0.0, 0.0))
    up_rbx = _normalize(_cross(back_rbx, right_rbx), (0.0, 1.0, 0.0))

    pos_rbx = stk_to_rbx_pos(cx, cy, cz)
    # Offset slab slightly below the quad surface so road top aligns with quad Y
    pos_rbx[1] = round(pos_rbx[1] - 0.25, 4)

    size_rbx, _, _ = stk_to_rbx_size(width_m, 0.14, length_m, min_studs=0.5)
    size_rbx[1] = 0.5  # fixed 0.5 stud driveline slab thickness

    return pos_rbx, _basis_from_axes(right_rbx, up_rbx, back_rbx), size_rbx


def check_line_to_rbx_transform(
    p1: Iterable[float],
    p2: Iterable[float],
    height_m: float = 5.0,
) -> tuple[list[float], Mat3, list[float]]:
    """Compute Roblox box CFrame and Size spanning a check-line segment."""
    a = tuple(float(v) for v in p1)
    b = tuple(float(v) for v in p2)
    cx = 0.5 * (a[0] + b[0])
    cy = 0.5 * (a[1] + b[1]) + 0.3 * height_m
    cz = 0.5 * (a[2] + b[2])

    span_stk = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    span_m = max(_norm(span_stk), 1.0)
    span_rbx = _normalize(stk_to_rbx_vec_dir(*span_stk), (1.0, 0.0, 0.0))

    up_rbx: Vec3 = (0.0, 1.0, 0.0)
    back_rbx = _normalize(_cross(span_rbx, up_rbx), (0.0, 0.0, 1.0))
    right_rbx = _normalize(_cross(up_rbx, back_rbx), (1.0, 0.0, 0.0))

    pos_rbx = stk_to_rbx_pos(cx, cy, cz)
    size_rbx, _, _ = stk_to_rbx_size(span_m, height_m, 0.5, min_studs=1.0)
    return pos_rbx, _basis_from_axes(right_rbx, up_rbx, back_rbx), size_rbx
