# SPDX-License-Identifier: GPL-3.0-or-later
"""XML parsers for SuperTuxKart 1.5 track files (track, quads, graph, scene).

Mirrors parsing logic in:
  - src/tracks/track.cpp:L527-L664, L1273-L1380, L2419-L2550 (STK 1.5)
  - src/tracks/drive_graph.cpp:L66-L260 (STK 1.5)
  - src/tracks/check_manager.cpp:L38-L95 (STK 1.5)
"""

from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

Vec3 = tuple[float, float, float]


def _parse_bool(raw: Optional[str], default: bool = False) -> bool:
    if raw is None:
        return default
    return raw.strip().lower() in ("true", "1", "yes", "y")


def _parse_float(raw: Optional[str], default: float = 0.0) -> float:
    if raw is None or not raw.strip():
        return default
    return float(raw.strip())


def _parse_int(raw: Optional[str], default: int = 0) -> int:
    if raw is None or not raw.strip():
        return default
    return int(raw.strip())


def _parse_vec3(raw: Optional[str], default: Vec3 = (0.0, 0.0, 0.0)) -> Vec3:
    if raw is None or not raw.strip():
        return default
    parts = [float(p) for p in re.split(r"[\s,]+", raw.strip()) if p]
    if len(parts) < 3:
        raise ValueError(f"Expected 3 floats in '{raw}', got {len(parts)}")
    return (parts[0], parts[1], parts[2])


def _parse_xyz_elem(elem: ET.Element, default: Vec3 = (0.0, 0.0, 0.0)) -> Vec3:
    """Parse STK XMLNode::getXYZ: supports either xyz='x y z' or x/y/z attributes."""
    if elem.get("xyz") is not None:
        return _parse_vec3(elem.get("xyz"), default)
    if any(elem.get(k) is not None for k in ("x", "y", "z")):
        return (
            _parse_float(elem.get("x"), default[0]),
            _parse_float(elem.get("y"), default[1]),
            _parse_float(elem.get("z"), default[2]),
        )
    return default


def _parse_hpr_elem(elem: ET.Element, default: Vec3 = (0.0, 0.0, 0.0)) -> Vec3:
    """Parse STK XMLNode::getHPR: supports either hpr='h p r' or h/p/r attributes."""
    if elem.get("hpr") is not None:
        return _parse_vec3(elem.get("hpr"), default)
    if any(elem.get(k) is not None for k in ("h", "p", "r")):
        return (
            _parse_float(elem.get("h"), default[0]),
            _parse_float(elem.get("p"), default[1]),
            _parse_float(elem.get("r"), default[2]),
        )
    return default


def _parse_vec2(raw: str) -> tuple[float, float]:
    parts = [float(p) for p in re.split(r"[\s,]+", raw.strip()) if p]
    if len(parts) < 2:
        raise ValueError(f"Expected 2 floats in '{raw}', got {len(parts)}")
    return (parts[0], parts[1])


def _parse_int_list(raw: Optional[str]) -> list[int]:
    if raw is None or not raw.strip():
        return []
    return [int(p) for p in re.split(r"[\s,]+", raw.strip()) if p]


@dataclass
class TrackModeInfo:
    name: str = "standard"
    quads: str = "quads.xml"
    graph: str = "graph.xml"
    scene: str = "scene.xml"


@dataclass
class TrackInfo:
    name: str
    designer: str = ""
    version: int = 0
    gravity: float = 9.80665
    friction: float = 0.5
    default_laps: int = 3
    reverse_available: bool = False
    push_back: bool = True
    auto_rescue: bool = True
    smooth_normals: bool = False
    is_arena: bool = False
    is_soccer: bool = False
    is_ctf: bool = False
    groups: list[str] = field(default_factory=list)
    modes: list[TrackModeInfo] = field(default_factory=list)


