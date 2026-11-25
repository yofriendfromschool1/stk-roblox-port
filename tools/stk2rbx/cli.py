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

from .item_emit import convert_items
from .kart_emit import convert_kart
from .mesh_inspect import (
    ROBLOX_HARD_TRI_CAP,
    ROBLOX_MAX_PART_SIZE_STUDS,
    ROBLOX_MAX_SUBMESHES_PER_IMPORT,
    ROBLOX_SOFT_TRI_CAP,
    MeshAudit,
    audit_mesh,
)
from .rbx_emit import emit_track_model_json
from .xml_parser import MaterialData, parse_graph_and_quads, parse_materials_xml, parse_scene_xml, parse_track_xml

STK_SVN_REPO_BASE = "https://svn.code.sf.net/p/supertuxkart/code"
STK_ASSETS_TRACKS_BASE = f"{STK_SVN_REPO_BASE}/stk-assets/tracks"
FETCH_EXTENSIONS = {".xml", ".spm", ".b3d", ".txt"}
MEDIA_EXTENSIONS = {".png", ".jpg", ".jpeg", ".ogg", ".wav", ".music"}


def _svn_assets_url(subpath: str, revision: str = "") -> str:
    clean = subpath.lstrip("/")
    if revision:
        return f"{STK_SVN_REPO_BASE}/!svn/bc/{revision}/stk-assets/{clean}"
    return f"{STK_SVN_REPO_BASE}/stk-assets/{clean}"


