# SPDX-License-Identifier: GPL-3.0-or-later
"""Emit Rojo 7 .model.json instance trees from parsed STK 1.5 track data."""

from __future__ import annotations

from typing import Any, Optional

from .coords import (
    STUDS_PER_METER,
    check_line_to_rbx_transform,
    quad_to_rbx_transform,
    stk_heading_to_rbx_matrix,
    stk_hpr_to_rbx_matrix,
    stk_to_rbx_pos,
    stk_to_rbx_size,
)
from .mesh_inspect import MeshAudit
from .xml_parser import (
    CheckStructureData,
    DriveGraphData,
    ItemPlacementData,
    SceneData,
    SceneObjectData,
    TrackInfo,
)

IDENTITY_MAT3 = [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
]


def _encode_attributes(attributes: dict[str, Any]) -> dict[str, Any]:
    """Encode a flat dict into Rojo 7 .model.json Properties.Attributes format."""
    encoded: dict[str, Any] = {}
    for key, val in attributes.items():
        if isinstance(val, bool):
            encoded[key] = {"Bool": val}
        elif isinstance(val, int):
            encoded[key] = {"Int32": val}
        elif isinstance(val, float):
            encoded[key] = {"Float64": val}
        else:
            encoded[key] = {"String": str(val)}
    return {"Attributes": encoded}