@dataclass
class QuadNode:
    index: int
    points: tuple[Vec3, Vec3, Vec3, Vec3]
    center: Vec3
    normal: Vec3
    invisible: bool = False
    ai_ignore: bool = False
    ignored: bool = False
    direction: str = ""
    successors: list[int] = field(default_factory=list)
    distance_from_start: float = 0.0


@dataclass
class DriveGraphData:
    quads: list[QuadNode]
    min_height_testing: float = -1.0
    max_height_testing: float = 5.0
    lap_length: float = 0.0
    has_explicit_graph: bool = False


@dataclass
class CheckStructureData:
    index: int
    tag: str
    kind: str
    active_at_reset: bool
    other_ids: list[int] = field(default_factory=list)
    same_group: list[int] = field(default_factory=list)
    p1: Optional[Vec3] = None
    p2: Optional[Vec3] = None
    xyz: Optional[Vec3] = None
    radius: float = 0.0


@dataclass
class SceneObjectData:
    index: int
    tag: str  # "object" | "library" | "particle-emitter" | "light"
    obj_id: str = ""
    obj_type: str = ""
    model: str = ""
    name: str = ""
    interaction: str = ""
    shape: str = ""
    xyz: Vec3 = (0.0, 0.0, 0.0)
    hpr: Vec3 = (0.0, 0.0, 0.0)
    scale: Vec3 = (1.0, 1.0, 1.0)


@dataclass
class ItemPlacementData:
    index: int
    item_type: str
    xyz: Vec3
    drop: bool = True


@dataclass
class StartPosData:
    position: int
    xyz: Vec3
    heading: float = 0.0


@dataclass
class SceneData:
    main_track_model: str = ""
    main_track_xyz: Vec3 = (0.0, 0.0, 0.0)
    main_track_hpr: Vec3 = (0.0, 0.0, 0.0)
    lod_models: list[str] = field(default_factory=list)
    objects: list[SceneObjectData] = field(default_factory=list)
    checks: list[CheckStructureData] = field(default_factory=list)
    items: list[ItemPlacementData] = field(default_factory=list)
    starts: list[StartPosData] = field(default_factory=list)
    default_start: Optional[StartPosData] = None
    sky_type: str = ""
    sun_xyz: Vec3 = (0.0, 10.0, 10.0)
    camera_far: float = 1000.0


def parse_track_xml(path: Path) -> TrackInfo:
    """Parse STK track.xml metadata (src/tracks/track.cpp:L527-L624)."""
    root = ET.parse(path).getroot()
    if root.tag != "track":
        raise ValueError(f"Expected <track> root in {path}, got <{root.tag}>")

    laps = _parse_int(root.get("default-number-of-laps"), 3)
    if laps <= 0:
        laps = 3

    is_arena = _parse_bool(root.get("arena"), False)
    is_soccer = _parse_bool(root.get("soccer"), False)
    auto_rescue_default = not (is_arena or is_soccer)

    modes: list[TrackModeInfo] = []
    for child in root:
        if child.tag == "mode":
            modes.append(
                TrackModeInfo(
                    name=child.get("name", "standard"),
                    quads=child.get("quads", "quads.xml"),
                    graph=child.get("graph", "graph.xml"),
                    scene=child.get("scene", "scene.xml"),
                )
            )
    if not modes:
        modes.append(TrackModeInfo())

    groups_raw = root.get("groups", "")
    groups = [g for g in re.split(r"[\s,]+", groups_raw.strip()) if g]

    return TrackInfo(
        name=root.get("name", path.parent.name),
        designer=root.get("designer", ""),
        version=_parse_int(root.get("version"), 0),
        gravity=_parse_float(root.get("gravity"), 9.80665),
        friction=_parse_float(root.get("friction"), 0.5),
        default_laps=laps,
        reverse_available=False if (is_arena or is_soccer) else _parse_bool(root.get("reverse"), False),
        push_back=_parse_bool(root.get("push-back"), True),
        auto_rescue=_parse_bool(root.get("auto-rescue"), auto_rescue_default),
        smooth_normals=_parse_bool(root.get("smooth-normals"), False),
        is_arena=is_arena,
        is_soccer=is_soccer,
        is_ctf=_parse_bool(root.get("ctf"), False),
        groups=groups,
        modes=modes,
    )


