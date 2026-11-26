# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert STK 1.5 track `.spm` geometry and XML data into Roblox `.glb` + `.rbxmx` + Luau data."""

from __future__ import annotations

from collections import defaultdict
import dataclasses
import json
import math
import os
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Optional, Sequence

from .coords import METERS_PER_STUD, STUDS_PER_METER, _mat3_mul, stk_hpr_to_rbx_matrix, stk_to_rbx_pos, stk_to_rbx_size
from .kart_emit import (
    FLIP_Y180_MAT3,
    GlbNodeSpec,
    SpmSubmeshGeom,
    _encode_rbx_attrs_binary,
    _xml_cf,
    _xml_escape,
    convert_submesh_to_rbx,
    read_spm_mesh,
    verify_submesh_outward_winding,
    write_glb_scene,
)
from .open_cloud_upload import upload_glb_model
from .rbx_emit import IDENTITY_MAT3
from .xml_parser import parse_materials_xml

Vec3 = tuple[float, float, float]


def _sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _add(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def _scale(a: Vec3, s: float) -> Vec3:
    return (a[0] * s, a[1] * s, a[2] * s)


def _norm_len(a: Vec3) -> tuple[Vec3, float]:
    ln = math.sqrt(a[0] ** 2 + a[1] ** 2 + a[2] ** 2)
    if ln < 1e-9:
        return (0.0, 0.0, 1.0), 0.0
    return (a[0] / ln, a[1] / ln, a[2] / ln), ln


def _lower_center(q: list[Vec3]) -> Vec3:
    return _scale(_add(q[0], q[1]), 0.5)


def _upper_center(q: list[Vec3]) -> Vec3:
    return _scale(_add(q[2], q[3]), 0.5)


def _parse_quads(quads_path: Path) -> list[list[Vec3]]:
    root = ET.parse(quads_path).getroot()
    quads: list[list[Vec3]] = []
    for q in root.findall("quad"):
        pts: list[Vec3] = []
        for k in ("p0", "p1", "p2", "p3"):
            val = q.attrib[k].strip()
            if ":" in val:
                qi, pi = map(int, val.split(":"))
                pts.append(quads[qi][pi])
            else:
                coords = tuple(float(v) for v in val.split())
                pts.append((coords[0], coords[1], coords[2]))
        quads.append(pts)
    return quads


def _parse_main_loop_quad_indices(graph_path: Path, total_quads: int) -> list[int]:
    if not graph_path.exists():
        return list(range(total_quads))
    root = ET.parse(graph_path).getroot()
    loop = root.find("edge-loop")
    if loop is not None:
        start_idx = int(loop.attrib.get("from", "0"))
        end_idx = int(loop.attrib.get("to", str(total_quads - 1)))
        return list(range(start_idx, end_idx + 1))
    return list(range(total_quads))


def compute_start_transforms(
    quads: list[list[Vec3]],
    main_loop_indices: list[int],
    scene_root: ET.Element,
    num_slots: int = 6,
) -> list[dict[str, Any]]:
    """Reproduce DriveGraph::setDefaultStartPositions (drive_graph.cpp:L401-L475)."""
    ds = scene_root.find("default-start")
    karts_per_row = int(ds.attrib.get("karts-per-row", "2")) if ds is not None else 2
    forwards_dist = float(ds.attrib.get("forwards-distance", "1.5")) if ds is not None else 1.5
    sidewards_dist = float(ds.attrib.get("sidewards-distance", "3.0")) if ds is not None else 3.0
    upwards_dist = float(ds.attrib.get("upwards-distance", "0.1")) if ds is not None else 0.1

    multiplier = 1.0
    if sidewards_dist < 0:
        sidewards_dist = -sidewards_dist
        multiplier = -1.0

    loop_pos = len(main_loop_indices) - 1  # predecessor of start node 0
    dist_from_start = 0.75 + forwards_dist
    max_x_dist = 0.5 * (karts_per_row - 0.5) * sidewards_dist
    x_pos = -max_x_dist + sidewards_dist * 0.5
    row_number = 0

    transforms: list[dict[str, Any]] = []
    for slot in range(num_slots):
        while True:
            qi = main_loop_indices[loop_pos]
            q = quads[qi]
            lc, uc = _lower_center(q), _upper_center(q)
            _, node_len = _norm_len(_sub(uc, lc))
            if dist_from_start > node_len and loop_pos > 0:
                dist_from_start -= node_len
                loop_pos -= 1
            else:
                break

        qi = main_loop_indices[loop_pos]
        q = quads[qi]
        lc, uc = _lower_center(q), _upper_center(q)
        center_line, _ = _norm_len(_sub(lc, uc))
        horiz_line, _ = _norm_len(_sub(q[2], q[3]))
        start_stk = _add(_add(uc, _scale(center_line, dist_from_start)), _scale(horiz_line, x_pos * multiplier))
        origin_stk = (start_stk[0], start_stk[1] + upwards_dist, start_stk[2])

        succ_loop_pos = (loop_pos + 1) % len(main_loop_indices)
        qs = quads[main_loop_indices[succ_loop_pos]]
        c_cur = _scale(_add(lc, uc), 0.5)
        c_suc = _scale(_add(_lower_center(qs), _upper_center(qs)), 0.5)
        fwd = _sub(c_suc, c_cur)
        yaw_stk_rad = math.atan2(fwd[0], fwd[2])

        transforms.append(
            {
                "slot": slot,
                "quadIndex": qi,
                "posStk": [round(origin_stk[0], 4), round(origin_stk[1], 4), round(origin_stk[2], 4)],
                "yawStkRad": round(yaw_stk_rad, 6),
            }
        )

        if x_pos >= max_x_dist - sidewards_dist * 0.5:
            x_pos = -max_x_dist
            row_number += 1
            if row_number % 2 == 0:
                x_pos += sidewards_dist * 0.5
        else:
            x_pos += sidewards_dist
        dist_from_start += forwards_dist

    return transforms


def _parse_graph_branches(graph_path: Path, quads: list[list[Vec3]]) -> list[dict[str, Any]]:
    """Extract secondary driveline branches (e.g. temple shortcut) from graph.xml."""
    if not graph_path.exists():
        return []
    root = ET.parse(graph_path).getroot()
    incoming: dict[int, int] = {}
    outgoing: dict[int, int] = {}
    for edge in root.findall("edge"):
        f_idx = int(edge.attrib["from"])
        t_idx = int(edge.attrib["to"])
        incoming[t_idx] = f_idx
        outgoing[f_idx] = t_idx

    branches: list[dict[str, Any]] = []
    for b_idx, line in enumerate(root.findall("edge-line"), 1):
        a = int(line.attrib["from"])
        b = int(line.attrib["to"])
        seq: list[int] = []
        if a in incoming:
            seq.append(incoming[a])
        step = 1 if b >= a else -1
        seq.extend(range(a, b + step, step))
        if b in outgoing:
            seq.append(outgoing[b])

        pts: list[dict[str, float]] = []
        for qi in seq:
            q = quads[qi]
            cx = 0.25 * sum(p[0] for p in q)
            cz = 0.25 * sum(p[2] for p in q)
            pts.append({"x": round(cx, 4), "z": round(cz, 4)})
        branches.append(
            {
                "id": b_idx,
                "fromQuad": seq[0],
                "toQuad": seq[-1],
                "quadIndices": seq,
                "points": pts,
            }
        )
    return branches


def parse_scene_checkpoints(scene_root: ET.Element, quads: list[list[Vec3]]) -> list[dict[str, Any]]:
    """Extract <checks> checkpoint lines in canonical STK meters."""
    checks_el = scene_root.find("checks")
    if checks_el is None:
        return []
    out: list[dict[str, Any]] = []
    for idx, el in enumerate(checks_el):
        kind = el.attrib.get("kind", "activate")
        other_ids = [int(v) for v in el.attrib.get("other-ids", "").split() if v]
        same_group = [int(v) for v in el.attrib.get("same-group", "").split() if v]
        if "p1" in el.attrib and "p2" in el.attrib:
            p1 = [round(float(v), 4) for v in el.attrib["p1"].split()[:3]]
            p2 = [round(float(v), 4) for v in el.attrib["p2"].split()[:3]]
        elif quads:
            p1 = [round(v, 4) for v in quads[0][0]]
            p2 = [round(v, 4) for v in quads[0][1]]
        else:
            p1 = [0.0, 0.0, 0.0]
            p2 = [0.0, 0.0, 0.0]
        out.append(
            {
                "id": idx,
                "kind": kind,
                "otherIds": other_ids,
                "sameGroup": same_group,
                "p1": p1,
                "p2": p2,
            }
        )
    return out


def _raycast_down_stk(
    x: float,
    y_start: float,
    z: float,
    tris: Sequence[tuple[Vec3, Vec3, Vec3, str]],
) -> Optional[tuple[float, str]]:
    """Vertical downward raycast against STK triangles (Track::itemCommand, track.cpp:L2813-L2837)."""
    best_y: Optional[float] = None
    best_mat = ""
    for p0, p1, p2, mat in tris:
        if x < min(p0[0], p1[0], p2[0]) - 1e-5 or x > max(p0[0], p1[0], p2[0]) + 1e-5:
            continue
        if z < min(p0[2], p1[2], p2[2]) - 1e-5 or z > max(p0[2], p1[2], p2[2]) + 1e-5:
            continue
        d00 = (p1[0] - p0[0]) * (p2[2] - p0[2]) - (p1[2] - p0[2]) * (p2[0] - p0[0])
        if abs(d00) < 1e-9:
            continue
        u = ((x - p0[0]) * (p2[2] - p0[2]) - (z - p0[2]) * (p2[0] - p0[0])) / d00
        v = ((p1[0] - p0[0]) * (z - p0[2]) - (p1[2] - p0[2]) * (x - p0[0])) / d00
        if u >= -1e-5 and v >= -1e-5 and (u + v) <= 1.0 + 1e-5:
            hy = p0[1] + u * (p1[1] - p0[1]) + v * (p2[1] - p0[1])
            if hy <= y_start and (best_y is None or hy > best_y):
                best_y = hy
                best_mat = mat
    if best_y is None:
        return None
    return best_y, best_mat


def _collect_track_collision_tris_stk(
    track_dir: Path,
    scene_root: ET.Element,
    ignored_mats: set[str],
) -> list[tuple[Vec3, Vec3, Vec3, str]]:
    """Collect all physical track triangles in canonical STK meter coordinates."""
    track_id = track_dir.name
    spm = read_spm_mesh(track_dir / f"{track_id}_track.spm")
    tris: list[tuple[Vec3, Vec3, Vec3, str]] = []
    for sub in spm.submeshes:
        if sub.texture_1.lower() in ignored_mats:
            continue
        for k in range(0, len(sub.indices_stk) - 2, 3):
            p0 = sub.positions_stk[sub.indices_stk[k]]
            p1 = sub.positions_stk[sub.indices_stk[k + 1]]
            p2 = sub.positions_stk[sub.indices_stk[k + 2]]
            tris.append((p0, p1, p2, sub.texture_1))

    bridge_path = track_dir / "bridge_physics.spm"
    if bridge_path.exists():
        bspm = read_spm_mesh(bridge_path)
        for el in scene_root.iter():
            if el.tag in ("static-object", "object") and el.attrib.get("model") == "bridge_physics.spm":
                xyz = _parse_vec3_attr(el.attrib.get("xyz", ""), (0.0, 0.0, 0.0))
                scl = _parse_vec3_attr(el.attrib.get("scale", ""), (1.0, 1.0, 1.0))
                for sub in bspm.submeshes:
                    for k in range(0, len(sub.indices_stk) - 2, 3):
                        pts = []
                        for idx_v in (sub.indices_stk[k], sub.indices_stk[k + 1], sub.indices_stk[k + 2]):
                            vp = sub.positions_stk[idx_v]
                            pts.append((vp[0] * scl[0] + xyz[0], vp[1] * scl[1] + xyz[1], vp[2] * scl[2] + xyz[2]))
                        tris.append((pts[0], pts[1], pts[2], "road.jpg"))
    return tris


def parse_scene_items(
    scene_root: ET.Element,
    track_tris: Optional[Sequence[tuple[Vec3, Vec3, Vec3, str]]] = None,
) -> list[dict[str, Any]]:
    """Extract track items from scene.xml with STK Track::itemCommand ground drop -> Roblox studs."""
    tag_map = {
        "item": "item",
        "banana": "banana",
        "small-nitro": "small-nitro",
        "big-nitro": "big-nitro",
        "nitro-small": "small-nitro",
        "nitro-big": "big-nitro",
        "bubblegum": "bubblegum",
    }
    items: list[dict[str, Any]] = []
    idx = 0
    for el in scene_root:
        item_type = tag_map.get(el.tag)
        if not item_type:
            continue
        idx += 1
        sx = float(el.attrib.get("x", "0"))
        sy = float(el.attrib.get("y", "0"))
        sz = float(el.attrib.get("z", "0"))
        drop = el.attrib.get("drop", "true").lower() not in ("false", "0", "n")
        if drop and track_tris is not None:
            hit = _raycast_down_stk(sx, sy + 0.1, sz, track_tris)
            if hit is None:
                raise RuntimeError(f"Item #{idx} ({item_type}) at ({sx}, {sy}, {sz}) missed track ground")
            sy = hit[0]
        items.append(
            {
                "id": idx,
                "itemType": item_type,
                "pos": stk_to_rbx_pos(sx, sy, sz),
            }
        )
    return items


def sanitize_tex_stem(tex: str) -> str:
    stem = Path(tex).stem
    return re.sub(r"[^A-Za-z0-9_]+", "_", stem).strip("_") or "submesh"


def _export_spm_submeshes(
    spm_path: Path,
    out_glb_dir: Path,
    prefix: str,
    only_textures: Optional[Sequence[str]] = None,
    skip_textures: Optional[Sequence[str]] = None,
) -> list[dict[str, Any]]:
    mesh = read_spm_mesh(spm_path)
    only_set = {t.lower() for t in only_textures} if only_textures is not None else None
    skip_set = {t.lower() for t in skip_textures} if skip_textures is not None else set()
    out_glb_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    for sub in mesh.submeshes:
        tl = sub.texture_1.lower()
        if only_set is not None and tl not in only_set:
            continue
        sub_rbx = convert_submesh_to_rbx(sub)
        verify_submesh_outward_winding(sub_rbx, max_opposed_ratio=0.15)

        bmin = sub_rbx.bbox_min_studs
        bmax = sub_rbx.bbox_max_studs
        cx = 0.5 * (bmin[0] + bmax[0])
        cy = 0.5 * (bmin[1] + bmax[1])
        cz = 0.5 * (bmin[2] + bmax[2])
        size_studs = [
            round(bmax[0] - bmin[0], 4),
            round(bmax[1] - bmin[1], 4),
            round(bmax[2] - bmin[2], 4),
        ]
        stem = sanitize_tex_stem(sub.texture_1)
        part_name = f"{prefix}_{sub.submesh_index:02d}_{stem}"
        glb_rel = ""
        if tl not in skip_set:
            centered_positions = [(p[0] - cx, p[1] - cy, p[2] - cz) for p in sub_rbx.positions_studs]
            cmin = (bmin[0] - cx, bmin[1] - cy, bmin[2] - cz)
            cmax = (bmax[0] - cx, bmax[1] - cy, bmax[2] - cz)
            centered_sub = dataclasses.replace(
                sub_rbx,
                positions_studs=centered_positions,
                bbox_min_studs=cmin,
                bbox_max_studs=cmax,
            )
            glb_name = f"{prefix.lower()}_{sub.submesh_index:02d}_{stem}.glb"
            glb_path = out_glb_dir / glb_name
            write_glb_scene(
                [GlbNodeSpec(name=part_name, translation_studs=(0.0, 0.0, 0.0), submeshes=[centered_sub])],
                glb_path,
                root_name=part_name,
            )
            glb_rel = f"{out_glb_dir.as_posix().rstrip('/')}/{glb_name}"

        results.append(
            {
                "part_name": part_name,
                "submesh_index": sub.submesh_index,
                "texture_1": sub.texture_1,
                "vertex_count": len(sub_rbx.positions_studs),
                "triangle_count": len(sub_rbx.indices_rbx) // 3,
                "world_center_studs": [round(cx, 5), round(cy, 5), round(cz, 5)],
                "size_studs": size_studs,
                "glb_file": glb_rel,
            }
        )
    return results


def _parse_vec3_attr(raw: str, default: tuple[float, float, float]) -> tuple[float, float, float]:
    parts = [float(v) for v in raw.strip().split()] if raw else []
    if len(parts) >= 3:
        return (parts[0], parts[1], parts[2])
    return default


def export_track_glbs(
    track_dir: Path,
    out_glb_dir: Path,
    only_textures: Optional[Sequence[str]] = None,
    include_aux: bool = False,
    library_root: Optional[Path] = None,
) -> dict[str, Any]:
    """Export track `.spm` submeshes (+ aux & library meshes) to centered `.glb` files."""
    track_id = track_dir.name
    spm_path = track_dir / f"{track_id}_track.spm"
    skip_tex = ["transparence2.png"] if only_textures is None else []
    sub_reports = _export_spm_submeshes(
        spm_path,
        out_glb_dir,
        prefix="Submesh",
        only_textures=only_textures,
        skip_textures=skip_tex,
    )
    # Keep Phase 1 Submesh_06_road glb filename consistent
    for sp in sub_reports:
        if sp["part_name"] == "Submesh_06_road":
            old_glb = Path(sp["glb_file"])
            new_glb = out_glb_dir / f"{track_id}_06_road.glb"
            if old_glb.exists() and old_glb != new_glb:
                new_glb.write_bytes(old_glb.read_bytes())
                sp["glb_file"] = f"{out_glb_dir.as_posix().rstrip('/')}/{track_id}_06_road.glb"

    scene_root = ET.parse(track_dir / "scene.xml").getroot()
    aux_meshes: list[dict[str, Any]] = []
    aux_instances: list[dict[str, Any]] = []
    lib_meshes: list[dict[str, Any]] = []
    lib_proxies: list[dict[str, Any]] = []

    if include_aux:
        for aux_spm, aux_prefix in [
            ("bridge_physics.spm", "AuxBridgePhysics"),
            ("ghost_bridge.spm", "AuxGhostBridge"),
            ("sand-clouds.spm", "AuxSandClouds"),
        ]:
            p = track_dir / aux_spm
            if p.exists():
                aux_meshes.extend(_export_spm_submeshes(p, out_glb_dir, prefix=aux_prefix))

        for el in scene_root.iter():
            if el.tag in ("static-object", "object"):
                model_name = el.attrib.get("model", "")
                if model_name in ("bridge_physics.spm", "ghost_bridge.spm", "sand-clouds.spm"):
                    xyz = _parse_vec3_attr(el.attrib.get("xyz", ""), (0.0, 0.0, 0.0))
                    hpr = _parse_vec3_attr(el.attrib.get("hpr", ""), (0.0, 0.0, 0.0))
                    scl = _parse_vec3_attr(el.attrib.get("scale", ""), (1.0, 1.0, 1.0))
                    aux_instances.append(
                        {
                            "model": model_name,
                            "interaction": el.attrib.get("interaction", "static"),
                            "posStk": list(xyz),
                            "hprDeg": list(hpr),
                            "scale": list(scl),
                        }
                    )

    if library_root is not None:
        lib_specs = {
            "stklib_accacia_a": "stklib_accacia_a_high.spm",
            "stklib_agave_a": "stklib_agave_main.spm",
            "stklib_lowPalmTree_a": "stklib_lowPalmTree_a_main.spm",
            "stklib_palmTree_a": "stklib_palmTree_a_LOD_a.spm",
        }
        for lib_name, spm_name in lib_specs.items():
            lpath = library_root / lib_name / spm_name
            if lpath.exists():
                exported = _export_spm_submeshes(lpath, out_glb_dir, prefix=f"Lib_{lib_name}")
                for sp in exported:
                    sp["library_name"] = lib_name
                lib_meshes.extend(exported)

        for idx, el in enumerate(scene_root.findall("library"), 1):
            lname = el.attrib.get("name", "")
            if lname in lib_specs:
                xyz = _parse_vec3_attr(el.attrib.get("xyz", ""), (0.0, 0.0, 0.0))
                hpr = _parse_vec3_attr(el.attrib.get("hpr", ""), (0.0, 0.0, 0.0))
                scl = _parse_vec3_attr(el.attrib.get("scale", ""), (1.0, 1.0, 1.0))
                lib_proxies.append(
                    {
                        "index": idx,
                        "library_name": lname,
                        "id": el.attrib.get("id", f"{lname}_{idx}"),
                        "posStk": list(xyz),
                        "hprDeg": list(hpr),
                        "scale": list(scl),
                    }
                )

    quads = _parse_quads(track_dir / "quads.xml")
    main_loop = _parse_main_loop_quad_indices(track_dir / "graph.xml", len(quads))
    driveline_branches = _parse_graph_branches(track_dir / "graph.xml", quads)
    start_transforms = compute_start_transforms(quads, main_loop, scene_root)

    driveline_centers: list[dict[str, float]] = []
    min_x, max_x = float("inf"), float("-inf")
    min_z, max_z = float("inf"), float("-inf")
    for qi in main_loop:
        q = quads[qi]
        cx = 0.25 * sum(p[0] for p in q)
        cz = 0.25 * sum(p[2] for p in q)
        driveline_centers.append({"x": round(cx, 4), "z": round(cz, 4)})
    # Include ALL quads (main loop + shortcut branches) in minimapBounds
    for q in quads:
        for p in q:
            min_x = min(min_x, p[0])
            max_x = max(max_x, p[0])
            min_z = min(min_z, p[2])
            max_z = max(max_z, p[2])

    pad = 24.0
    min_x -= pad
    max_x += pad
    min_z -= pad
    max_z += pad
    span = max(max_x - min_x, max_z - min_z)
    mid_x = 0.5 * (min_x + max_x)
    mid_z = 0.5 * (min_z + max_z)

    mat_path = track_dir / "materials.xml"
    ignored_mats = {m.name.lower() for m in parse_materials_xml(mat_path) if m.ignore} if mat_path.exists() else set()
    track_tris = _collect_track_collision_tris_stk(track_dir, scene_root, ignored_mats)
    items = parse_scene_items(scene_root, track_tris=track_tris)
    checkpoints = parse_scene_checkpoints(scene_root, quads)

    return {
        "track_id": track_id,
        "submeshes": sub_reports,
        "auxMeshes": aux_meshes,
        "auxInstances": aux_instances,
        "libraryMeshes": lib_meshes,
        "libraryProxies": lib_proxies,
        "startTransforms": start_transforms,
        "drivelineQuadCenters": driveline_centers,
        "drivelineBranches": driveline_branches,
        "checkpoints": checkpoints,
        "minimapBounds": {
            "minX": round(mid_x - span * 0.5, 4),
            "maxX": round(mid_x + span * 0.5, 4),
            "minZ": round(mid_z - span * 0.5, 4),
            "maxZ": round(mid_z + span * 0.5, 4),
            "range": round(span, 4),
        },
        "items": items,
    }


def _chunk_submesh_per_material(
    sub_rbx: SpmSubmeshGeom,
    material_name: str,
    all_quad_centers_stk: Sequence[tuple[float, float]],
) -> list[dict[str, Any]]:
    """Split ONE material submesh into spatial + normal-band convex-safe collision chunks."""
    mat_lower = material_name.lower()
    stem = sanitize_tex_stem(material_name)
    single_chunk = mat_lower in ("camel_col.jpg", "monkey_col.png", "water_light.png", "transparence2.png")
    split_bands = mat_lower in (
        "road.jpg",
        "sand.png",
        "pyramidwall.jpg",
        "bumpy_surface.png",
        "texture_egypte.jpg",
        "egypt2.jpg",
        "seabed.jpg",
    )
    near_dist_sq = 55.0 * 55.0
    cells: dict[tuple[int, int, int, int], list[tuple[int, int, int]]] = defaultdict(list)

    pos = sub_rbx.positions_studs
    idxs = sub_rbx.indices_rbx
    for k in range(0, len(idxs) - 2, 3):
        i0, i1, i2 = idxs[k], idxs[k + 1], idxs[k + 2]
        p0, p1, p2 = pos[i0], pos[i1], pos[i2]
        e1 = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
        e2 = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
        nx = e1[1] * e2[2] - e1[2] * e2[1]
        ny = e1[2] * e2[0] - e1[0] * e2[2]
        nz = e1[0] * e2[1] - e1[1] * e2[0]
        nlen = math.sqrt(nx * nx + ny * ny + nz * nz)
        e3 = (p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2])
        max_edge = max(
            math.sqrt(e1[0] * e1[0] + e1[1] * e1[1] + e1[2] * e1[2]),
            math.sqrt(e2[0] * e2[0] + e2[1] * e2[1] + e2[2] * e2[2]),
            math.sqrt(e3[0] * e3[0] + e3[1] * e3[1] + e3[2] * e3[2]),
        )
        if nlen < 1e-3 or (max_edge > 1e-6 and (nlen / max_edge) < 0.01):
            continue
        nny = ny / nlen
        band = (0 if nny > 0.35 else (1 if nny >= -0.35 else 2)) if split_bands else 0
        # Split opposing walls (left vs right tunnel wall) into separate normal quadrants
        wdir = (int((math.atan2(nz, nx) + math.pi) / (math.pi * 0.5)) % 4) if band == 1 else 0

        if single_chunk:
            key = (0, band, wdir, 0, 0, 0)
        elif mat_lower == "sand.png":
            cx_studs = (p0[0] + p1[0] + p2[0]) / 3.0
            cz_studs = (p0[2] + p1[2] + p2[2]) / 3.0
            cx_m = cx_studs * METERS_PER_STUD
            cz_m = -cz_studs * METERS_PER_STUD
            near = any((cx_m - qx) ** 2 + (cz_m - qz) ** 2 <= near_dist_sq for qx, qz in all_quad_centers_stk)
            cell = 25.0 if near else 120.0
            zone = 0 if near else 1
            key = (zone, band, wdir, math.floor(cx_studs / cell), 0, math.floor(cz_studs / cell))
        elif mat_lower in ("pyramidwall.jpg", "texture_egypte.jpg", "bumpy_surface.png"):
            cx_studs = (p0[0] + p1[0] + p2[0]) / 3.0
            cy_studs = (p0[1] + p1[1] + p2[1]) / 3.0
            cz_studs = (p0[2] + p1[2] + p2[2]) / 3.0
            cx_m = cx_studs * METERS_PER_STUD
            cz_m = -cz_studs * METERS_PER_STUD
            near = any((cx_m - qx) ** 2 + (cz_m - qz) ** 2 <= near_dist_sq for qx, qz in all_quad_centers_stk)
            if mat_lower == "pyramidwall.jpg":
                cell_xz, cell_y = (10.0, 6.0) if near else (80.0, 40.0)
            elif mat_lower == "texture_egypte.jpg":
                cell_xz, cell_y = (15.0, 8.0) if near else (60.0, 30.0)
            else:
                cell_xz, cell_y = (20.0, 8.0) if near else (80.0, 40.0)
            zone = 0 if near else 1
            key = (
                zone,
                band,
                wdir,
                math.floor(cx_studs / cell_xz),
                math.floor(cy_studs / cell_y),
                math.floor(cz_studs / cell_xz),
            )
        else:
            cell_map = {
                "road.jpg": 35.0,
                "woodpost.png": 40.0,
                "wood_planks1.jpg": 40.0,
                "sphinx.png": 40.0,
                "stktex_generic_wooda.png": 40.0,
                "egypt2.jpg": 60.0,
                "seabed.jpg": 60.0,
            }
            cell = cell_map.get(mat_lower, 40.0)
            cx_studs = (p0[0] + p1[0] + p2[0]) / 3.0
            cz_studs = (p0[2] + p1[2] + p2[2]) / 3.0
            key = (0, band, wdir, math.floor(cx_studs / cell), 0, math.floor(cz_studs / cell))
        cells[key].append((i0, i1, i2))

    chunks: list[dict[str, Any]] = []
    for key in sorted(cells.keys()):
        tri_list = cells[key]
        remap: dict[int, int] = {}
        local_world: list[Vec3] = []
        chunk_tris: list[int] = []
        for i0, i1, i2 in tri_list:
            for orig in (i0, i1, i2):
                if orig not in remap:
                    remap[orig] = len(local_world) + 1
                    local_world.append(pos[orig])
                chunk_tris.append(remap[orig])
        xs = [v[0] for v in local_world]
        ys = [v[1] for v in local_world]
        zs = [v[2] for v in local_world]
        cx = 0.5 * (min(xs) + max(xs))
        cy = 0.5 * (min(ys) + max(ys))
        cz = 0.5 * (min(zs) + max(zs))
        verts_flat: list[float] = []
        for vx, vy, vz in local_world:
            verts_flat.extend([round(vx - cx, 4), round(vy - cy, 4), round(vz - cz, 4)])
        chunks.append(
            {
                "material": material_name,
                "materialStem": stem,
                "center": [round(cx, 4), round(cy, 4), round(cz, 4)],
                "verts": verts_flat,
                "tris": chunk_tris,
            }
        )
    return chunks