def _make_part(
    name: str,
    size: list[float],
    pos: list[float],
    orient: list[list[float]],
    color: list[float],
    transparency: float = 0.0,
    can_collide: bool = True,
    can_touch: bool = False,
    can_query: bool = True,
    shape: Optional[str] = None,
    attributes: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    props: dict[str, Any] = {
        "Anchored": True,
        "CanCollide": can_collide,
        "CanTouch": can_touch,
        "CanQuery": can_query,
        "Size": size,
        "Color": color,
        "Transparency": transparency,
        "TopSurface": "Smooth",
        "BottomSurface": "Smooth",
        "CFrame": {
            "CFrame": {
                "position": pos,
                "orientation": orient,
            }
        },
    }
    if shape is not None:
        props["Shape"] = shape
    if attributes:
        props["Attributes"] = _encode_attributes(attributes)
    return {
        "ClassName": "Part",
        "Name": name,
        "Properties": props,
    }


def _build_main_track_part(
    scene: SceneData,
    mesh_audits: dict[str, MeshAudit],
) -> dict[str, Any]:
    audit = mesh_audits.get(scene.main_track_model)
    orient = stk_hpr_to_rbx_matrix(*scene.main_track_hpr)

    if audit is not None:
        cx_m = 0.5 * (audit.bbox_min_m[0] + audit.bbox_max_m[0]) + scene.main_track_xyz[0]
        cy_m = 0.5 * (audit.bbox_min_m[1] + audit.bbox_max_m[1]) + scene.main_track_xyz[1]
        cz_m = 0.5 * (audit.bbox_min_m[2] + audit.bbox_max_m[2]) + scene.main_track_xyz[2]
        pos = stk_to_rbx_pos(cx_m, cy_m, cz_m)
        size, raw_studs, exceeds_size = stk_to_rbx_size(*audit.size_m, min_studs=1.0)
        attrs: dict[str, Any] = {
            "ModelFile": scene.main_track_model,
            "MeshFormat": audit.mesh_format,
            "SubmeshCount": audit.submesh_count,
            "MaterialCount": audit.material_count,
            "TriangleCount": audit.triangle_count,
            "VertexCount": audit.vertex_count,
            "MaxSubmeshTriangles": audit.max_submesh_triangles,
            "ExceedsCap20k": audit.exceeds_20k_whole,
            "ExceedsCap10k": audit.exceeds_10k_whole,
            "ExceedsCap20kSubmesh": audit.exceeds_20k_any_submesh,
            "ExceedsCap10kSubmesh": audit.exceeds_10k_any_submesh,
            "Exceeds2048Studs": exceeds_size,
            "RawSizeStudsX": raw_studs[0],
            "RawSizeStudsY": raw_studs[1],
            "RawSizeStudsZ": raw_studs[2],
        }
    else:
        pos = stk_to_rbx_pos(*scene.main_track_xyz)
        size = [10.0, 1.0, 10.0]
        attrs = {
            "ModelFile": scene.main_track_model,
            "MeshFormat": "MISSING",
        }

    return _make_part(
        name="MainTrack",
        size=size,
        pos=pos,
        orient=orient,
        color=[0.85, 0.72, 0.45],
        transparency=0.92,
        can_collide=False,
        attributes=attrs,
    )


def _build_driveline_folder(graph: DriveGraphData) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    for q in graph.quads:
        pos, orient, size = quad_to_rbx_transform(*q.points)
        color = [0.42, 0.42, 0.45] if not q.invisible else [0.35, 0.35, 0.55]
        attrs = {
            "QuadIndex": q.index,
            "Successors": ",".join(str(s) for s in q.successors),
            "DistanceFromStartMeters": round(q.distance_from_start, 3),
            "Invisible": q.invisible,
            "AiIgnore": q.ai_ignore,
            "Direction": q.direction or "both",
        }
        children.append(
            _make_part(
                name=f"Quad_{q.index:03d}",
                size=size,
                pos=pos,
                orient=orient,
                color=color,
                transparency=1.0,
                can_collide=False,
                can_touch=False,
                can_query=True,
                attributes=attrs,
            )
        )
    return {
        "ClassName": "Folder",
        "Name": "Driveline",
        "Children": children,
    }


def _check_color(chk: CheckStructureData) -> list[float]:
    if chk.kind == "lap":
        return [0.15, 0.85, 0.25]
    if chk.kind == "activate":
        return [0.95, 0.8, 0.15]
    if chk.kind in ("cannon", "goal"):
        return [0.15, 0.75, 0.95]
    return [0.85, 0.45, 0.9]


def _build_checkpoints_folder(scene: SceneData, graph: DriveGraphData) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    for chk in scene.checks:
        if chk.p1 is not None and chk.p2 is not None:
            pos, orient, size = check_line_to_rbx_transform(chk.p1, chk.p2)
            shape = None
        elif chk.xyz is not None:
            pos = stk_to_rbx_pos(*chk.xyz)
            orient = IDENTITY_MAT3
            d = max(1.0, round(chk.radius * 2.0 * STUDS_PER_METER, 4))
            size = [min(2048.0, d), min(2048.0, d), min(2048.0, d)]
            shape = "Ball"
        elif graph.quads:
            pos, orient, size = quad_to_rbx_transform(*graph.quads[0].points)
            pos[1] = round(pos[1] + 5.0, 4)
            size = [size[0], 10.0, 2.0]
            shape = None
        else:
            pos = [0.0, 0.0, 0.0]
            orient = IDENTITY_MAT3
            size = [4.0, 4.0, 4.0]
            shape = None

        attrs: dict[str, Any] = {
            "CheckId": chk.index,
            "CheckType": chk.tag,
            "Kind": chk.kind,
            "ActiveAtReset": chk.active_at_reset,
            "OtherIds": ",".join(str(x) for x in chk.other_ids),
            "SameGroup": ",".join(str(x) for x in chk.same_group),
        }
        if chk.radius > 0.0:
            attrs["RadiusMeters"] = chk.radius

        children.append(
            _make_part(
                name=f"Check_{chk.index:03d}",
                size=size,
                pos=pos,
                orient=orient,
                color=_check_color(chk),
                transparency=1.0,
                can_collide=False,
                can_touch=False,
                can_query=True,
                shape=shape,
                attributes=attrs,
            )
        )
    return {
        "ClassName": "Folder",
        "Name": "Checkpoints",
        "Children": children,
    }


def _item_color(item_type: str) -> list[float]:
    if item_type == "item":
        return [0.95, 0.3, 0.25]
    if item_type == "small-nitro":
        return [0.25, 0.65, 0.98]
    if item_type == "big-nitro":
        return [0.1, 0.35, 0.95]
    if item_type == "banana":
        return [0.98, 0.88, 0.15]
    return [0.85, 0.85, 0.85]


def _build_items_folder(items: list[ItemPlacementData]) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    for item in items:
        pos = stk_to_rbx_pos(*item.xyz)
        pos[1] = round(pos[1] + 1.5, 4)
        children.append(
            _make_part(
                name=f"Item_{item.index:03d}",
                size=[2.5, 2.5, 2.5],
                pos=pos,
                orient=IDENTITY_MAT3,
                color=_item_color(item.item_type),
                transparency=0.25,
                can_collide=False,
                attributes={
                    "ItemIndex": item.index,
                    "ItemType": item.item_type,
                    "Drop": item.drop,
                },
            )
        )
    return {
        "ClassName": "Folder",
        "Name": "Items",
        "Children": children,
    }


def _build_scene_objects_folder(
    objects: list[SceneObjectData],
    mesh_audits: dict[str, MeshAudit],
) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    for obj in objects:
        audit = mesh_audits.get(obj.model) if obj.model else None
        orient = stk_hpr_to_rbx_matrix(*obj.hpr)
        if audit is not None:
            sx_m = audit.size_m[0] * obj.scale[0]
            sy_m = audit.size_m[1] * obj.scale[1]
            sz_m = audit.size_m[2] * obj.scale[2]
            cx_m = obj.xyz[0] + 0.5 * (audit.bbox_min_m[0] + audit.bbox_max_m[0]) * obj.scale[0]
            cy_m = obj.xyz[1] + 0.5 * (audit.bbox_min_m[1] + audit.bbox_max_m[1]) * obj.scale[1]
            cz_m = obj.xyz[2] + 0.5 * (audit.bbox_min_m[2] + audit.bbox_max_m[2]) * obj.scale[2]
            pos = stk_to_rbx_pos(cx_m, cy_m, cz_m)
            size, raw_studs, exceeds_size = stk_to_rbx_size(sx_m, sy_m, sz_m, min_studs=0.5)
        else:
            pos = stk_to_rbx_pos(*obj.xyz)
            size, raw_studs, exceeds_size = stk_to_rbx_size(
                obj.scale[0], obj.scale[1], obj.scale[2], min_studs=1.0
            )

        attrs: dict[str, Any] = {
            "ObjectIndex": obj.index,
            "Tag": obj.tag,
            "ObjectId": obj.obj_id,
            "ObjectType": obj.obj_type,
            "ModelFile": obj.model,
            "LibraryName": obj.name,
            "Interaction": obj.interaction or "static",
            "Exceeds2048Studs": exceeds_size,
        }
        if audit is not None:
            attrs["MeshFormat"] = audit.mesh_format
            attrs["SubmeshCount"] = audit.submesh_count
            attrs["TriangleCount"] = audit.triangle_count
            attrs["VertexCount"] = audit.vertex_count
            attrs["ExceedsCap20k"] = audit.exceeds_20k_whole
            attrs["ExceedsCap10k"] = audit.exceeds_10k_whole
            attrs["RawSizeStudsX"] = raw_studs[0]
            attrs["RawSizeStudsY"] = raw_studs[1]
            attrs["RawSizeStudsZ"] = raw_studs[2]
        elif obj.tag == "library":
            attrs["MeshFormat"] = "EXTERNAL_LIBRARY"

        color = [0.76, 0.58, 0.36] if obj.tag == "object" else [0.55, 0.65, 0.78]
        children.append(
            _make_part(
                name=f"Obj_{obj.index:03d}_{obj.obj_id or obj.name or obj.tag}",
                size=size,
                pos=pos,
                orient=orient,
                color=color,
                transparency=0.5,
                can_collide=False,
                attributes=attrs,
            )
        )
    return {
        "ClassName": "Folder",
        "Name": "SceneObjects",
        "Children": children,
    }


def _build_starts_folder(scene: SceneData, graph: DriveGraphData) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    starts = list(scene.starts)
    if not starts and scene.default_start is not None:
        starts = [scene.default_start]

    if starts:
        for st in starts:
            pos = stk_to_rbx_pos(*st.xyz)
            pos[1] = round(pos[1] + 1.0, 4)
            orient = stk_heading_to_rbx_matrix(st.heading)
            children.append(
                _make_part(
                    name=f"Start_{st.position:02d}",
                    size=[3.0, 1.0, 5.0],
                    pos=pos,
                    orient=orient,
                    color=[1.0, 1.0, 1.0],
                    transparency=0.3,
                    can_collide=False,
                    can_touch=False,
                    can_query=True,
                    attributes={"StartPosition": st.position, "HeadingDeg": st.heading},
                )
            )
    elif graph.quads:
        pos, orient, _ = quad_to_rbx_transform(*graph.quads[0].points)
        pos[1] = round(pos[1] + 1.25, 4)
        children.append(
            _make_part(
                name="Start_00_DerivedFromQuad0",
                size=[3.0, 1.0, 5.0],
                pos=pos,
                orient=orient,
                color=[1.0, 1.0, 1.0],
                transparency=0.3,
                can_collide=False,
                attributes={"StartPosition": 0, "DerivedFromQuad": 0},
            )
        )

    return {
        "ClassName": "Folder",
        "Name": "StartPositions",
        "Children": children,
    }


def emit_track_model_json(
    track_id: str,
    track_info: TrackInfo,
    graph: DriveGraphData,
    scene: SceneData,
    mesh_audits: dict[str, MeshAudit],
    assets_revision: str = "",
) -> dict[str, Any]:
    """Assemble a complete Rojo 7 .model.json Model tree for one STK track."""
    return {
        "ClassName": "Model",
        "Properties": {
            "Attributes": _encode_attributes({
                "TrackId": track_id,
                "TrackName": track_info.name,
                "Designer": track_info.designer,
                "Version": track_info.version,
                "Gravity": track_info.gravity,
                "Friction": track_info.friction,
                "DefaultLaps": track_info.default_laps,
                "ReverseAvailable": track_info.reverse_available,
                "PushBack": track_info.push_back,
                "AutoRescue": track_info.auto_rescue,
                "SmoothNormals": track_info.smooth_normals,
                "QuadCount": len(graph.quads),
                "LapLengthMeters": round(graph.lap_length, 3),
                "LapLengthStuds": round(graph.lap_length * STUDS_PER_METER, 3),
                "CheckpointCount": len(scene.checks),
                "ItemCount": len(scene.items),
                "SceneObjectCount": len(scene.objects),
                "UpstreamAssetsRevision": assets_revision,
            }),
        },
        "Children": [
            _build_main_track_part(scene, mesh_audits),
            _build_driveline_folder(graph),
            _build_checkpoints_folder(scene, graph),
            _build_items_folder(scene.items),
            _build_scene_objects_folder(scene.objects, mesh_audits),
            _build_starts_folder(scene, graph),
        ],
    }