def _resolve_quad_point(raw: str, prior_quads: list[QuadNode]) -> Vec3:
    raw = raw.strip()
    if ":" in raw:
        n_str, p_str = raw.split(":", 1)
        return prior_quads[int(n_str)].points[int(p_str)]
    return _parse_vec3(raw)


def _quad_normal(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3) -> Vec3:
    # Average triangle normals (p0,p1,p2) and (p0,p2,p3)
    ux, uy, uz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
    vx, vy, vz = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
    nx = uy * vz - uz * vy
    ny = uz * vx - ux * vz
    nz = ux * vy - uy * vx
    length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length < 1e-9:
        return (0.0, 1.0, 0.0)
    if ny < 0:
        nx, ny, nz = -nx, -ny, -nz
    return (nx / length, ny / length, nz / length)


def parse_quads_xml(path: Path) -> tuple[list[QuadNode], float, float]:
    """Parse STK quads.xml (src/tracks/drive_graph.cpp:L66-L162)."""
    root = ET.parse(path).getroot()
    if root.tag != "quads":
        raise ValueError(f"Expected <quads> root in {path}, got <{root.tag}>")

    min_ht = -1.0
    max_ht = 5.0
    quads: list[QuadNode] = []

    for child in root:
        if child.tag == "height-testing":
            min_ht = _parse_float(child.get("min"), min_ht)
            max_ht = _parse_float(child.get("max"), max_ht)
            continue
        if child.tag != "quad":
            continue

        p0 = _resolve_quad_point(child.attrib["p0"], quads)
        p1 = _resolve_quad_point(child.attrib["p1"], quads)
        p2 = _resolve_quad_point(child.attrib["p2"], quads)
        p3 = _resolve_quad_point(child.attrib["p3"], quads)
        center = (
            0.25 * (p0[0] + p1[0] + p2[0] + p3[0]),
            0.25 * (p0[1] + p1[1] + p2[1] + p3[1]),
            0.25 * (p0[2] + p1[2] + p2[2] + p3[2]),
        )
        direction = child.get("direction", "")
        ignored = direction == "reverse"
        invisible = _parse_bool(child.get("invisible"), False) or ignored
        ai_ignore = _parse_bool(child.get("ai-ignore"), False) or ignored

        quads.append(
            QuadNode(
                index=len(quads),
                points=(p0, p1, p2, p3),
                center=center,
                normal=_quad_normal(p0, p1, p2, p3),
                invisible=invisible,
                ai_ignore=ai_ignore,
                ignored=ignored,
                direction=direction,
            )
        )
    return quads, min_ht, max_ht


def _dist(a: Vec3, b: Vec3) -> float:
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


def _quad_lower_center(q: QuadNode) -> Vec3:
    """Lower edge midpoint matching DriveNode::m_lower_center (`drive_node.cpp:L55`)."""
    p0, p1 = q.points[0], q.points[1]
    return (0.5 * (p0[0] + p1[0]), 0.5 * (p0[1] + p1[1]), 0.5 * (p0[2] + p1[2]))


