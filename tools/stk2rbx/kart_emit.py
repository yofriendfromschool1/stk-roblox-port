# SPDX-License-Identifier: GPL-3.0-or-later
"""Parse STK 1.5 kart assets (`kart.xml`, `SPMN`/`SPMA` `.spm` meshes) and emit static assemblies.

Upstream citations (STK 1.5):
- `src/karts/kart_model.cpp:L125-L253, L426-L520, L624-L906` (`KartModel` loadInfo/attachModel/loadModels)
- `src/graphics/sp_mesh_loader.cpp:L255-L445, L554-L766` (`SPMeshLoader` SPMN/SPMA binary layout)
- `lib/graphics_engine/include/ge_animation.hpp:L43-L145` (`LocRotScale` and `Armature::read`)
- `data/official_karts.xml:L18` (Tux collision chassis dimensions `0.821 x 0.675 x 1.437`)
"""

from __future__ import annotations

import base64
import json
import math
import struct
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as _xml_escape
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Optional

from .coords import (
    METERS_PER_STUD,
    STUDS_PER_METER,
    flip_triangle_winding,
    stk_hpr_to_rbx_matrix,
    stk_to_rbx_normal,
    stk_to_rbx_pos,
    stk_to_rbx_size,
)
from .rbx_emit import IDENTITY_MAT3, _encode_attributes, _make_part
from .xml_parser import MaterialData, parse_materials_xml

Vec2 = tuple[float, float]
Vec3 = tuple[float, float, float]

WHEEL_SLOTS = (
    ("front-left", "WheelFrontLeft"),
    ("front-right", "WheelFrontRight"),
    ("rear-left", "WheelRearLeft"),
    ("rear-right", "WheelRearRight"),
)

FLIP_Y180_MAT3 = [
    [-1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, -1.0],
]

BODY_TEXTURE_PART_NAMES = {
    "engine.png": "Body_Engine",
    "tuxkart.png": "Body_Chassis",
    "wheel.png": "Body_Steering",
}

OMITTED_UNVERIFIED_TEXTURES = {
    "",
    "gfxglow_white_a.png",
    "gfxglow_blue_a.png",
    "gfxglow_red_a.png",
    "stk_conelight_a.png",
    "stk_headlight_halo_a.png",
}

CC0_SUBSTITUTE_TEXTURES = {
    "stk_headlight_a.png": "cc0_headlight_lens.png",
    "stk_darkgraymetal_a.png": "cc0_dark_gray_metal.png",
    "stk_generic_sand_b.png": "cc0_generic_sand.png",
    "stktex_generic_underwaterrock_a.png": "cc0_underwater_rock.png",
}


def resolve_kart_texture_name(raw_tex: str) -> str:
    return CC0_SUBSTITUTE_TEXTURES.get(raw_tex.lower(), raw_tex)


def is_omitted_texture(raw_tex: str) -> bool:
    return raw_tex.strip().lower() in OMITTED_UNVERIFIED_TEXTURES


def _parse_vec3(raw: Optional[str], default: Vec3 = (0.0, 0.0, 0.0)) -> Vec3:
    if not raw:
        return default
    parts = raw.replace(",", " ").split()
    if len(parts) < 3:
        return default
    return (float(parts[0]), float(parts[1]), float(parts[2]))


def _unpack_10bit_signed(val: int) -> float:
    val &= 0x3FF
    return (val - 1024) / 511.0 if val >= 512 else val / 511.0


def _sanitize_float(val: float, fallback: float = 0.0) -> float:
    return val if math.isfinite(val) else fallback


def _bbox_from_points(points: list[Vec3]) -> tuple[Vec3, Vec3]:
    if not points:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    zs = [p[2] for p in points]
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def _bbox_size(bmin: Vec3, bmax: Vec3) -> Vec3:
    return (bmax[0] - bmin[0], bmax[1] - bmin[1], bmax[2] - bmin[2])


def _bbox_center(bmin: Vec3, bmax: Vec3) -> Vec3:
    return (
        0.5 * (bmin[0] + bmax[0]),
        0.5 * (bmin[1] + bmax[1]),
        0.5 * (bmin[2] + bmax[2]),
    )


def _merge_bboxes(boxes: list[tuple[Vec3, Vec3]]) -> tuple[Vec3, Vec3]:
    if not boxes:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    return (
        (min(b[0][0] for b in boxes), min(b[0][1] for b in boxes), min(b[0][2] for b in boxes)),
        (max(b[1][0] for b in boxes), max(b[1][1] for b in boxes), max(b[1][2] for b in boxes)),
    )


@dataclass
class WheelSpec:
    slot: str
    node_name: str
    position_m: Vec3
    model_file: str
    min_suspension_m: float = -0.07
    max_suspension_m: float = 0.20


@dataclass
class NitroEmitterSpec:
    name: str
    position_m: Vec3


@dataclass
class HeadlightSpec:
    position_m: Vec3
    rotation_deg: Vec3
    scale: Vec3
    bone: str
    model_file: str


@dataclass
class HatSpec:
    position_m: Vec3
    rotation_deg: Vec3
    scale: Vec3
    bone: str


@dataclass
class KartSpec:
    name: str
    version: int
    model_file: str
    icon_file: str
    minimap_icon_file: str
    shadow_file: str
    kart_type: str
    groups: str
    rgb: Vec3
    engine_sound: str
    animations: dict[str, int]
    wheels: list[WheelSpec]
    nitro_emitters: list[NitroEmitterSpec]
    headlights: list[HeadlightSpec]
    hat: Optional[HatSpec]
    exhaust_file: str


@dataclass
class SpmArmatureInfo:
    bind_frame: int
    armature_count: int
    joint_used: int
    joint_total: int
    joint_names: list[str]
    parent_indices: list[int]
    keyframe_count: int
    keyframe_indices: list[int]


@dataclass
class SpmSubmeshGeom:
    submesh_index: int
    material_id: int
    texture_1: str
    texture_2: str
    positions_stk: list[Vec3]
    normals_stk: list[Vec3]
    uv1: list[Vec2]
    indices_stk: list[int]
    bbox_min_stk: Vec3
    bbox_max_stk: Vec3


@dataclass
class SpmMeshData:
    file_name: str
    mesh_format: str
    version: int
    flags: int
    header_bbox_min_stk: Vec3
    header_bbox_max_stk: Vec3
    materials: list[tuple[str, str]]
    submeshes: list[SpmSubmeshGeom]
    bbox_min_stk: Vec3
    bbox_max_stk: Vec3
    armature: Optional[SpmArmatureInfo]


