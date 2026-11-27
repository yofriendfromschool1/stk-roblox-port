# SPDX-License-Identifier: GPL-3.0-or-later
"""Batch convert STK 1.5 item & powerup `.spm` meshes to Roblox `.glb` + `.model.json` at METERS_PER_STUD = 1.0."""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from .coords import METERS_PER_STUD, stk_to_rbx_size
from .kart_emit import (
    FLIP_Y180_MAT3,
    GlbNodeSpec,
    RbxSubmeshGeom,
    SpmMeshData,
    SpmSubmeshGeom,
    _bbox_from_points,
    _make_mesh_part,
    _part_metrics,
    convert_submesh_to_rbx,
    emit_kart_rbxmx,
    read_spm_mesh,
    verify_submesh_outward_winding,
    write_glb_scene,
)
from .rbx_emit import IDENTITY_MAT3, _encode_attributes


@dataclass(frozen=True)
class ItemDef:
    item_id: str
    spm_file: str
    xml_key: str
    emit_model_json: bool = True
    scale: float = 1.0


AUTHORITATIVE_ITEMS: tuple[ItemDef, ...] = (
    ItemDef("gift-box", "gift-box.spm", "bonus-box", emit_model_json=True),
    ItemDef("banana", "banana.spm", "banana", emit_model_json=True),
    ItemDef("nitrotank-big", "nitrotank-big.spm", "nitro-big", emit_model_json=True),
    ItemDef("nitrotank-small", "nitrotank-small.spm", "nitro-small", emit_model_json=True),
    ItemDef("bubblegum", "bubblegum.spm", "bubblegum", emit_model_json=True),
    ItemDef("bubblegum-nolok", "bubblegum-nolok.spm", "bubblegum-nolok", emit_model_json=True),
    ItemDef("easter_egg", "easter_egg.spm", "easter-egg", emit_model_json=True),
    ItemDef("bowling", "bowling.spm", "bowling", emit_model_json=True),
    ItemDef("cake", "cake.spm", "cake", emit_model_json=True),
    ItemDef("anchor", "anchor.spm", "anchor", emit_model_json=True),
    ItemDef("rubber_ball", "rubber_ball.spm", "rubber-ball", emit_model_json=True),
    ItemDef("parachute", "parachute.spm", "parachute", emit_model_json=True),
    ItemDef("plunger", "plunger.spm", "plunger", emit_model_json=True),
    ItemDef("swatter", "swatter.spm", "swatter", emit_model_json=True),
    ItemDef("bomb", "bomb.spm", "bomb", emit_model_json=True),
    ItemDef("bubblegum_shield", "bubblegum_shield.spm", "bubblegum-shield", emit_model_json=True),
    ItemDef("referee", "thunderbird.spm", "referee", emit_model_json=True, scale=0.2),
)

SUBMESH_FRIENDLY_NAMES: dict[str, str] = {
    "gift-box.png": "Box",
    "gift-loop.png": "Ribbon",
    "stk_mod_nitrobarrel.png": "Barrel",
    "stk_mod_nitrobottle.png": "Bottle",
    "stk_mod_nitrologo.png": "Logo",
    "thunderbird.png": "Body",
    "traffic_light.png": "TrafficLight",
}


def _subpart_name(texture_1: str, index: int, total: int) -> str:
    if total == 1:
        return "Main"
    mapped = SUBMESH_FRIENDLY_NAMES.get(texture_1.lower())
    if mapped:
        return mapped
    return f"Part_{index}"