def parse_graph_and_quads(quads_path: Path, graph_path: Optional[Path]) -> DriveGraphData:
    """Parse quads.xml + graph.xml and compute driveline distances."""
    quads, min_ht, max_ht = parse_quads_xml(quads_path)
    num_quads = len(quads)
    has_explicit_graph = graph_path is not None and graph_path.exists()

    def add_edge(u: int, v: int) -> None:
        if 0 <= u < num_quads and 0 <= v < num_quads and v not in quads[u].successors:
            quads[u].successors.append(v)

    if has_explicit_graph and graph_path is not None:
        root = ET.parse(graph_path).getroot()
        for child in root:
            if child.tag == "edge-loop":
                start = _parse_int(child.get("from"))
                end = _parse_int(child.get("to"))
                for i in range(start, end + 1):
                    add_edge(i, i + 1 if i != end else start)
            elif child.tag == "edge-line":
                start = _parse_int(child.get("from"))
                end = _parse_int(child.get("to"))
                for i in range(start, end):
                    add_edge(i, i + 1)
            elif child.tag == "edge":
                add_edge(_parse_int(child.get("from")), _parse_int(child.get("to")))

    # Default successors for any isolated nodes (drive_graph.cpp:L170, L248)
    for i, q in enumerate(quads):
        if not q.successors and num_quads > 0:
            add_edge(i, (i + 1) % num_quads)

    # Longest-path distance_from_start along m_lower_center edges (drive_graph.cpp:L503-L560)
    lap_length = 0.0
    if num_quads > 0:
        lower_centers = [_quad_lower_center(q) for q in quads]
        dist = [-1.0] * num_quads
        dist[0] = 0.0
        relax_count = [0] * num_quads
        queue = [0]

        while queue:
            cur = queue.pop(0)
            cur_d = dist[cur]
            for nxt in quads[cur].successors:
                if nxt == 0:
                    continue
                new_d = cur_d + _dist(lower_centers[cur], lower_centers[nxt])
                if dist[nxt] < new_d:
                    if relax_count[nxt] >= num_quads:
                        continue
                    dist[nxt] = new_d
                    relax_count[nxt] += 1
                    queue.append(nxt)

        for i, q in enumerate(quads):
            q.distance_from_start = max(dist[i], 0.0)

        for u, q in enumerate(quads):
            if dist[u] < 0.0 or not q.successors:
                continue
            for nxt in q.successors:
                if nxt == 0:
                    total = q.distance_from_start + _dist(lower_centers[u], lower_centers[0])
                    if total > lap_length:
                        lap_length = total
        if lap_length <= 0.0:
            for u, q in enumerate(quads):
                if q.successors and dist[u] >= 0.0:
                    total = q.distance_from_start + _dist(lower_centers[u], lower_centers[q.successors[0]])
                    if total > lap_length:
                        lap_length = total

    return DriveGraphData(
        quads=quads,
        min_height_testing=min_ht,
        max_height_testing=max_ht,
        lap_length=lap_length,
        has_explicit_graph=has_explicit_graph,
    )