def build_track_collision_chunks(track_dir: Path) -> list[dict[str, Any]]:
    """Build strictly per-material collision chunks for all non-ignored surfaces."""
    track_id = track_dir.name
    quads = _parse_quads(track_dir / "quads.xml")
    all_quad_centers = [
        (0.25 * sum(p[0] for p in q), 0.25 * sum(p[2] for p in q)) for q in quads
    ]
    mat_path = track_dir / "materials.xml"
    ignored_mats = {m.name.lower() for m in parse_materials_xml(mat_path) if m.ignore} if mat_path.exists() else set()

    spm = read_spm_mesh(track_dir / f"{track_id}_track.spm")
    chunks: list[dict[str, Any]] = []
    for sub in spm.submeshes:
        if sub.texture_1.lower() in ignored_mats:
            continue
        sub_rbx = convert_submesh_to_rbx(sub)
        chunks.extend(_chunk_submesh_per_material(sub_rbx, sub.texture_1, all_quad_centers))

    bridge_path = track_dir / "bridge_physics.spm"
    scene_path = track_dir / "scene.xml"
    if bridge_path.exists() and scene_path.exists():
        scene_root = ET.parse(scene_path).getroot()
        bspm = read_spm_mesh(bridge_path)
        for el in scene_root.iter():
            if el.tag in ("static-object", "object") and el.attrib.get("model") == "bridge_physics.spm":
                xyz = _parse_vec3_attr(el.attrib.get("xyz", ""), (0.0, 0.0, 0.0))
                scl = _parse_vec3_attr(el.attrib.get("scale", ""), (1.0, 1.0, 1.0))
                for sub in bspm.submeshes:
                    world_stk_verts = [
                        (p[0] * scl[0] + xyz[0], p[1] * scl[1] + xyz[1], p[2] * scl[2] + xyz[2])
                        for p in sub.positions_stk
                    ]
                    shifted = dataclasses.replace(sub, positions_stk=world_stk_verts)
                    sub_rbx = convert_submesh_to_rbx(shifted)
                    chunks.extend(_chunk_submesh_per_material(sub_rbx, "road.jpg", all_quad_centers))
    return chunks