def _split_bomb_spm(spm_path: Path, spm: SpmMeshData) -> list[tuple[str, SpmSubmeshGeom]]:
    """Split SPMA bomb.spm into rigid Body (261 tris) and Hand arrow (5 tris, joint 0)."""
    data = spm_path.read_bytes()
    off = 4  # sig(2) + byte2(1) + flags(1)
    flags = data[3]
    read_normal = bool(flags & 1)
    read_vcolor = bool(flags & 2)
    read_tangent = bool(flags & 4)
    off += 24  # header bbox
    mat_count = struct.unpack_from("<H", data, off)[0]
    off += 2
    mats: list[tuple[str, str]] = []
    for _ in range(mat_count):
        t1l = data[off]
        off += 1
        t1 = data[off : off + t1l].decode("utf-8", errors="replace")
        off += t1l
        t2l = data[off]
        off += 1
        t2 = data[off : off + t2l].decode("utf-8", errors="replace")
        off += t2l
        mats.append((t1, t2))
    sec_count = struct.unpack_from("<H", data, off)[0]
    off += 2
    hand_verts: set[int] = set()
    for _ in range(sec_count):
        mc = struct.unpack_from("<H", data, off)[0]
        off += 2
        for _ in range(mc):
            vc, ic, mid = struct.unpack_from("<IIH", data, off)
            off += 10
            t1, t2 = mats[mid]
            for vi in range(vc):
                off += 12
                if read_normal:
                    off += 4
                if read_vcolor:
                    ci = data[off]
                    off += 1
                    if ci != 128:
                        off += 3
                if len(t1) > 0:
                    off += 4
                    if len(t2) > 0:
                        off += 4
                    if read_tangent:
                        off += 4
                j = struct.unpack_from("<4h", data, off)
                off += 8
                w = struct.unpack_from("<4e", data, off)
                off += 8
                if any(jj == 0 and ww > 0.5 for jj, ww in zip(j, w)):
                    hand_verts.add(vi)
            idx_sz = 4 if vc > 65535 else (2 if vc > 255 else 1)
            off += ic * idx_sz

    src = spm.submeshes[0]

    def _extract(want_hand: bool) -> SpmSubmeshGeom:
        remap: dict[int, int] = {}
        pos: list[tuple[float, float, float]] = []
        nrm: list[tuple[float, float, float]] = []
        uvs: list[tuple[float, float]] = []
        idxs: list[int] = []
        for k in range(0, len(src.indices_stk), 3):
            tri = src.indices_stk[k : k + 3]
            is_hand = all(v in hand_verts for v in tri)
            if is_hand != want_hand:
                continue
            for v in tri:
                if v not in remap:
                    remap[v] = len(pos)
                    pos.append(src.positions_stk[v])
                    nrm.append(src.normals_stk[v])
                    uvs.append(src.uv1[v])
                idxs.append(remap[v])
        bmin, bmax = _bbox_from_points(pos)
        return SpmSubmeshGeom(
            submesh_index=1 if want_hand else 0,
            material_id=src.material_id,
            texture_1=src.texture_1,
            texture_2=src.texture_2,
            positions_stk=pos,
            normals_stk=nrm,
            uv1=uvs,
            indices_stk=idxs,
            bbox_min_stk=bmin,
            bbox_max_stk=bmax,
        )

    return [("Body", _extract(False)), ("Hand", _extract(True))]


def _emit_bounds_lua(items_report: list[dict[str, Any]], out_lua: Path, revision: str) -> None:
    lines: list[str] = [
        "--!strict",
        "-- src/shared/items/ItemBoundsData.lua",
        "-- SPDX-License-Identifier: GPL-3.0-or-later",
        f"-- AUTO-GENERATED by tools/stk2rbx/item_emit.py (METERS_PER_STUD = {METERS_PER_STUD}, rev {revision}).",
        "",
        "export type ItemSubmeshBounds = {",
        "\tsize: { number },",
        "\tcenter: { number },",
        "\ttexture: string,",
        "}",
        "",
        "local ItemBoundsData = {}",
        "",
        "ItemBoundsData.TOLERANCE_STUDS = 0.002",
        "",
        "ItemBoundsData.items = table.freeze({",
    ]
    for item in items_report:
        item_id = item["item_id"]
        lines.append(f'\t["{item_id}"] = table.freeze({{')
        for sp in item["subparts"]:
            clamped_size, _, _ = stk_to_rbx_size(*sp["size_studs"], min_studs=0.05)
            sx, sy, sz = clamped_size
            cx, cy, cz = sp["world_center_studs"]
            tex = sp["texture_1"].replace('"', '\\"')
            lines.append(f'\t\t["{sp["part_name"]}"] = table.freeze({{')
            lines.append(f"\t\t\tsize = table.freeze({{ {sx}, {sy}, {sz} }}),")
            lines.append(f"\t\t\tcenter = table.freeze({{ {cx}, {cy}, {cz} }}),")
            lines.append(f'\t\t\ttexture = "{tex}",')
            lines.append("\t\t}),")
        lines.append("\t}),")
    lines.append("}) :: { [string]: { [string]: ItemSubmeshBounds } }")
    lines.append("")
    lines.append("return ItemBoundsData")
    lines.append("")
    out_lua.parent.mkdir(parents=True, exist_ok=True)
    out_lua.write_text("\n".join(lines), encoding="utf-8")