def parse_scene_xml(path: Path) -> SceneData:
    """Parse STK scene.xml (src/tracks/track.cpp:L1273-L1380, L2419-L2550)."""
    root = ET.parse(path).getroot()
    scene = SceneData()
    start_counter = 0

    for child in root:
        tag = child.tag
        if tag == "track":
            scene.main_track_model = child.get("model", "")
            scene.main_track_xyz = _parse_xyz_elem(child, (0.0, 0.0, 0.0))
            scene.main_track_hpr = _parse_hpr_elem(child, (0.0, 0.0, 0.0))
            for sub in child:
                if sub.tag == "static-object":
                    scene.objects.append(
                        SceneObjectData(
                            index=len(scene.objects),
                            tag="static-object",
                            obj_id=sub.get("id", ""),
                            obj_type=sub.get("type", "static"),
                            model=sub.get("model", ""),
                            name=sub.get("name", ""),
                            interaction=sub.get("interaction", ""),
                            shape=sub.get("shape", ""),
                            xyz=_parse_xyz_elem(sub, (0.0, 0.0, 0.0)),
                            hpr=_parse_hpr_elem(sub, (0.0, 0.0, 0.0)),
                            scale=_parse_vec3(sub.get("scale"), (1.0, 1.0, 1.0)),
                        )
                    )
        elif tag == "lod":
            for group in child:
                for model_node in group:
                    m = model_node.get("model")
                    if m:
                        scene.lod_models.append(m)
        elif tag in ("object", "library", "particle-emitter", "light"):
            scene.objects.append(
                SceneObjectData(
                    index=len(scene.objects),
                    tag=tag,
                    obj_id=child.get("id", ""),
                    obj_type=child.get("type", ""),
                    model=child.get("model", ""),
                    name=child.get("name", ""),
                    interaction=child.get("interaction", ""),
                    shape=child.get("shape", ""),
                    xyz=_parse_xyz_elem(child, (0.0, 0.0, 0.0)),
                    hpr=_parse_hpr_elem(child, (0.0, 0.0, 0.0)),
                    scale=_parse_vec3(child.get("scale"), (1.0, 1.0, 1.0)),
                )
            )
        elif tag == "checks":
            for idx, chk in enumerate(child):
                kind = chk.get("kind", "")
                if not kind and chk.tag in ("cannon", "goal"):
                    kind = chk.tag
                default_active = kind in ("lap", "cannon", "goal")
                active = _parse_bool(chk.get("active"), default_active)
                other_ids = _parse_int_list(chk.get("other-ids")) or _parse_int_list(chk.get("other-id"))
                same_group = _parse_int_list(chk.get("same-group"))
                if idx not in same_group:
                    same_group.append(idx)

                p1: Optional[Vec3] = None
                p2: Optional[Vec3] = None
                xyz: Optional[Vec3] = None
                radius = _parse_float(chk.get("radius"), 0.0)

                if chk.tag in ("check-line", "check-lap", "cannon", "goal"):
                    p1_raw = chk.get("p1")
                    p2_raw = chk.get("p2")
                    if p1_raw and p2_raw:
                        min_h = chk.get("min-height")
                        if min_h is not None:
                            mh = _parse_float(min_h, 0.0)
                            x1, z1 = _parse_vec2(p1_raw)
                            x2, z2 = _parse_vec2(p2_raw)
                            p1 = (x1, mh, z1)
                            p2 = (x2, mh, z2)
                        else:
                            p1 = _parse_vec3(p1_raw)
                            p2 = _parse_vec3(p2_raw)
                if child.get("xyz") is not None or any(child.get(k) is not None for k in ("x", "y", "z")):
                    pass
                if chk.get("xyz") is not None or any(chk.get(k) is not None for k in ("x", "y", "z")):
                    xyz = _parse_xyz_elem(chk)

                scene.checks.append(
                    CheckStructureData(
                        index=idx,
                        tag=chk.tag,
                        kind=kind or chk.tag,
                        active_at_reset=active,
                        other_ids=other_ids,
                        same_group=same_group,
                        p1=p1,
                        p2=p2,
                        xyz=xyz,
                        radius=radius,
                    )
                )
        elif tag in ("item", "banana", "small-nitro", "big-nitro", "easter-egg"):
            scene.items.append(
                ItemPlacementData(
                    index=len(scene.items),
                    item_type=tag,
                    xyz=_parse_xyz_elem(child, (0.0, 0.0, 0.0)),
                    drop=_parse_bool(child.get("drop"), True),
                )
            )
        elif tag == "start":
            pos = _parse_int(child.get("position"), start_counter)
            start_counter += 1
            scene.starts.append(
                StartPosData(
                    position=pos,
                    xyz=_parse_xyz_elem(child, (0.0, 0.0, 0.0)),
                    heading=_parse_float(child.get("h"), 0.0),
                )
            )
        elif tag == "default-start":
            scene.default_start = StartPosData(
                position=0,
                xyz=_parse_xyz_elem(child, (0.0, 0.0, 0.0)),
                heading=_parse_float(child.get("h"), 0.0),
            )
        elif tag in ("sky-box", "sky-dome", "sky-color"):
            scene.sky_type = tag
        elif tag == "sun":
            scene.sun_xyz = _parse_xyz_elem(child, scene.sun_xyz)
        elif tag == "camera":
            scene.camera_far = _parse_float(child.get("far"), scene.camera_far)

    return scene