def emit_track_collision_lua(chunks: Sequence[dict[str, Any]], out_lua: Path, revision: str) -> None:
    """Emit SandtrackCollisionData.lua with per-material spatial + normal-band chunks."""
    lines: list[str] = [
        "--!strict",
        "-- src/shared/track/SandtrackCollisionData.lua",
        "-- SPDX-License-Identifier: GPL-3.0-or-later",
        f"-- AUTO-GENERATED per-material collision chunks for sandtrack (rev {revision}).",
        "",
        "export type CollisionChunk = {",
        "\tmaterial: string,",
        "\tmaterialStem: string,",
        "\tcenter: { number },",
        "\tverts: { number },",
        "\ttris: { number },",
        "}",
        "",
        "local chunks: { CollisionChunk } = {",
    ]
    for ch in chunks:
        c = ch["center"]
        verts_s = ", ".join(str(v) for v in ch["verts"])
        tris_s = ", ".join(str(t) for t in ch["tris"])
        lines.append("\t{")
        lines.append(f'\t\tmaterial = "{ch["material"]}",')
        lines.append(f'\t\tmaterialStem = "{ch["materialStem"]}",')
        lines.append(f"\t\tcenter = {{ {c[0]}, {c[1]}, {c[2]} }},")
        lines.append(f"\t\tverts = {{ {verts_s} }},")
        lines.append(f"\t\ttris = {{ {tris_s} }},")
        lines.append("\t},")
    lines.extend(["}", "", "return table.freeze(chunks)", ""])
    out_lua.parent.mkdir(parents=True, exist_ok=True)
    out_lua.write_text("\n".join(lines), encoding="utf-8")


