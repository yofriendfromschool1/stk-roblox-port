# SPDX-License-Identifier: GPL-3.0-or-later
"""Upload converted item .glb meshes to Roblox Open Cloud Assets API using ROBLOX_OPEN_CLOUD_KEY."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

OPEN_CLOUD_BASE = "https://apis.roblox.com"
ASSETS_ENDPOINT = f"{OPEN_CLOUD_BASE}/assets/v1/assets"


def _encode_multipart(request_payload: dict[str, Any], filename: str, file_bytes: bytes) -> tuple[bytes, str]:
    boundary = f"----OpenKartBoundary{uuid.uuid4().hex}"
    chunks: list[bytes] = []

    req_json = json.dumps(request_payload, separators=(",", ":"))
    chunks.append(
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="request"\r\n'
            "Content-Type: application/json\r\n\r\n"
            f"{req_json}\r\n"
        ).encode("utf-8")
    )

    chunks.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="fileContent"; filename="{filename}"\r\n'
            "Content-Type: model/gltf-binary\r\n\r\n"
        ).encode("utf-8")
    )
    chunks.append(file_bytes)
    chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    body = b"".join(chunks)
    return body, f"multipart/form-data; boundary={boundary}"


def _http_json(url: str, api_key: str, method: str = "GET", body: bytes | None = None, content_type: str | None = None) -> dict[str, Any]:
    headers = {"x-api-key": api_key, "User-Agent": "OpenKart-stk2rbx/0.1"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        err_text = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Open Cloud {method} {url} HTTP {err.code}: {err_text}") from None


def upload_glb_model(
    glb_path: Path,
    display_name: str,
    creator_user_id: str,
    api_key: str,
    poll_timeout_sec: float = 90.0,
) -> str:
    payload = {
        "assetType": "Model",
        "displayName": display_name[:50],
        "description": "OpenKart STK 1.5 item mesh (rev 18627, METERS_PER_STUD=1.0)",
        "creationContext": {
            "creator": {"userId": str(creator_user_id)},
        },
    }
    body, content_type = _encode_multipart(payload, glb_path.name, glb_path.read_bytes())
    op = _http_json(ASSETS_ENDPOINT, api_key=api_key, method="POST", body=body, content_type=content_type)

    op_id = op.get("operationId") or ""
    op_path = str(op.get("path") or "").lstrip("/")
    if not op_path and op_id:
        op_path = f"assets/v1/operations/{op_id}"
    elif op_path and not op_path.startswith("assets/"):
        op_path = f"assets/v1/{op_path}"
    if not op.get("done"):
        if not op_path:
            raise RuntimeError(f"Unexpected Open Cloud response (no path/operationId): {op}")
        poll_url = f"{OPEN_CLOUD_BASE}/{op_path.lstrip('/')}"
        deadline = time.monotonic() + poll_timeout_sec
        delay = 1.0
        while time.monotonic() < deadline:
            time.sleep(delay)
            op = _http_json(poll_url, api_key=api_key, method="GET")
            if op.get("done"):
                break
            delay = min(3.0, delay * 1.25)

    if not op.get("done"):
        raise TimeoutError(f"Timed out waiting for Open Cloud operation {op_path}")
    if op.get("error"):
        raise RuntimeError(f"Open Cloud operation failed: {op['error']}")

    resp_obj = op.get("response") or {}
    asset_id = resp_obj.get("assetId")
    if not asset_id:
        raise RuntimeError(f"Completed Open Cloud operation missing assetId: {op}")
    return str(asset_id)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Upload pending item .glb submeshes via Roblox Open Cloud Assets API")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("assets/items/roblox_assets.json"),
        help="Path to assets/items/roblox_assets.json",
    )
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--limit", type=int, default=0, help="Optional cap on number of parts to upload (0 = all)")
    args = parser.parse_args(argv)

    api_key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY", "")
    if not api_key:
        raise RuntimeError("Missing ROBLOX_OPEN_CLOUD_KEY environment variable")

    doc = json.loads(args.manifest.read_text(encoding="utf-8"))
    creator_user_id = str(doc.get("creator_user_id") or "")
    if not creator_user_id:
        raise RuntimeError("Manifest missing creator_user_id")

    uploaded = 0
    for item_id, item_meta in doc.get("items", {}).items():
        parts = item_meta.get("parts", {})
        for part_name, part_meta in parts.items():
            if part_meta.get("modelAssetId") or part_meta.get("meshId"):
                continue
            glb_rel = part_meta.get("glbFile")
            if not glb_rel:
                continue
            glb_path = args.repo_root / glb_rel
            if not glb_path.is_file():
                raise FileNotFoundError(f"Missing GLB file: {glb_path}")

            display_name = f"OpenKart_{item_id}_{part_name}"
            asset_id = upload_glb_model(
                glb_path=glb_path,
                display_name=display_name,
                creator_user_id=creator_user_id,
                api_key=api_key,
            )
            part_meta["modelAssetId"] = asset_id
            args.manifest.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
            uploaded += 1
            print(f"Uploaded {item_id}.{part_name} -> modelAssetId={asset_id}")
            if args.limit > 0 and uploaded >= args.limit:
                return 0

    if all(
        bool(p.get("modelAssetId") or p.get("meshId"))
        for it in doc.get("items", {}).values()
        for p in it.get("parts", {}).values()
    ):
        doc["status"] = "MODELS_UPLOADED_EXTRACTING_MESH_IDS"
        args.manifest.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

    print(f"Done: uploaded {uploaded} item model(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