@dataclass
class RbxSubmeshGeom:
    texture_1: str
    texture_2: str
    positions_studs: list[Vec3]
    normals_rbx: list[Vec3]
    uv1: list[Vec2]
    indices_rbx: list[int]
    bbox_min_studs: Vec3
    bbox_max_studs: Vec3


def parse_kart_xml(kart_xml_path: Path) -> KartSpec:
    """Parse STK `kart.xml` (`src/karts/kart_model.cpp:L167-L253 (STK 1.5)`)."""
    root = ET.parse(kart_xml_path).getroot()

    sounds_el = root.find("sounds")
    engine_sound = sounds_el.get("engine", "small") if sounds_el is not None else "small"

    animations: dict[str, int] = {}
    anim_el = root.find("animations")
    if anim_el is not None:
        for k, v in anim_el.attrib.items():
            animations[k] = int(v)

    wheels: list[WheelSpec] = []
    wheels_el = root.find("wheels")
    if wheels_el is not None:
        for slot, node_name in WHEEL_SLOTS:
            w_el = wheels_el.find(slot)
            if w_el is None:
                continue
            wheels.append(
                WheelSpec(
                    slot=slot,
                    node_name=node_name,
                    position_m=_parse_vec3(w_el.get("position")),
                    model_file=w_el.get("model", ""),
                    min_suspension_m=float(w_el.get("min-suspension", "-0.07")),
                    max_suspension_m=float(w_el.get("max-suspension", "0.20")),
                )
            )

    nitro_emitters: list[NitroEmitterSpec] = []
    nitro_el = root.find("nitro-emitter")
    if nitro_el is not None:
        for tag in ("nitro-emitter-a", "nitro-emitter-b"):
            ne = nitro_el.find(tag)
            if ne is not None:
                nitro_emitters.append(
                    NitroEmitterSpec(name=tag, position_m=_parse_vec3(ne.get("position")))
                )

    headlights: list[HeadlightSpec] = []
    hl_el = root.find("headlights")
    if hl_el is not None:
        for obj in hl_el.findall("object"):
            headlights.append(
                HeadlightSpec(
                    position_m=_parse_vec3(obj.get("position")),
                    rotation_deg=_parse_vec3(obj.get("rotation")),
                    scale=_parse_vec3(obj.get("scale"), (1.0, 1.0, 1.0)),
                    bone=obj.get("bone", ""),
                    model_file=obj.get("model", ""),
                )
            )

    hat: Optional[HatSpec] = None
    hat_el = root.find("hat")
    if hat_el is not None:
        hat = HatSpec(
            position_m=_parse_vec3(hat_el.get("position")),
            rotation_deg=_parse_vec3(hat_el.get("rotation")),
            scale=_parse_vec3(hat_el.get("scale"), (1.0, 1.0, 1.0)),
            bone=hat_el.get("bone", ""),
        )

    exhaust_el = root.find("exhaust")
    exhaust_file = exhaust_el.get("file", "") if exhaust_el is not None else ""

    return KartSpec(
        name=root.get("name", kart_xml_path.parent.name),
        version=int(root.get("version", "0")),
        model_file=root.get("model-file", ""),
        icon_file=root.get("icon-file", ""),
        minimap_icon_file=root.get("minimap-icon-file", ""),
        shadow_file=root.get("shadow-file", ""),
        kart_type=root.get("type", "medium"),
        groups=root.get("groups", "standard"),
        rgb=_parse_vec3(root.get("rgb"), (1.0, 1.0, 1.0)),
        engine_sound=engine_sound,
        animations=animations,
        wheels=wheels,
        nitro_emitters=nitro_emitters,
        headlights=headlights,
        hat=hat,
        exhaust_file=exhaust_file,
    )