def verify_canonical_transforms(report: dict[str, Any], chunks: Sequence[dict[str, Any]]) -> None:
    """Assert canonical STK<->Roblox transform agreement across chunks, items, driveline, starts, and checks."""
    chunk_tris_stk: list[tuple[Vec3, Vec3, Vec3, str]] = []
    for ch in chunks:
        mat = ch["material"]
        if not mat:
            raise AssertionError("Collision chunk missing material")
        cx, cy, cz = ch["center"]
        v = ch["verts"]
        t = ch["tris"]
        pts_stk = [
            ((cx + v[i]) * METERS_PER_STUD, (cy + v[i + 1]) * METERS_PER_STUD, -(cz + v[i + 2]) * METERS_PER_STUD)
            for i in range(0, len(v), 3)
        ]
        for k in range(0, len(t), 3):
            chunk_tris_stk.append((pts_stk[t[k] - 1], pts_stk[t[k + 1] - 1], pts_stk[t[k + 2] - 1], mat))

    for it in report["items"]:
        rx, ry, rz = it["pos"]
        sx, sy, sz = rx * METERS_PER_STUD, ry * METERS_PER_STUD, -rz * METERS_PER_STUD
        hit = _raycast_down_stk(sx, sy + 0.05, sz, chunk_tris_stk)
        if hit is None or abs(sy - hit[0]) > 0.05:
            raise AssertionError(
                f"Item #{it['id']} ({it['itemType']}) at STK=({sx},{sy},{sz}) not grounded on collision chunks: hit={hit}"
            )

    mb = report["minimapBounds"]
    for pt in report["drivelineQuadCenters"]:
        if not (mb["minX"] <= pt["x"] <= mb["maxX"] and mb["minZ"] <= pt["z"] <= mb["maxZ"]):
            raise AssertionError(f"Main driveline point {pt} outside minimapBounds {mb}")
    for br in report.get("drivelineBranches", []):
        for pt in br["points"]:
            if not (mb["minX"] <= pt["x"] <= mb["maxX"] and mb["minZ"] <= pt["z"] <= mb["maxZ"]):
                raise AssertionError(f"Branch driveline point {pt} outside minimapBounds {mb}")
    for st in report["startTransforms"]:
        p = st["posStk"]
        if not (mb["minX"] <= p[0] <= mb["maxX"] and mb["minZ"] <= p[2] <= mb["maxZ"]):
            raise AssertionError(f"Start transform {st} outside minimapBounds {mb}")
    for chk in report.get("checkpoints", []):
        for p in (chk["p1"], chk["p2"]):
            if not (mb["minX"] <= p[0] <= mb["maxX"] and mb["minZ"] <= p[2] <= mb["maxZ"]):
                raise AssertionError(f"Checkpoint {chk} outside minimapBounds {mb}")


