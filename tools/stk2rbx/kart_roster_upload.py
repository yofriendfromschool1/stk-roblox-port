# SPDX-License-Identifier: GPL-3.0-or-later
"""Batch convert & Open Cloud upload the full 18-kart STK 1.5 roster (rev 18627)."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from .kart_emit import (
    convert_kart,
    emit_kart_bounds_luau,
    parse_kart_xml,
)
from .open_cloud_upload import ASSETS_ENDPOINT, OPEN_CLOUD_BASE, _http_json, upload_glb_model

CREATOR_USER_ID = "7225229891"
STK_KARTS_ROOT = Path(r"C:\dev\stk-assets\karts")
STK_TEX_ROOT = Path(r"C:\dev\stk-assets\textures")
CC0_SUBS_ROOT = Path("assets/karts/_cc0_substitutes")

ALL_KARTS = [
    "adiumy", "amanda", "beastie", "emule", "gavroche", "gnu",
    "hexley", "kiki", "konqi", "nolok", "pidgin", "puffy",
    "sara_the_racer", "sara_the_wizard", "suzanne", "tux", "wilber", "xue",
]


def resolve_texture_file(kart_id: str, tex_name: str, repo_root: Path) -> Path:
    p_cc0 = repo_root / CC0_SUBS_ROOT / tex_name
    if p_cc0.is_file():
        return p_cc0
    p_local = STK_KARTS_ROOT / kart_id / tex_name
    if p_local.is_file():
        return p_local
    p_shared = STK_TEX_ROOT / tex_name
    if p_shared.is_file():
        return p_shared
    # Case-insensitive fallback inside kart_dir / shared_tex_dir
    low = tex_name.lower()
    for folder in (STK_KARTS_ROOT / kart_id, STK_TEX_ROOT):
        if folder.is_dir():
            for f in folder.iterdir():
                if f.name.lower() == low and f.is_file():
                    return f
    raise FileNotFoundError(f"Missing texture '{tex_name}' for kart '{kart_id}'")


def upload_decal_image(img_path: Path, display_name: str, creator_user_id: str, api_key: str, poll_timeout_sec: float = 90.0) -> str:
    ext = img_path.suffix.lower()
    mime = "image/jpeg" if ext in (".jpg", ".jpeg") else "image/png"
    boundary = f"----OpenKartDecal{uuid.uuid4().hex}"
    payload = {
        "assetType": "Decal",
        "displayName": display_name[:50],
        "description": "OpenKart STK 1.5 kart texture/icon (rev 18627)",
        "creationContext": {"creator": {"userId": str(creator_user_id)}},
    }
    chunks = [
        f'--{boundary}\r\nContent-Disposition: form-data; name="request"\r\nContent-Type: application/json\r\n\r\n{json.dumps(payload, separators=(",", ":"))}\r\n'.encode("utf-8"),
        f'--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; filename="{img_path.name}"\r\nContent-Type: {mime}\r\n\r\n'.encode("utf-8"),
        img_path.read_bytes(),
        f"\r\n--{boundary}--\r\n".encode("utf-8"),
    ]
    op = _http_json(ASSETS_ENDPOINT, api_key=api_key, method="POST", body=b"".join(chunks), content_type=f"multipart/form-data; boundary={boundary}")
    op_id = op.get("operationId") or ""
    op_path = str(op.get("path") or "").lstrip("/")
    if not op_path and op_id:
        op_path = f"assets/v1/operations/{op_id}"
    elif op_path and not op_path.startswith("assets/"):
        op_path = f"assets/v1/{op_path}"
    if not op.get("done"):
        poll_url = f"{OPEN_CLOUD_BASE}/{op_path}"
        deadline = time.monotonic() + poll_timeout_sec
        delay = 1.0
        while time.monotonic() < deadline:
            time.sleep(delay)
            op = _http_json(poll_url, api_key=api_key, method="GET")
            if op.get("done"):
                break
            delay = min(3.0, delay * 1.25)
    if not op.get("done"):
        raise TimeoutError(f"Timed out waiting for Decal operation {op_path}")
    if op.get("error"):
        raise RuntimeError(f"Decal operation failed: {op['error']}")
    asset_id = (op.get("response") or {}).get("assetId")
    if not asset_id:
        raise RuntimeError(f"Decal operation missing assetId: {op}")
    return str(asset_id)


def convert_all(repo_root: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for kid in ALL_KARTS:
        kdir = STK_KARTS_ROOT / kid
        out_rbxmx = repo_root / "assets" / "roblox" / "karts" / f"{kid}.rbxmx"
        out_glb = repo_root / "build" / "karts" / kid
        rep_path = repo_root / "build" / "karts" / f"{kid}_report.json"
        manifest_path = repo_root / "assets" / "karts" / kid / "roblox_assets.json"
        rep = convert_kart(
            kart_dir=kdir,
            out_model=out_rbxmx,
            out_glb_dir=out_glb,
            report_path=rep_path,
            revision="18627",
            assets_manifest_path=manifest_path if manifest_path.is_file() else None,
        )
        reports.append(rep)
        # Ensure manifest skeleton exists for non-tux karts
        if not manifest_path.is_file():
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            spec = parse_kart_xml(kdir / "kart.xml")
            parts_meta: dict[str, Any] = {}
            textures_meta: dict[str, str] = {}
            for p in rep["parts"]:
                subparts = p.get("subparts")
                if subparts:
                    for sp in subparts:
                        tname = sp["texture_1"]
                        textures_meta.setdefault(tname, "")
                        parts_meta[sp["part_name"]] = {
                            "glbFile": f"build/karts/{kid}/{sp['glb_file']}",
                            "meshId": "",
                            "textureId": "",
                            "material": tname,
                            "robloxMaterial": "SmoothPlastic",
                            "importFlipY180": True,
                        }
                else:
                    tname = p["materials"][0]
                    textures_meta.setdefault(tname, "")
                    mat_rbx = "Rubber" if "wheel_slot" in p else "SmoothPlastic"
                    parts_meta[p["node_name"]] = {
                        "glbFile": f"build/karts/{kid}/{p['glb_file']}",
                        "meshId": "",
                        "textureId": "",
                        "material": tname,
                        "robloxMaterial": mat_rbx,
                        "importFlipY180": True,
                    }
            doc = {
                "kartId": kid,
                "kartName": spec.name,
                "kartType": spec.kart_type,
                "sourceRevision": "18627",
                "importFlipY180": True,
                "iconFile": spec.icon_file,
                "iconDecalId": "",
                "iconId": "",
                "textures": textures_meta,
                "textureDecalIds": {},
                "parts": parts_meta,
            }
            manifest_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    emit_kart_bounds_luau(reports, repo_root / "src" / "shared" / "kart" / "KartBoundsData.lua")
    return reports


def upload_pending(repo_root: Path, workers: int = 6) -> None:
    api_key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY", "")
    if not api_key:
        raise RuntimeError("Missing ROBLOX_OPEN_CLOUD_KEY")

    # 1. GUI icons (mass, speed, power, nitro, random_kart)
    menu_manifest_path = repo_root / "assets" / "gui" / "menu" / "roblox_assets.json"
    menu_doc = json.loads(menu_manifest_path.read_text(encoding="utf-8"))
    menu_assets = menu_doc.setdefault("assets", {})
    menu_decals = menu_doc.setdefault("decalIds", {})
    for ico_name in ["mass.png", "speed.png", "power.png", "nitro.png", "random_kart.png"]:
        if not menu_assets.get(ico_name) and not menu_decals.get(ico_name):
            ico_path = repo_root / "assets" / "gui" / "menu" / ico_name
            did = upload_decal_image(ico_path, f"OpenKart_gui_{ico_path.stem}", CREATOR_USER_ID, api_key)
            menu_decals[ico_name] = did
            menu_manifest_path.write_text(json.dumps(menu_doc, indent=2) + "\n", encoding="utf-8")
            print(f"Uploaded GUI decal {ico_name} -> decalId={did}")

    # 2. Gather all pending kart textures, icons, and GLB models
    tasks = []
    manifests: dict[str, dict[str, Any]] = {}
    for kid in ALL_KARTS:
        mpath = repo_root / "assets" / "karts" / kid / "roblox_assets.json"
        doc = json.loads(mpath.read_text(encoding="utf-8"))
        manifests[kid] = doc

        # Kart face icon
        if not doc.get("iconId") and not doc.get("iconDecalId") and doc.get("iconFile"):
            ico_p = STK_KARTS_ROOT / kid / doc["iconFile"]
            tasks.append(("icon", kid, doc["iconFile"], ico_p))

        # Textures
        t_decals = doc.setdefault("textureDecalIds", {})
        for tname, tid in doc.get("textures", {}).items():
            if not tid and not t_decals.get(tname):
                tpath = resolve_texture_file(kid, tname, repo_root)
                tasks.append(("tex", kid, tname, tpath))

        # Mesh GLBs
        for pname, pmeta in doc.get("parts", {}).items():
            if not pmeta.get("meshId") and not pmeta.get("modelAssetId"):
                glb_p = repo_root / pmeta["glbFile"]
                tasks.append(("glb", kid, pname, glb_p))

    print(f"Pending Open Cloud uploads: {len(tasks)}")
    if not tasks:
        return

    def run_task(t):
        kind, kid, key, fpath = t
        if kind == "icon":
            return kind, kid, key, upload_decal_image(fpath, f"OpenKart_icon_{kid}", CREATOR_USER_ID, api_key)
        elif kind == "tex":
            return kind, kid, key, upload_decal_image(fpath, f"OpenKart_{kid}_{Path(key).stem}", CREATOR_USER_ID, api_key)
        else:
            return kind, kid, key, upload_glb_model(fpath, f"OpenKart_{kid}_{key}", CREATOR_USER_ID, api_key)

    errors: list[str] = []
    done_cnt = 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(run_task, t): t for t in tasks}
        for fut in as_completed(futs):
            t = futs[fut]
            try:
                kind, kid, key, asset_id = fut.result()
                doc = manifests[kid]
                if kind == "icon":
                    doc["iconDecalId"] = asset_id
                elif kind == "tex":
                    doc.setdefault("textureDecalIds", {})[key] = asset_id
                else:
                    doc["parts"][key]["modelAssetId"] = asset_id
                mpath = repo_root / "assets" / "karts" / kid / "roblox_assets.json"
                mpath.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
                done_cnt += 1
                print(f"[{done_cnt}/{len(tasks)}] {kind} {kid}.{key} -> {asset_id}")
            except Exception as exc:
                msg = f"ERROR {t[0]} {t[1]}.{t[2]}: {exc}"
                print(msg)
                errors.append(msg)

    if errors:
        raise RuntimeError(f"{len(errors)} upload(s) failed; first: {errors[0]}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--convert-only", action="store_true")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args()
    repo_root = Path(".").resolve()
    reports = convert_all(repo_root)
    print(f"Converted {len(reports)} karts -> build/karts/ & src/shared/kart/KartBoundsData.lua")
    if args.upload and not args.convert_only:
        upload_pending(repo_root, workers=args.workers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