def read_spm_mesh(spm_path: Path) -> SpmMeshData:
    """Read STK binary `.spm` (both static `SPMN` and skinned `SPMA` straight-pose geometry).

    Mirrors `src/graphics/sp_mesh_loader.cpp:L255-L445, L554-L715 (STK 1.5)` and
    `lib/graphics_engine/include/ge_animation.hpp:L60-L145 (STK 1.5)`.
    """
    data = spm_path.read_bytes()
    if len(data) < 32 or data[:2] != b"SP":
        raise ValueError(f"{spm_path.name}: expected 'SP' header")

    header_byte = data[2]
    version = header_byte >> 3
    if version != 1:
        raise ValueError(f"{spm_path.name}: unsupported SPM version {version}")

    type_code = header_byte & ~0x08
    if type_code == 0:
        raise ValueError(f"{spm_path.name}: SPMS space-partitioned mesh unsupported")
    mesh_format = "SPMA" if type_code == 1 else "SPMN"
    is_skinned = type_code == 1

    flags = data[3]
    read_normal = bool(flags & 0x01)
    read_vcolor = bool((flags >> 1) & 0x01)
    read_tangent = bool((flags >> 2) & 0x01)

    off = 4
    hx0, hy0, hz0, hx1, hy1, hz1 = struct.unpack_from("<6f", data, off)
    off += 24

    mat_count = struct.unpack_from("<H", data, off)[0]
    off += 2
    materials: list[tuple[str, str]] = []
    for _ in range(mat_count):
        l1 = data[off]
        off += 1
        t1 = data[off : off + l1].decode("utf-8", errors="replace") if l1 > 0 else ""
        off += l1
        l2 = data[off]
        off += 1
        t2 = data[off : off + l2].decode("utf-8", errors="replace") if l2 > 0 else ""
        off += l2
        materials.append((t1, t2))

    sector_count = struct.unpack_from("<H", data, off)[0]
    off += 2
    submeshes: list[SpmSubmeshGeom] = []

    for _ in range(sector_count):
        sub_count = struct.unpack_from("<H", data, off)[0]
        off += 2
        for _ in range(sub_count):
            v_count, i_count, mat_id = struct.unpack_from("<IIH", data, off)
            off += 10
            if mat_id >= len(materials):
                raise ValueError(f"{spm_path.name}: invalid material id {mat_id}")
            tex1, tex2 = materials[mat_id]
            uv_one = len(tex1) > 0
            uv_two = len(tex2) > 0

            positions: list[Vec3] = []
            normals: list[Vec3] = []
            uv1_list: list[Vec2] = []

            for _ in range(v_count):
                px, py, pz = struct.unpack_from("<fff", data, off)
                off += 12
                positions.append((px, py, pz))

                if read_normal:
                    pn = struct.unpack_from("<I", data, off)[0]
                    off += 4
                    normals.append(
                        (
                            _unpack_10bit_signed(pn),
                            _unpack_10bit_signed(pn >> 10),
                            _unpack_10bit_signed(pn >> 20),
                        )
                    )
                else:
                    normals.append((0.0, 1.0, 0.0))

                if read_vcolor:
                    ci = data[off]
                    off += 1
                    if ci != 128:
                        off += 3

                if uv_one:
                    u, v = struct.unpack_from("<ee", data, off)
                    off += 4
                    uv1_list.append((_sanitize_float(u), _sanitize_float(v)))
                    if uv_two:
                        off += 4
                    if read_tangent:
                        off += 4
                else:
                    uv1_list.append((0.0, 0.0))

                if is_skinned:
                    # 4x int16 joint_idx + 4x float16 weights (sp_mesh_loader.cpp:L405-L418)
                    off += 16

            idx_fmt = "<I" if v_count > 65535 else ("<H" if v_count > 255 else "<B")
            idx_sz = struct.calcsize(idx_fmt)
            indices = [struct.unpack_from(idx_fmt, data, off + k * idx_sz)[0] for k in range(i_count)]
            off += i_count * idx_sz

            s_min, s_max = _bbox_from_points(positions)
            submeshes.append(
                SpmSubmeshGeom(
                    submesh_index=len(submeshes),
                    material_id=mat_id,
                    texture_1=tex1,
                    texture_2=tex2,
                    positions_stk=positions,
                    normals_stk=normals,
                    uv1=uv1_list,
                    indices_stk=indices,
                    bbox_min_stk=s_min,
                    bbox_max_stk=s_max,
                )
            )

    armature: Optional[SpmArmatureInfo] = None
    if is_skinned and off < len(data):
        arm_count, bind_frame = struct.unpack_from("<BH", data, off)
        off += 3
        all_names: list[str] = []
        all_parents: list[int] = []
        all_kf_indices: list[int] = []
        total_used = 0
        total_joints = 0
        max_kf_count = 0
        for _ in range(arm_count):
            j_used, j_total = struct.unpack_from("<HH", data, off)
            off += 4
            total_used += j_used
            total_joints += j_total
            for _ in range(j_total):
                nlen = data[off]
                off += 1
                all_names.append(data[off : off + nlen].decode("utf-8", errors="replace"))
                off += nlen
            # m_joint_matrices (LocRotScale = 10 floats = 40 bytes per joint)
            off += j_total * 40
            parents = list(struct.unpack_from(f"<{j_total}h", data, off))
            off += j_total * 2
            all_parents.extend(parents)
            kf_count = struct.unpack_from("<H", data, off)[0]
            off += 2
            max_kf_count = max(max_kf_count, kf_count)
            for _ in range(kf_count):
                kf_idx = struct.unpack_from("<H", data, off)[0]
                off += 2
                all_kf_indices.append(kf_idx)
                off += j_total * 40
        armature = SpmArmatureInfo(
            bind_frame=bind_frame,
            armature_count=arm_count,
            joint_used=total_used,
            joint_total=total_joints,
            joint_names=all_names,
            parent_indices=all_parents,
            keyframe_count=max_kf_count,
            keyframe_indices=all_kf_indices,
        )

    g_min, g_max = _merge_bboxes([(s.bbox_min_stk, s.bbox_max_stk) for s in submeshes])
    return SpmMeshData(
        file_name=spm_path.name,
        mesh_format=mesh_format,
        version=version,
        flags=flags,
        header_bbox_min_stk=(hx0, hy0, hz0),
        header_bbox_max_stk=(hx1, hy1, hz1),
        materials=materials,
        submeshes=submeshes,
        bbox_min_stk=g_min,
        bbox_max_stk=g_max,
        armature=armature,
    )


def convert_submesh_to_rbx(sub: SpmSubmeshGeom) -> RbxSubmeshGeom:
    """Transform STK submesh geometry to Roblox space (`S = diag(1, 1, -1)` + winding flip)."""
    positions_studs: list[Vec3] = [
        (x * STUDS_PER_METER, y * STUDS_PER_METER, -z * STUDS_PER_METER)
        for (x, y, z) in sub.positions_stk
    ]
    normals_rbx: list[Vec3] = [stk_to_rbx_normal(*n) for n in sub.normals_stk]
    indices_rbx = flip_triangle_winding(sub.indices_stk)
    bmin, bmax = _bbox_from_points(positions_studs)
    return RbxSubmeshGeom(
        texture_1=sub.texture_1,
        texture_2=sub.texture_2,
        positions_studs=positions_studs,
        normals_rbx=normals_rbx,
        uv1=list(sub.uv1),
        indices_rbx=indices_rbx,
        bbox_min_studs=bmin,
        bbox_max_studs=bmax,
    )


def verify_submesh_outward_winding(sub_rbx: RbxSubmeshGeom, max_opposed_ratio: float = 0.05) -> None:
    """Assert Z-reflected + flipped triangles face outward along vertex normals."""
    vs = sub_rbx.positions_studs
    ns = sub_rbx.normals_rbx
    idxs = sub_rbx.indices_rbx
    checked = 0
    all_opposed = 0
    for k in range(0, len(idxs), 3):
        i0, i1, i2 = idxs[k], idxs[k + 1], idxs[k + 2]
        p0, p1, p2 = vs[i0], vs[i1], vs[i2]
        e1 = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
        e2 = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
        cx = e1[1] * e2[2] - e1[2] * e2[1]
        cy = e1[2] * e2[0] - e1[0] * e2[2]
        cz = e1[0] * e2[1] - e1[1] * e2[0]
        area = 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)
        if area < 1e-7:
            continue
        checked += 1
        if all(cx * ns[idx][0] + cy * ns[idx][1] + cz * ns[idx][2] < 0.0 for idx in (i0, i1, i2)):
            all_opposed += 1
    if checked > 0 and (all_opposed / checked) > max_opposed_ratio:
        raise AssertionError(
            f"Submesh {sub_rbx.texture_1}: {all_opposed}/{checked} triangles oppose vertex normals"
        )