def emit_sandtrack_data_lua(report: dict[str, Any], out_lua: Path, revision: str) -> None:
    """Emit pure-Luau SandtrackData.lua with start transforms, driveline, items, and bounds."""
    lines: list[str] = [
        "--!strict",
        "-- src/shared/track/SandtrackData.lua",
        "-- SPDX-License-Identifier: GPL-3.0-or-later",
        f"-- AUTO-GENERATED by tools/stk2rbx/track_emit.py (METERS_PER_STUD = {METERS_PER_STUD}, rev {revision}).",
        "",
        "local SandtrackData = {}",
        "",
        'SandtrackData.trackId = "sandtrack"',
        'SandtrackData.name = "Shifting Sands"',
        "SandtrackData.voidResetYMeters = -250.0",
        "SandtrackData.drivelineWidthM = 12.0",
        "SandtrackData.drivelineClosedLoop = true",
        "",
        "SandtrackData.startTransforms = table.freeze({",
    ]
    for st in report["startTransforms"]:
        p = st["posStk"]
        lines.append(
            f"\t{{ slot = {st['slot']}, pos = {{ x = {p[0]}, y = {p[1]}, z = {p[2]} }}, yawRad = {st['yawStkRad']} }},"
        )
    lines.append("})")
    lines.append("")

    mb = report["minimapBounds"]
    lines.append("SandtrackData.minimapBounds = table.freeze({")
    lines.append(f"\tminX = {mb['minX']},")
    lines.append(f"\tmaxX = {mb['maxX']},")
    lines.append(f"\tminZ = {mb['minZ']},")
    lines.append(f"\tmaxZ = {mb['maxZ']},")
    lines.append(f"\trange = {mb['range']},")
    lines.append("})")
    lines.append("")

    lines.append("SandtrackData.drivelineQuadCenters = table.freeze({")
    for pt in report["drivelineQuadCenters"]:
        lines.append(f"\ttable.freeze({{ x = {pt['x']}, z = {pt['z']} }}),")
    lines.append("})")
    lines.append("")

    lines.append("SandtrackData.drivelineBranches = table.freeze({")
    for br in report.get("drivelineBranches", []):
        lines.append("\ttable.freeze({")
        lines.append(f"\t\tfromQuad = {br['fromQuad']},")
        lines.append(f"\t\ttoQuad = {br['toQuad']},")
        lines.append("\t\tpoints = table.freeze({")
        for pt in br["points"]:
            lines.append(f"\t\t\ttable.freeze({{ x = {pt['x']}, z = {pt['z']} }}),")
        lines.append("\t\t}),")
        lines.append("\t}),")
    lines.append("})")
    lines.append("")

    lines.append("SandtrackData.checkpoints = table.freeze({")
    for chk in report.get("checkpoints", []):
        oids = ", ".join(str(v) for v in chk["otherIds"])
        sgrp = ", ".join(str(v) for v in chk["sameGroup"])
        p1 = chk["p1"]
        p2 = chk["p2"]
        lines.append("\ttable.freeze({")
        lines.append(f'\t\tid = {chk["id"]},')
        lines.append(f'\t\tkind = "{chk["kind"]}",')
        lines.append(f"\t\totherIds = table.freeze({{ {oids} }}),")
        lines.append(f"\t\tsameGroup = table.freeze({{ {sgrp} }}),")
        lines.append(f"\t\tp1 = table.freeze({{ x = {p1[0]}, y = {p1[1]}, z = {p1[2]} }}),")
        lines.append(f"\t\tp2 = table.freeze({{ x = {p2[0]}, y = {p2[1]}, z = {p2[2]} }}),")
        lines.append("\t}),")
    lines.append("})")
    lines.append("")

    lines.append("SandtrackData.items = table.freeze({")
    for it in report["items"]:
        p = it["pos"]
        lines.append(
            f'\ttable.freeze({{ id = {it["id"]}, itemType = "{it["itemType"]}", pos = table.freeze({{ {p[0]}, {p[1]}, {p[2]} }}) }}),'
        )
    lines.append("})")
    lines.append("")

    lines.append("SandtrackData.expectedBounds = table.freeze({")
    for sp in report["submeshes"]:
        sz = sp["size_studs"]
        lines.append(
            f'\t["{sp["part_name"]}"] = table.freeze({{ size = table.freeze({{ {sz[0]}, {sz[1]}, {sz[2]} }}), tris = {sp["triangle_count"]} }}),'
        )
    for sp in report.get("auxMeshes", []):
        sz = sp["size_studs"]
        lines.append(
            f'\t["{sp["part_name"]}"] = table.freeze({{ size = table.freeze({{ {sz[0]}, {sz[1]}, {sz[2]} }}), tris = {sp["triangle_count"]} }}),'
        )
    lines.append("})")
    lines.append("")
    lines.append("return table.freeze(SandtrackData)")
    lines.append("")

    out_lua.parent.mkdir(parents=True, exist_ok=True)
    out_lua.write_text("\n".join(lines), encoding="utf-8")