def _build_item_model_json(
    item_entry: dict[str, Any],
    manifest_items: dict[str, Any],
    revision: str,
) -> dict[str, Any]:
    item_id = item_entry["item_id"]
    item_meta = manifest_items.get(item_id, {})
    parts_meta = item_meta.get("parts", {})
    children: list[dict[str, Any]] = []

    for sp in item_entry["subparts"]:
        sp_name = sp["part_name"]
        sp_pos = [round(v, 5) for v in sp["world_center_studs"]]
        sp_size, _, _ = stk_to_rbx_size(*sp["size_studs"], min_studs=0.05)
        p_meta = parts_meta.get(sp_name)
        if not (p_meta and p_meta.get("meshId")):
            raise ValueError(
                f"Missing uploaded meshId for {item_id}.{sp_name} in manifest (primitive Part fallback disabled)"
            )
        flip_y180 = bool(p_meta.get("importFlipY180", False))
        attrs: dict[str, Any] = {
            "GlbFile": sp["glb_file"],
            "SourceMaterial": sp["texture_1"],
            "VertexCount": sp["vertex_count"],
            "TriangleCount": sp["triangle_count"],
            "ImportFlipY180": flip_y180,
            "LocalPosX": sp_pos[0],
            "LocalPosY": sp_pos[1],
            "LocalPosZ": sp_pos[2],
        }
        children.append(
            _make_mesh_part(
                name=sp_name,
                mesh_id=p_meta["meshId"],
                texture_id=p_meta.get("textureId", ""),
                size=sp_size,
                pos=sp_pos,
                orient=FLIP_Y180_MAT3 if flip_y180 else IDENTITY_MAT3,
                material=p_meta.get("robloxMaterial", "SmoothPlastic"),
                attributes=attrs,
            )
        )

    return {
        "ClassName": "Model",
        "Properties": {
            "Attributes": _encode_attributes(
                {
                    "ItemId": item_id,
                    "SourceModel": item_entry["spm_file"],
                    "XmlKey": item_entry["xml_key"],
                    "SourceRevision": revision,
                    "MetersPerStud": METERS_PER_STUD,
                    "HasUploadedMeshes": True,
                }
            )
        },
        "Children": children,
    }