@dataclass
class GlbNodeSpec:
    name: str
    translation_studs: Vec3
    submeshes: list[RbxSubmeshGeom]


def write_glb_scene(
    nodes: list[GlbNodeSpec],
    out_glb: Path,
    root_name: str = "Tux",
) -> None:
    """Write a multi-node / multi-primitive binary glTF 2.0 `.glb` file."""
    bin_buf = bytearray()
    buffer_views: list[dict[str, Any]] = []
    accessors: list[dict[str, Any]] = []
    gltf_meshes: list[dict[str, Any]] = []
    material_map: dict[str, int] = {}
    gltf_materials: list[dict[str, Any]] = []

    def _pad4() -> None:
        while len(bin_buf) % 4 != 0:
            bin_buf.append(0)

    def _get_mat_id(tex_name: str) -> int:
        key = tex_name or "default"
        if key not in material_map:
            material_map[key] = len(gltf_materials)
            gltf_materials.append({"name": Path(key).stem if "." in key else key})
        return material_map[key]

    def _append_view(raw: bytes, target: int) -> int:
        _pad4()
        offset = len(bin_buf)
        bin_buf.extend(raw)
        bv_idx = len(buffer_views)
        buffer_views.append(
            {
                "buffer": 0,
                "byteOffset": offset,
                "byteLength": len(raw),
                "target": target,
            }
        )
        return bv_idx

    mesh_nodes: list[dict[str, Any]] = []
    for node in nodes:
        primitives: list[dict[str, Any]] = []
        for sub in node.submeshes:
            pos_raw = bytearray()
            norm_raw = bytearray()
            uv_raw = bytearray()
            for (px, py, pz), (nx, ny, nz), (u, v) in zip(
                sub.positions_studs, sub.normals_rbx, sub.uv1
            ):
                pos_raw.extend(struct.pack("<3f", px, py, pz))
                norm_raw.extend(struct.pack("<3f", nx, ny, nz))
                uv_raw.extend(struct.pack("<2f", u, v))

            use_u32 = len(sub.positions_studs) > 65535
            idx_raw = bytearray()
            idx_fmt = "<I" if use_u32 else "<H"
            for idx in sub.indices_rbx:
                idx_raw.extend(struct.pack(idx_fmt, idx))

            bv_pos = _append_view(bytes(pos_raw), 34962)
            bv_norm = _append_view(bytes(norm_raw), 34962)
            bv_uv = _append_view(bytes(uv_raw), 34962)
            bv_idx = _append_view(bytes(idx_raw), 34963)

            acc_pos = len(accessors)
            accessors.append(
                {
                    "bufferView": bv_pos,
                    "componentType": 5126,
                    "count": len(sub.positions_studs),
                    "type": "VEC3",
                    "min": [round(x, 6) for x in sub.bbox_min_studs],
                    "max": [round(x, 6) for x in sub.bbox_max_studs],
                }
            )
            acc_norm = len(accessors)
            accessors.append(
                {
                    "bufferView": bv_norm,
                    "componentType": 5126,
                    "count": len(sub.normals_rbx),
                    "type": "VEC3",
                }
            )
            acc_uv = len(accessors)
            accessors.append(
                {
                    "bufferView": bv_uv,
                    "componentType": 5126,
                    "count": len(sub.uv1),
                    "type": "VEC2",
                }
            )
            acc_idx = len(accessors)
            accessors.append(
                {
                    "bufferView": bv_idx,
                    "componentType": 5125 if use_u32 else 5123,
                    "count": len(sub.indices_rbx),
                    "type": "SCALAR",
                }
            )

            primitives.append(
                {
                    "attributes": {
                        "POSITION": acc_pos,
                        "NORMAL": acc_norm,
                        "TEXCOORD_0": acc_uv,
                    },
                    "indices": acc_idx,
                    "material": _get_mat_id(sub.texture_1),
                    "mode": 4,
                }
            )

        mesh_idx = len(gltf_meshes)
        gltf_meshes.append({"name": node.name, "primitives": primitives})
        node_dict: dict[str, Any] = {"name": node.name, "mesh": mesh_idx}
        if any(abs(c) > 1e-7 for c in node.translation_studs):
            node_dict["translation"] = [round(c, 6) for c in node.translation_studs]
        mesh_nodes.append(node_dict)

    _pad4()
    if len(nodes) == 1 and root_name == nodes[0].name:
        gltf_nodes = mesh_nodes
    else:
        child_indices = list(range(1, len(mesh_nodes) + 1))
        gltf_nodes = [{"name": root_name, "children": child_indices}] + mesh_nodes

    gltf: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "OpenKart-stk2rbx-kart_emit"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": gltf_nodes,
        "meshes": gltf_meshes,
        "materials": gltf_materials,
        "buffers": [{"byteLength": len(bin_buf)}],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }

    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(json_bytes) % 4 != 0:
        json_bytes += b" "

    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_buf)
    header = struct.pack("<III", 0x46546C67, 2, total_len)
    json_chunk = struct.pack("<II", len(json_bytes), 0x4E4F534A) + json_bytes
    bin_chunk = struct.pack("<II", len(bin_buf), 0x004E4942) + bytes(bin_buf)

    out_glb.parent.mkdir(parents=True, exist_ok=True)
    out_glb.write_bytes(header + json_chunk + bin_chunk)


def _split_body_and_driver(
    kart_id: str,
    rbx_submeshes: list[RbxSubmeshGeom],
) -> tuple[list[RbxSubmeshGeom], list[RbxSubmeshGeom]]:
    """Split main kart SPMA mesh into driver (`*_body.png`) vs kart body submeshes."""
    driver_tex = f"{kart_id.lower()}_body.png"
    driver = [s for s in rbx_submeshes if s.texture_1.lower() == driver_tex]
    body = [s for s in rbx_submeshes if s.texture_1.lower() != driver_tex]
    if not body and driver:
        return driver, []
    return body, driver