TEXTURE_ALIASES: dict[str, str] = {
    "stktex_generic_wooda.png": "wood_substitute_cc0.png",
    "gfx_sandanimated_a.png": "sand_clouds_substitute_cc0.png",
}

ALPHA_TRANSPARENCY_TEXTURES: set[str] = {
    "oasis-water.png",
    "water_light.png",
    "sand_clouds_substitute_cc0.png",
    "stk_accacia_a.png",
    "stktex_agave_a.png",
    "stktex_lowpalmleaf_a.png",
    "stktex_lowpalmtree_a.png",
    "stktex_palmleaf_a.png",
    "stktex_palmleafdry_a.png",
}


def _resolve_tex_id(tex_name: str, textures: dict[str, str]) -> tuple[str, str]:
    resolved_name = TEXTURE_ALIASES.get(tex_name.lower(), tex_name)
    return resolved_name, textures.get(resolved_name, "")


def _transform_local_center(
    pos_stk: Sequence[float],
    hpr_deg: Sequence[float],
    scale: Sequence[float],
    local_center_studs: Sequence[float],
    flip_y180: bool,
) -> tuple[list[float], list[list[float]]]:
    p_rbx = stk_to_rbx_pos(pos_stk[0], pos_stk[1], pos_stk[2])
    r_proxy = stk_hpr_to_rbx_matrix(hpr_deg[0], hpr_deg[1], hpr_deg[2])
    sx, sy, sz = float(scale[0]), float(scale[1]), float(scale[2])
    lx, ly, lz = local_center_studs[0] * sx, local_center_studs[1] * sy, local_center_studs[2] * sz
    wx = round(p_rbx[0] + r_proxy[0][0] * lx + r_proxy[0][1] * ly + r_proxy[0][2] * lz, 5)
    wy = round(p_rbx[1] + r_proxy[1][0] * lx + r_proxy[1][1] * ly + r_proxy[1][2] * lz, 5)
    wz = round(p_rbx[2] + r_proxy[2][0] * lx + r_proxy[2][1] * ly + r_proxy[2][2] * lz, 5)
    orient = _mat3_mul(r_proxy, FLIP_Y180_MAT3) if flip_y180 else r_proxy
    return [wx, wy, wz], orient