def convert_items(
    models_dir: Path,
    out_glb_dir: Path,
    out_models_dir: Path,
    report_path: Path,
    out_bounds_lua: Optional[Path] = None,
    assets_manifest_path: Optional[Path] = None,
    revision: str = "18627",
) -> dict[str, Any]:
    """Batch convert every authoritative STK 1.5 item `.spm` into `.glb`, report, and `.model.json`."""
    manifest_items: dict[str, Any] = {}
    if assets_manifest_path is not None and assets_manifest_path.is_file():
        manifest_doc = json.loads(assets_manifest_path.read_text(encoding="utf-8"))
        manifest_items = manifest_doc.get("items", {})

    out_glb_dir.mkdir(parents=True, exist_ok=True)
    out_models_dir.mkdir(parents=True, exist_ok=True)

    items_report: list[dict[str, Any]] = []

    for item_def in AUTHORITATIVE_ITEMS:
        spm_path = models_dir / item_def.spm_file
        if not spm_path.is_file():
            raise FileNotFoundError(f"Missing authoritative item mesh: {spm_path}")

        spm = read_spm_mesh(spm_path)
        if item_def.scale != 1.0:
            sc = item_def.scale
            for s in spm.submeshes:
                s.positions_stk = [(x * sc, y * sc, z * sc) for (x, y, z) in s.positions_stk]
        if item_def.item_id == "bomb" and spm.mesh_format == "SPMA":
            named_stk = _split_bomb_spm(spm_path, spm)
            rbx_pairs: list[tuple[str, RbxSubmeshGeom]] = [
                (pname, convert_submesh_to_rbx(sub)) for (pname, sub) in named_stk
            ]
        else:
            rbx_pairs = [
                (_subpart_name(s.texture_1, idx, len(spm.submeshes)), convert_submesh_to_rbx(s))
                for idx, s in enumerate(spm.submeshes)
            ]
        rbx_subs: list[RbxSubmeshGeom] = [sub for (_, sub) in rbx_pairs]
        for sub in rbx_subs:
            verify_submesh_outward_winding(sub, max_opposed_ratio=0.10)

        item_sub_dir = out_glb_dir / item_def.item_id
        item_sub_dir.mkdir(parents=True, exist_ok=True)

        subparts: list[dict[str, Any]] = []
        for idx, (pname, sub) in enumerate(rbx_pairs):
            stem = pname.lower() if item_def.item_id == "bomb" else (Path(sub.texture_1).stem if sub.texture_1 else f"sub{idx}")
            glb_name = f"{item_def.item_id}_{idx}_{stem}.glb" if len(rbx_subs) > 1 else f"{item_def.item_id}.glb"
            node = GlbNodeSpec(name=pname, translation_studs=(0.0, 0.0, 0.0), submeshes=[sub])
            write_glb_scene([node], item_sub_dir / glb_name, root_name=pname)
            metrics = _part_metrics([sub])
            metrics["part_name"] = pname
            metrics["texture_1"] = sub.texture_1
            metrics["glb_file"] = f"{item_def.item_id}/{glb_name}"
            subparts.append(metrics)

        if len(rbx_subs) > 1:
            assembly_node = GlbNodeSpec(name=item_def.item_id, translation_studs=(0.0, 0.0, 0.0), submeshes=rbx_subs)
            write_glb_scene([assembly_node], item_sub_dir / f"{item_def.item_id}_assembly.glb", root_name=item_def.item_id)

        whole_metrics = _part_metrics(rbx_subs)
        entry: dict[str, Any] = {
            "item_id": item_def.item_id,
            "spm_file": item_def.spm_file,
            "xml_key": item_def.xml_key,
            "mesh_format": spm.mesh_format,
            "vertex_count": whole_metrics["vertex_count"],
            "triangle_count": whole_metrics["triangle_count"],
            "size_studs": whole_metrics["size_studs"],
            "local_bbox_min_studs": whole_metrics["local_bbox_min_studs"],
            "local_bbox_max_studs": whole_metrics["local_bbox_max_studs"],
            "textures": [s.texture_1 for s in rbx_subs],
            "subparts": subparts,
        }
        items_report.append(entry)

        if item_def.emit_model_json:
            model_doc = _build_item_model_json(entry, manifest_items, revision)
            (out_models_dir / f"{item_def.item_id}.rbxmx").write_text(
                emit_kart_rbxmx(item_def.item_id, model_doc), encoding="utf-8"
            )

    full_report = {
        "assets_revision": revision,
        "meters_per_stud": METERS_PER_STUD,
        "item_count": len(items_report),
        "items": items_report,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(full_report, indent=2) + "\n", encoding="utf-8")

    if out_bounds_lua is not None:
        _emit_bounds_lua(items_report, out_bounds_lua, revision)

    return full_report
