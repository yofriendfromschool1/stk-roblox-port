# SPDX-License-Identifier: GPL-3.0-or-later
"""CLI for tools/stk2rbx: fetch upstream STK track data and convert to Rojo .model.json."""

from __future__ import annotations

import argparse
import html
import json
import re
import urllib.parse
import urllib.request
from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional

from .mesh_inspect import (
    ROBLOX_HARD_TRI_CAP,
    ROBLOX_MAX_PART_SIZE_STUDS,
    ROBLOX_MAX_SUBMESHES_PER_IMPORT,
    ROBLOX_SOFT_TRI_CAP,
    MeshAudit,
    audit_mesh,
)
from .rbx_emit import emit_track_model_json
from .xml_parser import parse_graph_and_quads, parse_scene_xml, parse_track_xml

STK_ASSETS_TRACKS_BASE = "https://svn.code.sf.net/p/supertuxkart/code/stk-assets/tracks"
FETCH_EXTENSIONS = {".xml", ".spm", ".b3d", ".txt"}
MEDIA_EXTENSIONS = {".png", ".jpg", ".jpeg", ".ogg", ".wav", ".music"}


def fetch_track(track_id: str, dest_dir: Path, include_media: bool = False) -> tuple[str, list[str]]:
    """Download one STK track directory from SourceForge SVN over HTTPS."""
    base_url = f"{STK_ASSETS_TRACKS_BASE}/{track_id}/"
    req = urllib.request.Request(base_url, headers={"User-Agent": "OpenKart-stk2rbx/0.1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        index_html = resp.read().decode("utf-8", errors="replace")

    rev_match = re.search(r"Revision\s+(\d+)", index_html)
    revision = rev_match.group(1) if rev_match else "unknown"

    hrefs = re.findall(r'href="([^"]+)"', index_html)
    allowed = FETCH_EXTENSIONS | (MEDIA_EXTENSIONS if include_media else set())

    dest_dir.mkdir(parents=True, exist_ok=True)
    downloaded: list[str] = []

    for raw_href in hrefs:
        fname = html.unescape(raw_href)
        if fname.startswith("?") or fname.startswith("/") or fname == "../" or fname.endswith("/"):
            continue
        ext = Path(fname).suffix.lower()
        if ext not in allowed and fname.lower() != "licenses.txt":
            continue
        file_url = urllib.parse.urljoin(base_url, raw_href)
        out_path = dest_dir / Path(fname).name
        file_req = urllib.request.Request(file_url, headers={"User-Agent": "OpenKart-stk2rbx/0.1"})
        with urllib.request.urlopen(file_req, timeout=60) as f_resp:
            out_path.write_bytes(f_resp.read())
        downloaded.append(out_path.name)

    (dest_dir / "svn_revision.txt").write_text(f"{revision}\n", encoding="utf-8")
    return revision, sorted(downloaded)


def convert_track(
    track_dir: Path,
    out_path: Path,
    report_path: Optional[Path] = None,
    revision: str = "",
) -> dict[str, Any]:
    """Parse track XMLs, inspect all local meshes, and emit Rojo .model.json + audit report."""
    track_id = track_dir.name
    if not revision and (track_dir / "svn_revision.txt").exists():
        revision = (track_dir / "svn_revision.txt").read_text(encoding="utf-8").strip()

    track_info = parse_track_xml(track_dir / "track.xml")
    mode = track_info.modes[0]
    quads_path = track_dir / mode.quads
    graph_path = track_dir / mode.graph
    scene_path = track_dir / mode.scene

    graph = parse_graph_and_quads(quads_path, graph_path if graph_path.exists() else None)
    scene = parse_scene_xml(scene_path)

    # Audit every mesh file present in track_dir
    mesh_files = sorted(
        [p for p in track_dir.iterdir() if p.is_file() and p.suffix.lower() in (".spm", ".b3d")],
        key=lambda p: p.name.lower(),
    )
    mesh_audits: dict[str, MeshAudit] = {}
    for mf in mesh_files:
        mesh_audits[mf.name] = audit_mesh(mf)

    # Identify referenced models missing locally (e.g., external library refs or missing LODs)
    referenced_models = set()
    if scene.main_track_model:
        referenced_models.add(scene.main_track_model)
    referenced_models.update(scene.lod_models)
    for obj in scene.objects:
        if obj.model:
            referenced_models.add(obj.model)
    missing_local_models = sorted(m for m in referenced_models if m not in mesh_audits)
    external_libraries = sorted({obj.name for obj in scene.objects if obj.tag == "library" and obj.name})

    model_json = emit_track_model_json(
        track_id=track_id,
        track_info=track_info,
        graph=graph,
        scene=scene,
        mesh_audits=mesh_audits,
        assets_revision=revision,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(model_json, indent=2) + "\n", encoding="utf-8")

    # Build detailed audit report
    formats_found = sorted({a.mesh_format for a in mesh_audits.values()})
    cap_violations: list[dict[str, Any]] = []
    mesh_summaries: list[dict[str, Any]] = []

    for name, a in mesh_audits.items():
        exceeds_20k_sub = [s for s in a.submeshes if s.exceeds_20k]
        exceeds_10k_sub = [s for s in a.submeshes if s.exceeds_10k]
        summary = {
            "file_name": a.file_name,
            "file_size_bytes": a.file_size_bytes,
            "mesh_format": a.mesh_format,
            "vertex_count": a.vertex_count,
            "triangle_count": a.triangle_count,
            "submesh_count": a.submesh_count,
            "material_count": a.material_count,
            "max_submesh_triangles": a.max_submesh_triangles,
            "size_m": list(a.size_m),
            "size_studs": list(a.size_studs),
            "exceeds_20k_whole": a.exceeds_20k_whole,
            "exceeds_10k_whole": a.exceeds_10k_whole,
            "exceeds_20k_any_submesh": a.exceeds_20k_any_submesh,
            "exceeds_10k_any_submesh": a.exceeds_10k_any_submesh,
            "exceeds_2048_studs": a.exceeds_2048_studs,
            "exceeds_200_submeshes": a.exceeds_200_submeshes,
            "submeshes": [
                {
                    **asdict(s),
                    "size_studs": list(s.size_studs),
                    "exceeds_20k": s.exceeds_20k,
                    "exceeds_10k": s.exceeds_10k,
                    "exceeds_2048_studs": s.exceeds_2048_studs,
                }
                for s in a.submeshes
            ],
        }
        mesh_summaries.append(summary)

        if (
            a.exceeds_20k_whole
            or a.exceeds_10k_whole
            or a.exceeds_2048_studs
            or a.exceeds_200_submeshes
        ):
            cap_violations.append(
                {
                    "file_name": name,
                    "mesh_format": a.mesh_format,
                    "triangle_count": a.triangle_count,
                    "max_submesh_triangles": a.max_submesh_triangles,
                    "size_studs": list(a.size_studs),
                    "exceeds_20k_whole": a.exceeds_20k_whole,
                    "exceeds_10k_whole": a.exceeds_10k_whole,
                    "submeshes_over_20k": [
                        {
                            "submesh_index": s.submesh_index,
                            "texture_1": s.texture_1,
                            "triangles": s.triangle_count,
                        }
                        for s in exceeds_20k_sub
                    ],
                    "submeshes_over_10k": [
                        {
                            "submesh_index": s.submesh_index,
                            "texture_1": s.texture_1,
                            "triangles": s.triangle_count,
                        }
                        for s in exceeds_10k_sub
                    ],
                    "exceeds_2048_studs": a.exceeds_2048_studs,
                    "exceeds_200_submeshes": a.exceeds_200_submeshes,
                }
            )

    report = {
        "track_id": track_id,
        "track_name": track_info.name,
        "assets_revision": revision,
        "roblox_caps": {
            "hard_tri_cap_per_mesh": ROBLOX_HARD_TRI_CAP,
            "soft_tri_cap_per_mesh": ROBLOX_SOFT_TRI_CAP,
            "max_part_size_studs": ROBLOX_MAX_PART_SIZE_STUDS,
            "max_submeshes_per_import": ROBLOX_MAX_SUBMESHES_PER_IMPORT,
        },
        "xml_summary": {
            "quad_count": len(graph.quads),
            "lap_length_m": round(graph.lap_length, 3),
            "checkpoint_count": len(scene.checks),
            "item_count": len(scene.items),
            "scene_object_count": len(scene.objects),
            "start_count": len(scene.starts),
            "main_track_model": scene.main_track_model,
            "lod_models": scene.lod_models,
            "external_libraries": external_libraries,
            "missing_local_models": missing_local_models,
        },
        "mesh_formats_found": formats_found,
        "mesh_count": len(mesh_summaries),
        "total_triangles_all_local_meshes": sum(a.triangle_count for a in mesh_audits.values()),
        "total_vertices_all_local_meshes": sum(a.vertex_count for a in mesh_audits.values()),
        "cap_violations": cap_violations,
        "meshes": mesh_summaries,
    }

    if report_path is not None:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return report


def _print_report(report: dict[str, Any]) -> None:
    xs = report["xml_summary"]
    print(f"=== stk2rbx conversion: {report['track_id']} ({report['track_name']}) rev={report['assets_revision']} ===")
    print(
        f"XML: quads={xs['quad_count']}, lap={xs['lap_length_m']}m, "
        f"checks={xs['checkpoint_count']}, items={xs['item_count']}, "
        f"objects={xs['scene_object_count']}, starts={xs['start_count']}"
    )
    print(f"Mesh formats found: {', '.join(report['mesh_formats_found']) or 'none'}")
    print(
        f"Local meshes: {report['mesh_count']}, total tris={report['total_triangles_all_local_meshes']}, "
        f"total verts={report['total_vertices_all_local_meshes']}"
    )
    if xs["external_libraries"]:
        print(f"External libraries referenced: {', '.join(xs['external_libraries'])}")
    print("\n--- Per-Mesh Breakdown ---")
    for m in report["meshes"]:
        flags = []
        if m["exceeds_20k_whole"]:
            flags.append(">20k_WHOLE")
        elif m["exceeds_10k_whole"]:
            flags.append(">10k_WHOLE")
        if m["exceeds_20k_any_submesh"]:
            flags.append(">20k_SUBMESH")
        elif m["exceeds_10k_any_submesh"]:
            flags.append(">10k_SUBMESH")
        if m["exceeds_2048_studs"]:
            flags.append(">2048_STUDS")
        flag_str = f" [{', '.join(flags)}]" if flags else ""
        print(
            f"  {m['file_name']:32s} {m['mesh_format']:4s} "
            f"tris={m['triangle_count']:6d} verts={m['vertex_count']:6d} "
            f"submeshes={m['submesh_count']:3d} max_sub_tris={m['max_submesh_triangles']:6d} "
            f"studs=({m['size_studs'][0]:.1f}x{m['size_studs'][1]:.1f}x{m['size_studs'][2]:.1f}){flag_str}"
        )


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="stk2rbx", description="Convert one STK 1.5 track to Roblox")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="Download one track directory from STK SourceForge SVN")
    p_fetch.add_argument("track_id", help="Upstream track directory name (e.g. sandtrack)")
    p_fetch.add_argument("--dest", required=True, type=Path, help="Output directory outside repo")
    p_fetch.add_argument("--include-media", action="store_true", help="Also download textures/audio")

    p_conv = sub.add_parser("convert", help="Parse track XMLs + inspect meshes + emit .model.json")
    p_conv.add_argument("track_dir", type=Path, help="Local upstream track directory")
    p_conv.add_argument("--out", required=True, type=Path, help="Output .model.json path")
    p_conv.add_argument("--report", type=Path, default=None, help="Optional JSON audit report path")
    p_conv.add_argument("--revision", default="", help="Override upstream SVN revision string")

    args = parser.parse_args(argv)
    if args.cmd == "fetch":
        rev, files = fetch_track(args.track_id, args.dest, include_media=args.include_media)
        print(f"Fetched {args.track_id} (rev {rev}): {len(files)} files -> {args.dest}")
        for f in files:
            print(f"  {f}")
        return 0

    if args.cmd == "convert":
        report = convert_track(args.track_dir, args.out, args.report, revision=args.revision)
        _print_report(report)
        return 0

    return 1