def emit_track_rbxmx(
    report: dict[str, Any],
    manifest: dict[str, Any],
    out_rbxmx: Path,
    materials_meta: Optional[dict[str, dict[str, Any]]] = None,
) -> None:
    """Emit Rojo-compatible `.rbxmx` Model with Surfaces, Visuals, and Props folders."""
    textures = manifest.get("textures", {})
    sub_meta = manifest.get("submeshes", {})
    mat_meta = materials_meta or {}
    ref_id = 0

    def next_ref() -> str:
        nonlocal ref_id
        r = f"RBX{ref_id}"
        ref_id += 1
        return r

    def xml_vec3(name: str, v: Sequence[float]) -> str:
        return f'<Vector3 name="{name}"><X>{v[0]}</X><Y>{v[1]}</Y><Z>{v[2]}</Z></Vector3>'

    rough_id = textures.get("matte_roughness.png", "")

    def append_mesh_part(
        target_lines: list[str],
        name: str,
        sp: dict[str, Any],
        pos_studs: list[float],
        orient: list[list[float]],
        size_studs: list[float],
        can_collide: bool,
        can_query: bool,
        transparency: float,
        surface_material: Optional[str],
        desired_fidelity: str,
        skip_sa: bool = False,
    ) -> None:
        pname = sp["part_name"]
        meta = sub_meta.get(pname, {})
        mesh_id = meta.get("meshId", "")
        if not mesh_id:
            raise ValueError(f"Missing meshId for {pname} in manifest")
        tex_name = sp["texture_1"]
        resolved_tex, tex_id = _resolve_tex_id(tex_name, textures)
        m_info = mat_meta.get(tex_name.lower(), {})
        nm_name = m_info.get("normal_map", "")
        nm_id = textures.get(nm_name, "") if nm_name else ""
        col_tok = 3 if desired_fidelity == "PreciseConvexDecomposition" else 2
        alpha_mode = 1 if resolved_tex.lower() in ALPHA_TRANSPARENCY_TEXTURES else 0

        attrs: dict[str, Any] = {
            "MeshAssetId": mesh_id,
            "TriangleCount": sp["triangle_count"],
            "VertexCount": sp["vertex_count"],
            "SourceTrack": report["track_id"],
            "ImportFlipY180": bool(meta.get("importFlipY180", False)),
            "DesiredCollisionFidelity": desired_fidelity,
        }
        if surface_material:
            attrs["SurfaceMaterial"] = surface_material

        target_lines.extend(
            [
                f'      <Item class="MeshPart" referent="{next_ref()}">',
                "        <Properties>",
                f'          <string name="Name">{_xml_escape(name)}</string>',
                '          <bool name="Anchored">true</bool>',
                f'          <bool name="CanCollide">{"true" if can_collide else "false"}</bool>',
                '          <bool name="CanTouch">false</bool>',
                f'          <bool name="CanQuery">{"true" if can_query else "false"}</bool>',
                '          <bool name="DoubleSided">true</bool>',
                f'          <float name="Transparency">{transparency}</float>',
                f'          <Content name="MeshId"><url>{_xml_escape(mesh_id)}</url></Content>',
                f'          <Content name="TextureID"><url>{_xml_escape(tex_id)}</url></Content>',
                '          <token name="Material">816</token>',
                '          <token name="RenderFidelity">1</token>',
                f'          <token name="CollisionFidelity">{col_tok}</token>',
                f'          {xml_vec3("InitialSize", size_studs)}',
                f'          {xml_vec3("size", size_studs)}',
                f'          {_xml_cf("CFrame", pos_studs, orient)}',
                f'          <BinaryString name="AttributesSerialize">{_encode_rbx_attrs_binary(attrs)}</BinaryString>',
                "        </Properties>",
            ]
        )
        if tex_id and not skip_sa:
            target_lines.extend(
                [
                    f'        <Item class="SurfaceAppearance" referent="{next_ref()}">',
                    "          <Properties>",
                    '            <string name="Name">SurfaceAppearance</string>',
                    f'            <token name="AlphaMode">{alpha_mode}</token>',
                    f'            <Content name="ColorMap"><url>{_xml_escape(tex_id)}</url></Content>',
                    f'            <Content name="NormalMap"><url>{_xml_escape(nm_id)}</url></Content>',
                    f'            <Content name="RoughnessMap"><url>{_xml_escape(rough_id)}</url></Content>',
                    "          </Properties>",
                    "        </Item>",
                ]
            )
        target_lines.append("      </Item>")

    surface_lines: list[str] = []
    visual_lines: list[str] = []
    prop_lines: list[str] = []

    for sp in report["submeshes"]:
        tex_lower = sp["texture_1"].lower()
        pname = sp["part_name"]
        sz, _, _ = stk_to_rbx_size(*sp["size_studs"], min_studs=0.05)
        if tex_lower == "transparence2.png":
            # Reset trigger surface lives in per-material runtime collision chunks (invisible).
            continue
        flip_y180 = bool(sub_meta.get(pname, {}).get("importFlipY180", False))
        append_mesh_part(
            visual_lines,
            pname,
            sp,
            sp["world_center_studs"],
            FLIP_Y180_MAT3 if flip_y180 else IDENTITY_MAT3,
            sz,
            can_collide=False,
            can_query=False,
            transparency=0.0,
            surface_material=None,
            desired_fidelity="Box",
        )

    # Auxiliary meshes (bridge_physics, ghost_bridge, sand-clouds)
    aux_by_model: dict[str, dict[str, Any]] = {}
    for sp in report.get("auxMeshes", []):
        if sp["part_name"].startswith("AuxBridgePhysics"):
            aux_by_model["bridge_physics.spm"] = sp
        elif sp["part_name"].startswith("AuxGhostBridge"):
            aux_by_model["ghost_bridge.spm"] = sp
        elif sp["part_name"].startswith("AuxSandClouds"):
            aux_by_model["sand-clouds.spm"] = sp

    cloud_idx = 0
    for inst in report.get("auxInstances", []):
        mname = inst["model"]
        sp = aux_by_model.get(mname)
        if not sp:
            continue
        pname = sp["part_name"]
        flip_y180 = bool(sub_meta.get(pname, {}).get("importFlipY180", False))
        wpos, worient = _transform_local_center(
            inst["posStk"], inst["hprDeg"], inst["scale"], sp["world_center_studs"], flip_y180
        )
        scl = inst["scale"]
        sz, _, _ = stk_to_rbx_size(
            sp["size_studs"][0] * scl[0],
            sp["size_studs"][1] * scl[1],
            sp["size_studs"][2] * scl[2],
            min_studs=0.05,
        )
        if mname == "bridge_physics.spm":
            # bridge_physics.spm collision lives in per-material runtime collision chunks (road.jpg).
            continue
        elif mname == "ghost_bridge.spm":
            append_mesh_part(
                visual_lines,
                "AuxGhostBridge",
                sp,
                wpos,
                worient,
                sz,
                can_collide=False,
                can_query=False,
                transparency=0.0,
                surface_material=None,
                desired_fidelity="Box",
            )
        elif mname == "sand-clouds.spm":
            cloud_idx += 1
            append_mesh_part(
                visual_lines,
                f"AuxSandClouds_{cloud_idx}",
                sp,
                wpos,
                worient,
                sz,
                can_collide=False,
                can_query=False,
                transparency=0.0,
                surface_material=None,
                desired_fidelity="Box",
            )

    # 95 Library proxies (Props)
    lib_by_name: dict[str, list[dict[str, Any]]] = {}
    for sp in report.get("libraryMeshes", []):
        lib_by_name.setdefault(sp["library_name"], []).append(sp)

    for proxy in report.get("libraryProxies", []):
        lname = proxy["library_name"]
        subs = lib_by_name.get(lname, [])
        scl = proxy["scale"]
        for sp in subs:
            pname = sp["part_name"]
            flip_y180 = bool(sub_meta.get(pname, {}).get("importFlipY180", False))
            wpos, worient = _transform_local_center(
                proxy["posStk"], proxy["hprDeg"], scl, sp["world_center_studs"], flip_y180
            )
            sz, _, _ = stk_to_rbx_size(
                sp["size_studs"][0] * scl[0],
                sp["size_studs"][1] * scl[1],
                sp["size_studs"][2] * scl[2],
                min_studs=0.05,
            )
            inst_name = f"Prop_{proxy['index']:03d}_{lname}_{sp['submesh_index']}"
            append_mesh_part(
                prop_lines,
                inst_name,
                sp,
                wpos,
                worient,
                sz,
                can_collide=False,
                can_query=False,
                transparency=0.0,
                surface_material=None,
                desired_fidelity="Box",
            )

    lines: list[str] = [
        '<roblox version="4">',
        f'  <Item class="Model" referent="{next_ref()}">',
        "    <Properties>",
        f'      <string name="Name">{_xml_escape(report["track_id"])}</string>',
        f'      <BinaryString name="AttributesSerialize">{_encode_rbx_attrs_binary({"TrackId": report["track_id"], "Revision": str(manifest.get("assets_revision", "18627"))})}</BinaryString>',
        "    </Properties>",
        f'    <Item class="Folder" referent="{next_ref()}">',
        '      <Properties><string name="Name">Surfaces</string></Properties>',
        *surface_lines,
        "    </Item>",
        f'    <Item class="Folder" referent="{next_ref()}">',
        '      <Properties><string name="Name">Visuals</string></Properties>',
        *visual_lines,
        "    </Item>",
        f'    <Item class="Folder" referent="{next_ref()}">',
        '      <Properties><string name="Name">Props</string></Properties>',
        *prop_lines,
        "    </Item>",
        "  </Item>",
        "</roblox>",
        "",
    ]
    out_rbxmx.parent.mkdir(parents=True, exist_ok=True)
    out_rbxmx.write_text("\n".join(lines), encoding="utf-8")