def _part_metrics(submeshes: list[RbxSubmeshGeom], origin_studs: Vec3 = (0.0, 0.0, 0.0)) -> dict[str, Any]:
    bmin, bmax = _merge_bboxes([(s.bbox_min_studs, s.bbox_max_studs) for s in submeshes])
    world_min = (bmin[0] + origin_studs[0], bmin[1] + origin_studs[1], bmin[2] + origin_studs[2])
    world_max = (bmax[0] + origin_studs[0], bmax[1] + origin_studs[1], bmax[2] + origin_studs[2])
    return {
        "vertex_count": sum(len(s.positions_studs) for s in submeshes),
        "triangle_count": sum(len(s.indices_rbx) // 3 for s in submeshes),
        "materials": [s.texture_1 for s in submeshes],
        "local_bbox_min_studs": [round(v, 5) for v in bmin],
        "local_bbox_max_studs": [round(v, 5) for v in bmax],
        "size_studs": [round(v, 5) for v in _bbox_size(bmin, bmax)],
        "world_bbox_min_studs": [round(v, 5) for v in world_min],
        "world_bbox_max_studs": [round(v, 5) for v in world_max],
        "world_center_studs": [round(v, 5) for v in _bbox_center(world_min, world_max)],
    }


def _make_mesh_part(
    name: str,
    mesh_id: str,
    texture_id: str,
    size: list[float],
    pos: list[float],
    orient: list[list[float]],
    material: str = "SmoothPlastic",
    attributes: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    props: dict[str, Any] = {
        "Anchored": True,
        "CanCollide": False,
        "CanTouch": False,
        "CanQuery": False,
        "Massless": True,
        "Size": size,
        "Color": [1.0, 1.0, 1.0],
        "Material": material,
        "MeshId": mesh_id,
        "TextureID": texture_id,
        "RenderFidelity": "Precise",
        "CollisionFidelity": "Box",
        "CFrame": {
            "CFrame": {
                "position": pos,
                "orientation": orient,
            }
        },
    }
    merged_attrs: dict[str, Any] = {"MeshAssetId": mesh_id}
    if attributes:
        merged_attrs.update(attributes)
    props["Attributes"] = _encode_attributes(merged_attrs)
    return {
        "ClassName": "MeshPart",
        "Name": name,
        "Properties": props,
    }


def _body_subpart_name(texture_1: str, index: int) -> str:
    return BODY_TEXTURE_PART_NAMES.get(texture_1.lower(), f"Body_{index}")


RBX_MATERIAL_TOKENS: dict[str, int] = {
    "SmoothPlastic": 256,
    "Metal": 1088,
    "Rubber": 1216,
    "Plastic": 256,
}


def _encode_rbx_attrs_binary(attrs: dict[str, Any]) -> str:
    buf = bytearray(struct.pack("<I", len(attrs)))
    for k, v in attrs.items():
        kb = str(k).encode("utf-8")
        buf += struct.pack("<I", len(kb)) + kb
        if isinstance(v, bool):
            buf += struct.pack("<BB", 3, 1 if v else 0)
        elif isinstance(v, (int, float)):
            buf += struct.pack("<Bd", 6, float(v))
        else:
            vb = str(v).encode("utf-8")
            buf += struct.pack("<BI", 2, len(vb)) + vb
    return base64.b64encode(bytes(buf)).decode("ascii")


def _xml_cf(name: str, pos: list[float], orient: list[list[float]]) -> str:
    r00, r01, r02 = orient[0]
    r10, r11, r12 = orient[1]
    r20, r21, r22 = orient[2]
    return (
        f'<CoordinateFrame name="{name}">'
        f"<X>{pos[0]}</X><Y>{pos[1]}</Y><Z>{pos[2]}</Z>"
        f"<R00>{r00}</R00><R01>{r01}</R01><R02>{r02}</R02>"
        f"<R10>{r10}</R10><R11>{r11}</R11><R12>{r12}</R12>"
        f"<R20>{r20}</R20><R21>{r21}</R21><R22>{r22}</R22>"
        "</CoordinateFrame>"
    )


def _xml_vec3(name: str, v: list[float]) -> str:
    return f'<Vector3 name="{name}"><X>{v[0]}</X><Y>{v[1]}</Y><Z>{v[2]}</Z></Vector3>'


def emit_kart_rbxmx(kart_id: str, model_doc: dict[str, Any]) -> str:
    """Serialize a converted kart Model (with InitialSize baked onto MeshParts) to Rojo-compatible `.rbxmx`."""
    ref_id = 0

    def next_ref() -> str:
        nonlocal ref_id
        r = f"RBX{ref_id}"
        ref_id += 1
        return r

    def extract_attrs(props: dict[str, Any]) -> dict[str, Any]:
        raw = props.get("Attributes", {}).get("Attributes", {})
        out: dict[str, Any] = {}
        for k, entry in raw.items():
            if isinstance(entry, dict) and entry:
                out[k] = next(iter(entry.values()))
        return out

    lines: list[str] = ['<roblox version="4">', f'  <Item class="Model" referent="{next_ref()}">']
    m_props = model_doc.get("Properties", {})
    m_attrs = extract_attrs(m_props)
    lines.append("    <Properties>")
    lines.append(f'      <string name="Name">{_xml_escape(kart_id)}</string>')
    if m_attrs:
        lines.append(f'      <BinaryString name="AttributesSerialize">{_encode_rbx_attrs_binary(m_attrs)}</BinaryString>')
    lines.append("    </Properties>")

    for child in model_doc.get("Children", []):
        cname = child["Name"]
        cclass = child["ClassName"]
        cprops = child.get("Properties", {})
        cattrs = extract_attrs(cprops)
        lines.append(f'    <Item class="{cclass}" referent="{next_ref()}">')
        lines.append("      <Properties>")
        lines.append(f'        <string name="Name">{_xml_escape(cname)}</string>')
        if cclass == "MeshPart":
            mesh_id = _xml_escape(str(cprops["MeshId"]))
            tex_id = _xml_escape(str(cprops["TextureID"]))
            sz = cprops["Size"]
            cf = cprops["CFrame"]["CFrame"]
            mat_tok = RBX_MATERIAL_TOKENS.get(str(cprops.get("Material", "SmoothPlastic")), 256)
            lines.append('        <bool name="Anchored">true</bool>')
            lines.append('        <bool name="CanCollide">false</bool>')
            lines.append('        <bool name="CanTouch">false</bool>')
            lines.append('        <bool name="CanQuery">false</bool>')
            lines.append('        <bool name="Massless">true</bool>')
            lines.append(f'        <Content name="MeshId"><url>{mesh_id}</url></Content>')
            lines.append(f'        <Content name="TextureID"><url>{tex_id}</url></Content>')
            lines.append(f'        <token name="Material">{mat_tok}</token>')
            lines.append('        <token name="RenderFidelity">1</token>')
            lines.append('        <token name="CollisionFidelity">2</token>')
            lines.append(f'        {_xml_vec3("InitialSize", sz)}')
            lines.append(f'        {_xml_vec3("size", sz)}')
            lines.append(f'        {_xml_cf("CFrame", cf["position"], cf["orientation"])}')
        else:
            sz = cprops["Size"]
            cf = cprops["CFrame"]["CFrame"]
            trans = float(cprops.get("Transparency", 0.0))
            lines.append('        <bool name="Anchored">true</bool>')
            lines.append('        <bool name="CanCollide">false</bool>')
            lines.append('        <bool name="CanTouch">false</bool>')
            lines.append('        <bool name="CanQuery">false</bool>')
            lines.append('        <bool name="Massless">true</bool>')
            lines.append(f'        <float name="Transparency">{trans}</float>')
            lines.append(f'        {_xml_vec3("size", sz)}')
            lines.append(f'        {_xml_cf("CFrame", cf["position"], cf["orientation"])}')
        if cattrs:
            lines.append(f'        <BinaryString name="AttributesSerialize">{_encode_rbx_attrs_binary(cattrs)}</BinaryString>')
        lines.append("      </Properties>")
        for subchild in child.get("Children", []):
            scname = subchild["Name"]
            scf = subchild["Properties"]["CFrame"]["CFrame"]
            lines.append(f'      <Item class="{subchild["ClassName"]}" referent="{next_ref()}">')
            lines.append("        <Properties>")
            lines.append(f'          <string name="Name">{_xml_escape(scname)}</string>')
            lines.append(f'          {_xml_cf("CFrame", scf["position"], scf["orientation"])}')
            lines.append("        </Properties>")
            lines.append("      </Item>")
        lines.append("    </Item>")

    lines.append("  </Item>")
    lines.append("</roblox>")
    lines.append("")
    return "\n".join(lines)


def emit_kart_model_json(
    kart_id: str,
    spec: KartSpec,
    part_entries: list[dict[str, Any]],
    chassis_bounds_studs: tuple[Vec3, Vec3],
    assets_revision: str = "",
    assets_manifest: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """Build a Rojo 7 `.model.json` Model representing `Body + Driver + 4 Wheels` at `METERS_PER_STUD = 1.0`."""
    c_min, c_max = chassis_bounds_studs
    c_size_raw = _bbox_size(c_min, c_max)
    c_size, _, _ = stk_to_rbx_size(*c_size_raw, min_studs=0.1)
    c_center = _bbox_center(c_min, c_max)

    nitro_children: list[dict[str, Any]] = []
    for ne in spec.nitro_emitters:
        ne_pos = stk_to_rbx_pos(*ne.position_m)
        rel = [round(ne_pos[i] - c_center[i], 4) for i in range(3)]
        nitro_children.append(
            {
                "ClassName": "Attachment",
                "Name": "NitroEmitterA" if ne.name.endswith("-a") else "NitroEmitterB",
                "Properties": {
                    "CFrame": {
                        "CFrame": {
                            "position": rel,
                            "orientation": IDENTITY_MAT3,
                        }
                    }
                },
            }
        )

    chassis_root = _make_part(
        name="ChassisRoot",
        size=c_size,
        pos=[round(v, 4) for v in c_center],
        orient=IDENTITY_MAT3,
        color=[1.0, 0.25, 0.25],
        transparency=1.0,
        can_collide=False,
        can_touch=False,
        can_query=False,
        attributes={
            "RawWidthStuds": round(c_size_raw[0], 5),
            "RawHeightStuds": round(c_size_raw[1], 5),
            "RawLengthStuds": round(c_size_raw[2], 5),
        },
    )
    if nitro_children:
        chassis_root["Children"] = nitro_children

    manifest_parts = assets_manifest.get("parts", {}) if assets_manifest else {}
    children: list[dict[str, Any]] = [chassis_root]

    for entry in part_entries:
        subparts = entry.get("subparts") if assets_manifest and entry.get("subparts") else None
        if subparts:
            for sp in subparts:
                sp_name = sp["part_name"]
                sp_meta = manifest_parts.get(sp_name)
                if not sp_meta:
                    continue
                sp_pos = [round(v, 5) for v in sp["world_center_studs"]]
                sp_size, _, _ = stk_to_rbx_size(*sp["size_studs"], min_studs=0.05)
                flip_y180 = bool(sp_meta.get("importFlipY180", False))
                orient = FLIP_Y180_MAT3 if flip_y180 else IDENTITY_MAT3
                children.append(
                    _make_mesh_part(
                        name=sp_name,
                        mesh_id=sp_meta["meshId"],
                        texture_id=sp_meta["textureId"],
                        size=sp_size,
                        pos=sp_pos,
                        orient=orient,
                        material=sp_meta.get("robloxMaterial", "SmoothPlastic"),
                        attributes={
                            "GlbFile": entry["glb_file"],
                            "SourceMaterial": sp["texture_1"],
                            "VertexCount": sp["vertex_count"],
                            "TriangleCount": sp["triangle_count"],
                            "ImportFlipY180": flip_y180,
                            "LocalPosX": sp_pos[0],
                            "LocalPosY": sp_pos[1],
                            "LocalPosZ": sp_pos[2],
                        },
                    )
                )
            continue

        node_name = entry["node_name"]
        p_meta = manifest_parts.get(node_name)
        p_size, _, _ = stk_to_rbx_size(*entry["size_studs"], min_studs=0.05)
        p_pos = [round(v, 5) for v in entry["world_center_studs"]]
        attrs: dict[str, Any] = {
            "GlbFile": entry["glb_file"],
            "VertexCount": entry["vertex_count"],
            "TriangleCount": entry["triangle_count"],
            "Materials": ",".join(entry["materials"]),
            "LocalPosX": p_pos[0],
            "LocalPosY": p_pos[1],
            "LocalPosZ": p_pos[2],
        }
        if "wheel_slot" in entry:
            attrs["WheelSlot"] = entry["wheel_slot"]
            attrs["WheelOriginX"] = entry["origin_studs"][0]
            attrs["WheelOriginY"] = entry["origin_studs"][1]
            attrs["WheelOriginZ"] = entry["origin_studs"][2]
            attrs["WheelRadiusStuds"] = entry["wheel_radius_studs"]

        if p_meta:
            flip_y180 = bool(p_meta.get("importFlipY180", False))
            attrs["ImportFlipY180"] = flip_y180
            children.append(
                _make_mesh_part(
                    name=node_name,
                    mesh_id=p_meta["meshId"],
                    texture_id=p_meta["textureId"],
                    size=p_size,
                    pos=p_pos,
                    orient=FLIP_Y180_MAT3 if flip_y180 else IDENTITY_MAT3,
                    material=p_meta.get("robloxMaterial", "SmoothPlastic"),
                    attributes=attrs,
                )
            )
        else:
            color = [0.22, 0.24, 0.28] if "wheel_slot" in entry else (
                [0.15, 0.15, 0.2] if node_name == "Driver" else [0.85, 0.18, 0.18]
            )
            children.append(
                _make_part(
                    name=node_name,
                    size=p_size,
                    pos=[round(v, 4) for v in entry["world_center_studs"]],
                    orient=IDENTITY_MAT3,
                    color=color,
                    transparency=0.0,
                    can_collide=False,
                    can_touch=False,
                    can_query=False,
                    attributes=attrs,
                )
            )

    hat_attrs: dict[str, Any] = {}
    if spec.hat is not None:
        hat_pos = stk_to_rbx_pos(*spec.hat.position_m)
        hat_orient = stk_hpr_to_rbx_matrix(*spec.hat.rotation_deg)
        hat_attrs["HatBone"] = spec.hat.bone
        hat_attrs["HatSocketPosStuds"] = ",".join(str(v) for v in hat_pos)
        hat_attrs["HatSocketRot00"] = hat_orient[0][0]

    return {
        "ClassName": "Model",
        "Properties": {
            "Attributes": _encode_attributes(
                {
                    "SourceKart": kart_id,
                    "KartName": spec.name,
                    "KartType": spec.kart_type,
                    "SourceRevision": assets_revision,
                    "MetersPerStud": METERS_PER_STUD,
                    "StaticFirstPass": True,
                    "HasUploadedMeshes": bool(manifest_parts),
                    "AnimationOmitted": "SPMA bone animation deferred (docs/divergences.md)",
                    "HeadlightsExcluded": "headlight.spm excluded (un-audited external textures)",
                    **hat_attrs,
                }
            )
        },
        "Children": children,
    }


def convert_kart(
    kart_dir: Path,
    out_model: Path,
    out_glb_dir: Path,
    report_path: Optional[Path] = None,
    revision: str = "",
    assets_manifest_path: Optional[Path] = None,
) -> dict[str, Any]:
    """Convert one STK kart directory into static `.glb` meshes + Rojo `.model.json` + JSON audit report."""
    kart_id = kart_dir.name
    if not revision and (kart_dir / "svn_revision.txt").exists():
        revision = (kart_dir / "svn_revision.txt").read_text(encoding="utf-8").strip()

    assets_manifest: Optional[dict[str, Any]] = None
    if assets_manifest_path is not None and assets_manifest_path.exists():
        assets_manifest = json.loads(assets_manifest_path.read_text(encoding="utf-8"))

    spec = parse_kart_xml(kart_dir / "kart.xml")
    materials_path = kart_dir / "materials.xml"
    materials: list[MaterialData] = parse_materials_xml(materials_path) if materials_path.exists() else []

    main_spm = read_spm_mesh(kart_dir / spec.model_file)
    main_rbx_subs = [
        convert_submesh_to_rbx(s)
        for s in main_spm.submeshes
        if not is_omitted_texture(s.texture_1)
    ]
    for sub in main_rbx_subs:
        verify_submesh_outward_winding(sub)
        sub.texture_1 = resolve_kart_texture_name(sub.texture_1)

    # Also include structural speed-weighted objects (e.g. Gnu carpet, Xue propeller, Kiki tail, Sara rail)
    root_xml = ET.parse(kart_dir / "kart.xml").getroot()
    swo_el = root_xml.find("speed-weighted-objects")
    if swo_el is not None:
        for obj_el in swo_el.findall("object"):
            swo_model = obj_el.get("model", "")
            if not swo_model or not (kart_dir / swo_model).is_file():
                continue
            swo_spm = read_spm_mesh(kart_dir / swo_model)
            pos_m = _parse_vec3(obj_el.get("position"))
            off_rbx = stk_to_rbx_pos(*pos_m)
            for s in swo_spm.submeshes:
                if is_omitted_texture(s.texture_1):
                    continue
                rsub = convert_submesh_to_rbx(s)
                verify_submesh_outward_winding(rsub)
                rsub.texture_1 = resolve_kart_texture_name(rsub.texture_1)
                if any(abs(v) > 1e-6 for v in off_rbx):
                    rsub.positions_studs = [
                        (p[0] + off_rbx[0], p[1] + off_rbx[1], p[2] + off_rbx[2])
                        for p in rsub.positions_studs
                    ]
                    rsub.bbox_min_studs, rsub.bbox_max_studs = _bbox_from_points(rsub.positions_studs)
                main_rbx_subs.append(rsub)

    body_subs, driver_subs = _split_body_and_driver(kart_id, main_rbx_subs)
    combined_chassis_bounds = _merge_bboxes(
        [(s.bbox_min_studs, s.bbox_max_studs) for s in main_rbx_subs]
    )

    glb_nodes: list[GlbNodeSpec] = []
    part_entries: list[dict[str, Any]] = []

    out_glb_dir.mkdir(parents=True, exist_ok=True)

    if body_subs:
        body_glb_name = f"{kart_id}_body.glb"
        body_node = GlbNodeSpec(name="Body", translation_studs=(0.0, 0.0, 0.0), submeshes=body_subs)
        write_glb_scene([body_node], out_glb_dir / body_glb_name, root_name="Body")
        glb_nodes.append(body_node)
        metrics = _part_metrics(body_subs)
        metrics["node_name"] = "Body"
        metrics["glb_file"] = body_glb_name
        metrics["origin_studs"] = [0.0, 0.0, 0.0]
        metrics["subparts"] = []
        for idx, sub in enumerate(body_subs):
            sp_name = _body_subpart_name(sub.texture_1, idx)
            sp_glb_name = f"{kart_id}_{sp_name}.glb"
            write_glb_scene([GlbNodeSpec(name=sp_name, translation_studs=(0.0, 0.0, 0.0), submeshes=[sub])], out_glb_dir / sp_glb_name, root_name=sp_name)
            sp_m = _part_metrics([sub])
            sp_m["part_name"] = sp_name
            sp_m["texture_1"] = sub.texture_1
            sp_m["glb_file"] = sp_glb_name
            metrics["subparts"].append(sp_m)
        part_entries.append(metrics)

    if driver_subs:
        driver_glb_name = f"{kart_id}_driver.glb"
        driver_node = GlbNodeSpec(name="Driver", translation_studs=(0.0, 0.0, 0.0), submeshes=driver_subs)
        write_glb_scene([driver_node], out_glb_dir / driver_glb_name, root_name="Driver")
        glb_nodes.append(driver_node)
        metrics = _part_metrics(driver_subs)
        metrics["node_name"] = "Driver"
        metrics["glb_file"] = driver_glb_name
        metrics["origin_studs"] = [0.0, 0.0, 0.0]
        part_entries.append(metrics)

    for w in spec.wheels:
        if not w.model_file:
            continue
        w_spm = read_spm_mesh(kart_dir / w.model_file)
        w_subs = [
            convert_submesh_to_rbx(s)
            for s in w_spm.submeshes
            if not is_omitted_texture(s.texture_1)
        ]
        for sub in w_subs:
            verify_submesh_outward_winding(sub)
            sub.texture_1 = resolve_kart_texture_name(sub.texture_1)
        origin_pos = stk_to_rbx_pos(*w.position_m)
        origin_tuple: Vec3 = (origin_pos[0], origin_pos[1], origin_pos[2])
        w_glb_name = f"{Path(w.model_file).stem}.glb"
        w_local_node = GlbNodeSpec(name=w.node_name, translation_studs=(0.0, 0.0, 0.0), submeshes=w_subs)
        write_glb_scene([w_local_node], out_glb_dir / w_glb_name, root_name=w.node_name)

        glb_nodes.append(GlbNodeSpec(name=w.node_name, translation_studs=origin_tuple, submeshes=w_subs))
        metrics = _part_metrics(w_subs, origin_studs=origin_tuple)
        metrics["node_name"] = w.node_name
        metrics["glb_file"] = w_glb_name
        metrics["wheel_slot"] = w.slot
        metrics["origin_studs"] = list(origin_pos)
        metrics["wheel_radius_studs"] = round(0.5 * metrics["size_studs"][1], 5)
        part_entries.append(metrics)

    assembly_glb_path = out_glb_dir / f"{kart_id}_assembly.glb"
    write_glb_scene(glb_nodes, assembly_glb_path, root_name=spec.name)

    model_doc = emit_kart_model_json(
        kart_id=kart_id,
        spec=spec,
        part_entries=part_entries,
        chassis_bounds_studs=combined_chassis_bounds,
        assets_revision=revision,
        assets_manifest=assets_manifest,
    )
    out_model.parent.mkdir(parents=True, exist_ok=True)
    if out_model.suffix.lower() == ".rbxmx":
        out_model.write_text(emit_kart_rbxmx(kart_id, model_doc), encoding="utf-8")
    else:
        out_model.write_text(json.dumps(model_doc, indent=2) + "\n", encoding="utf-8")

    c_size = _bbox_size(*combined_chassis_bounds)
    trunc_3dp = [int(v * 1000) / 1000.0 for v in c_size]
    full_assembly_bounds = _merge_bboxes(
        [
            (
                (p["world_bbox_min_studs"][0], p["world_bbox_min_studs"][1], p["world_bbox_min_studs"][2]),
                (p["world_bbox_max_studs"][0], p["world_bbox_max_studs"][1], p["world_bbox_max_studs"][2]),
            )
            for p in part_entries
        ]
    )

    report: dict[str, Any] = {
        "kart_id": kart_id,
        "kart_name": spec.name,
        "assets_revision": revision,
        "meters_per_stud": METERS_PER_STUD,
        "main_mesh_format": main_spm.mesh_format,
        "armature": asdict(main_spm.armature) if main_spm.armature is not None else None,
        "body_driver_combined_bounds_studs": {
            "min": [round(v, 5) for v in combined_chassis_bounds[0]],
            "max": [round(v, 5) for v in combined_chassis_bounds[1]],
            "size": [round(v, 5) for v in c_size],
            "truncated_3dp": trunc_3dp,
        },
        "full_assembly_bounds_studs": {
            "min": [round(v, 5) for v in full_assembly_bounds[0]],
            "max": [round(v, 5) for v in full_assembly_bounds[1]],
            "size": [round(v, 5) for v in _bbox_size(*full_assembly_bounds)],
        },
        "total_vertices": sum(p["vertex_count"] for p in part_entries),
        "total_triangles": sum(p["triangle_count"] for p in part_entries),
        "materials": [asdict(m) for m in materials],
        "parts": part_entries,
        "assembly_glb": str(assembly_glb_path.as_posix()),
        "model_json": str(out_model.as_posix()),
    }

    if report_path is not None:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return report


def emit_kart_bounds_luau(reports: list[dict[str, Any]], out_path: Path) -> None:
    """Emit src/shared/kart/KartBoundsData.lua with expected submesh bounds for all converted karts."""
    lines = [
        "--!strict",
        "-- src/shared/kart/KartBoundsData.lua",
        "-- SPDX-License-Identifier: GPL-3.0-or-later",
        "-- AUTO-GENERATED by tools/stk2rbx/kart_emit.py (METERS_PER_STUD = 1.0, rev 18627).",
        "",
        "local KartBoundsData = {}",
        "",
        "KartBoundsData.TOLERANCE_STUDS = 0.005",
        "",
        "KartBoundsData.karts = table.freeze({",
    ]
    for rep in sorted(reports, key=lambda r: r["kart_id"]):
        kid = rep["kart_id"]
        lines.append(f'\t["{kid}"] = table.freeze({{')
        for p in rep.get("parts", []):
            subparts = p.get("subparts")
            if subparts:
                for sp in subparts:
                    sz = sp["size_studs"]
                    lines.append(
                        f'\t\t["{sp["part_name"]}"] = table.freeze({{ {sz[0]}, {sz[1]}, {sz[2]} }}),'
                    )
            else:
                sz = p["size_studs"]
                lines.append(
                    f'\t\t["{p["node_name"]}"] = table.freeze({{ {sz[0]}, {sz[1]}, {sz[2]} }}),'
                )
        lines.append("\t}),")
    lines.append("}) :: { [string]: { [string]: { number } } }")
    lines.append("")
    lines.append("return table.freeze(KartBoundsData)")
    lines.append("")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines), encoding="utf-8")