def _fetch_svn_dir(
    subpath: str,
    dest_dir: Path,
    revision: str = "",
    include_media: bool = False,
) -> tuple[str, list[str]]:
    """Download one SVN directory from stk-assets over HTTPS (optionally pinned via !svn/bc/<rev>)."""
    base_url = _svn_assets_url(subpath, revision).rstrip("/") + "/"
    req = urllib.request.Request(base_url, headers={"User-Agent": "OpenKart-stk2rbx/0.1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        index_html = resp.read().decode("utf-8", errors="replace")

    rev_match = re.search(r"Revision\s+(\d+)", index_html)
    resolved_rev = revision or (rev_match.group(1) if rev_match else "unknown")

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

    (dest_dir / "svn_revision.txt").write_text(f"{resolved_rev}\n", encoding="utf-8")
    return resolved_rev, sorted(downloaded)


def fetch_library(
    lib_name: str,
    dest_dir: Path,
    revision: str = "",
    include_media: bool = False,
) -> tuple[str, list[str]]:
    """Download one STK stk-assets/library/<lib_name> directory at pinned revision."""
    return _fetch_svn_dir(f"library/{lib_name}", dest_dir, revision=revision, include_media=include_media)


def fetch_kart(
    kart_id: str,
    dest_dir: Path,
    revision: str = "",
    include_media: bool = False,
) -> tuple[str, list[str]]:
    """Download one STK stk-assets/karts/<kart_id> directory at pinned revision."""
    return _fetch_svn_dir(f"karts/{kart_id}", dest_dir, revision=revision, include_media=include_media)


def fetch_models(
    dest_dir: Path,
    revision: str = "",
    include_media: bool = False,
) -> tuple[str, list[str]]:
    """Download STK stk-assets/models directory at pinned revision."""
    return _fetch_svn_dir("models", dest_dir, revision=revision, include_media=include_media)


def fetch_track(
    track_id: str,
    dest_dir: Path,
    revision: str = "",
    include_media: bool = False,
    with_libraries: bool = False,
    assets_root: Optional[Path] = None,
) -> tuple[str, list[str], dict[str, list[str]]]:
    """Download one STK track directory (and optionally its referenced library models)."""
    resolved_rev, downloaded = _fetch_svn_dir(
        f"tracks/{track_id}",
        dest_dir,
        revision=revision,
        include_media=include_media,
    )
    fetched_libs: dict[str, list[str]] = {}
    if with_libraries and (dest_dir / "scene.xml").exists():
        root_dir = assets_root if assets_root is not None else dest_dir.parent.parent
        # Also pull root stk-assets/licenses.txt for library license auditing
        lic_url = _svn_assets_url("licenses.txt", resolved_rev if resolved_rev.isdigit() else "")
        lic_req = urllib.request.Request(lic_url, headers={"User-Agent": "OpenKart-stk2rbx/0.1"})
        with urllib.request.urlopen(lic_req, timeout=30) as l_resp:
            root_dir.mkdir(parents=True, exist_ok=True)
            (root_dir / "licenses.txt").write_bytes(l_resp.read())

        scene = parse_scene_xml(dest_dir / "scene.xml")
        lib_names = sorted({obj.name for obj in scene.objects if obj.tag == "library" and obj.name})
        for lib in lib_names:
            _, lfiles = fetch_library(
                lib,
                root_dir / "library" / lib,
                revision=resolved_rev if resolved_rev.isdigit() else "",
                include_media=include_media,
            )
            fetched_libs[lib] = lfiles
    return resolved_rev, downloaded, fetched_libs


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
    materials_path = track_dir / "materials.xml"
    materials: list[MaterialData] = parse_materials_xml(materials_path) if materials_path.exists() else []

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
                    "max_triangle_extent_studs": s.max_triangle_extent_studs,
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
        "materials": [asdict(m) for m in materials],
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
    p_fetch.add_argument("--revision", default="", help="Pin SVN revision via !svn/bc/<rev>/ (e.g. 18627)")
    p_fetch.add_argument("--include-media", action="store_true", help="Also download textures/audio")
    p_fetch.add_argument(
        "--with-libraries",
        action="store_true",
        help="Also fetch external stk-assets/library/* models referenced in scene.xml",
    )
    p_fetch.add_argument(
        "--assets-root",
        type=Path,
        default=None,
        help="Root stk-assets directory outside repo for library/ and root licenses.txt",
    )

    p_conv = sub.add_parser("convert", help="Parse track XMLs + inspect meshes + emit .model.json")
    p_conv.add_argument("track_dir", type=Path, help="Local upstream track directory")
    p_conv.add_argument("--out", required=True, type=Path, help="Output .model.json path")
    p_conv.add_argument("--report", type=Path, default=None, help="Optional JSON audit report path")
    p_conv.add_argument("--revision", default="", help="Override upstream SVN revision string")

    p_fk = sub.add_parser("fetch-kart", help="Download one kart directory from STK SourceForge SVN")
    p_fk.add_argument("kart_id", help="Upstream kart directory name (e.g. tux)")
    p_fk.add_argument("--dest", required=True, type=Path, help="Output directory outside repo")
    p_fk.add_argument("--revision", default="", help="Pin SVN revision via !svn/bc/<rev>/ (e.g. 18627)")
    p_fk.add_argument("--include-media", action="store_true", help="Also download textures/audio")

    p_fm = sub.add_parser("fetch-models", help="Download stk-assets/models directory from STK SourceForge SVN")
    p_fm.add_argument("--dest", required=True, type=Path, help="Output directory outside repo")
    p_fm.add_argument("--revision", default="", help="Pin SVN revision via !svn/bc/<rev>/ (e.g. 18627)")
    p_fm.add_argument("--include-media", action="store_true", help="Also download textures/audio")

    p_ck = sub.add_parser("convert-kart", help="Emit static kart .glb assembly + Rojo .model.json")
    p_ck.add_argument("kart_dir", type=Path, help="Local upstream kart directory")
    p_ck.add_argument("--out-model", required=True, type=Path, help="Output .model.json path")
    p_ck.add_argument("--out-glb-dir", required=True, type=Path, help="Output directory for .glb files")
    p_ck.add_argument("--report", type=Path, default=None, help="Optional JSON audit report path")
    p_ck.add_argument("--revision", default="", help="Override upstream SVN revision string")
    p_ck.add_argument(
        "--assets-manifest",
        type=Path,
        default=None,
        help="Optional JSON mapping part names to uploaded Roblox MeshId/TextureID assets",
    )

    p_ci = sub.add_parser("convert-items", help="Batch convert STK item/powerup .spm meshes to .glb & .model.json")
    p_ci.add_argument("models_dir", type=Path, help="Local STK data/models directory")
    p_ci.add_argument("--out-glb-dir", required=True, type=Path, help="Output directory for item .glb files")
    p_ci.add_argument("--out-models-dir", required=True, type=Path, help="Output directory for Rojo .model.json files")
    p_ci.add_argument("--report", required=True, type=Path, help="Output items-report.json path")
    p_ci.add_argument("--out-bounds-lua", type=Path, default=None, help="Optional ItemBoundsData.lua output path")
    p_ci.add_argument("--assets-manifest", type=Path, default=None, help="Optional assets/items/roblox_assets.json")
    p_ci.add_argument("--revision", default="18627", help="Upstream STK revision string")

    args = parser.parse_args(argv)
    if args.cmd == "fetch":
        rev, files, libs = fetch_track(
            args.track_id,
            args.dest,
            revision=args.revision,
            include_media=args.include_media,
            with_libraries=args.with_libraries,
            assets_root=args.assets_root,
        )
        print(f"Fetched {args.track_id} (rev {rev}): {len(files)} files -> {args.dest}")
        for f in files:
            print(f"  {f}")
        for lib_name, lfiles in libs.items():
            print(f"Fetched library/{lib_name} (rev {rev}): {len(lfiles)} files")
        return 0

    if args.cmd == "convert":
        report = convert_track(args.track_dir, args.out, args.report, revision=args.revision)
        _print_report(report)
        return 0

    if args.cmd == "fetch-kart":
        rev, files = fetch_kart(
            args.kart_id,
            args.dest,
            revision=args.revision,
            include_media=args.include_media,
        )
        print(f"Fetched kart {args.kart_id} (rev {rev}): {len(files)} files -> {args.dest}")
        for f in files:
            print(f"  {f}")
        return 0

    if args.cmd == "fetch-models":
        rev, files = fetch_models(
            args.dest,
            revision=args.revision,
            include_media=args.include_media,
        )
        print(f"Fetched models (rev {rev}): {len(files)} files -> {args.dest}")
        for f in files:
            print(f"  {f}")
        return 0

    if args.cmd == "convert-kart":
        report = convert_kart(
            args.kart_dir,
            args.out_model,
            args.out_glb_dir,
            report_path=args.report,
            revision=args.revision,
            assets_manifest_path=args.assets_manifest,
        )
        b = report["body_driver_combined_bounds_studs"]
        print(
            f"Converted kart {report['kart_id']} (rev={report['assets_revision']}): "
            f"verts={report['total_vertices']} tris={report['total_triangles']} "
            f"body+driver_size={b['size']} trunc3dp={b['truncated_3dp']}"
        )
        return 0

    if args.cmd == "convert-items":
        report = convert_items(
            models_dir=args.models_dir,
            out_glb_dir=args.out_glb_dir,
            out_models_dir=args.out_models_dir,
            report_path=args.report,
            out_bounds_lua=args.out_bounds_lua,
            assets_manifest_path=args.assets_manifest,
            revision=args.revision,
        )
        print(f"Converted {report['item_count']} items (rev={report['assets_revision']}) -> {args.report}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