def upload_pending_submeshes(report: dict[str, Any], manifest_path: Path, repo_root: Path) -> None:
    """Upload any track/aux/library `.glb` missing `modelAssetId` via Open Cloud."""
    api_key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY", "")
    if not api_key:
        raise RuntimeError("Missing ROBLOX_OPEN_CLOUD_KEY environment variable")
    doc = json.loads(manifest_path.read_text(encoding="utf-8"))
    creator_id = str(doc["creator_user_id"])
    subs = doc.setdefault("submeshes", {})
    all_entries = list(report["submeshes"]) + list(report.get("auxMeshes", [])) + list(report.get("libraryMeshes", []))
    for sp in all_entries:
        if not sp.get("glb_file"):
            continue
        pname = sp["part_name"]
        entry = subs.setdefault(pname, {})
        if entry.get("modelAssetId"):
            continue
        glb_path = repo_root / sp["glb_file"]
        asset_id = upload_glb_model(
            glb_path=glb_path,
            display_name=f"OpenKart_{report['track_id']}_{pname}",
            creator_user_id=creator_id,
            api_key=api_key,
        )
        entry["modelAssetId"] = asset_id
        entry["glbFile"] = sp["glb_file"]
        entry["texture"] = sp["texture_1"]
        manifest_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
        print(f"Uploaded {pname} -> modelAssetId={asset_id}")
