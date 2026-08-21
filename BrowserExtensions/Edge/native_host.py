#!/usr/bin/env python3
"""Microsoft Edge Native Messaging host for the Index demo.

stdout is reserved exclusively for the length-prefixed native-messaging response.
Diagnostic text must go to stderr, otherwise Edge treats it as protocol corruption.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid


MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_MESSAGE_BYTES = 36 * 1024 * 1024
SUPPORTED_MIME_TYPES = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/tiff": "tiff",
}
IMPORT_CONFIRMATION_TIMEOUT = 15.0


def read_exact(stream, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise EOFError("native message ended early")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_message(stream) -> dict:
    header = stream.read(4)
    if len(header) != 4:
        raise ValueError("missing native message header")
    (length,) = struct.unpack("=I", header)
    if length <= 0 or length > MAX_MESSAGE_BYTES:
        raise ValueError("native message is too large")
    payload = read_exact(stream, length)
    value = json.loads(payload.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("native message must be an object")
    return value


def write_message(stream, value: dict) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    stream.write(struct.pack("=I", len(payload)))
    stream.write(payload)
    stream.flush()


def inbox_root() -> Path:
    override = os.environ.get("INDEX_BROWSER_INBOX")
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / "Index" / "browser-inbox"


def safe_file_name(raw: object, mime_type: str) -> str:
    candidate = Path(str(raw or "")).name.strip()
    candidate = "".join("-" if ord(ch) < 32 or ch in '\\/:*?"<>|' else ch for ch in candidate)
    if not candidate or len(candidate) > 160:
        candidate = "web-image"

    allowed_extensions = {"png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"}
    suffix = Path(candidate).suffix.lower().lstrip(".")
    if suffix not in allowed_extensions:
        candidate = f"{candidate}.{SUPPORTED_MIME_TYPES[mime_type]}"
    return candidate


def optional_string(value: object, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped[:maximum] if stripped else None


def stage_import(message: dict) -> tuple[str, str]:
    if message.get("type") != "import-image":
        raise ValueError("unsupported command")

    mime_type = optional_string(message.get("mimeType"), 80) or ""
    if mime_type not in SUPPORTED_MIME_TYPES:
        raise ValueError(f"unsupported image type: {mime_type or 'unknown'}")

    encoded = message.get("dataBase64")
    if not isinstance(encoded, str) or not encoded:
        raise ValueError("image payload is missing")
    try:
        image_data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("image payload is not valid base64") from error
    if not image_data:
        raise ValueError("image payload is empty")
    if len(image_data) > MAX_IMAGE_BYTES:
        raise ValueError("image exceeds 25 MB")

    transfer_id = str(uuid.uuid4())
    file_name = safe_file_name(message.get("fileName"), mime_type)
    root = inbox_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)

    temporary = Path(tempfile.mkdtemp(prefix=f".{transfer_id}-", dir=root))
    final = root / transfer_id
    try:
        image_path = temporary / file_name
        image_path.write_bytes(image_data)
        metadata = {
            "schemaVersion": 1,
            "imageFile": file_name,
            "fileName": file_name,
            "mimeType": mime_type,
            "pageURL": optional_string(message.get("pageURL"), 8192),
            "pageTitle": optional_string(message.get("pageTitle"), 1024),
            "imageURL": optional_string(message.get("imageURL"), 8192),
        }
        (temporary / "metadata.json").write_text(
            json.dumps(metadata, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        os.chmod(image_path, 0o600)
        os.chmod(temporary / "metadata.json", 0o600)
        temporary.rename(final)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    return transfer_id, file_name


def open_index(transfer_id: str) -> None:
    if os.environ.get("INDEX_BROWSER_SKIP_OPEN") == "1":
        return
    result = subprocess.run(
        ["/usr/bin/open", "-g", f"index://import/browser?id={transfer_id}"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        shutil.rmtree(inbox_root() / transfer_id, ignore_errors=True)
        raise RuntimeError("unable to open Index")


def open_gallery() -> None:
    if os.environ.get("INDEX_BROWSER_SKIP_OPEN") == "1":
        return
    result = subprocess.run(
        ["/usr/bin/open", "index://gallery"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("unable to open Index gallery")


def wait_for_import(transfer_id: str) -> dict:
    if os.environ.get("INDEX_BROWSER_SKIP_OPEN") == "1":
        return {"ok": True, "staged": True}

    result_path = inbox_root() / ".results" / f"{transfer_id.lower()}.json"
    deadline = time.monotonic() + IMPORT_CONFIRMATION_TIMEOUT
    while time.monotonic() < deadline:
        try:
            result = json.loads(result_path.read_text(encoding="utf-8"))
            if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
                raise ValueError("Index returned an invalid import result")
            result_path.unlink(missing_ok=True)
            return result
        except FileNotFoundError:
            time.sleep(0.05)
    raise TimeoutError("Index did not confirm the import within 15 seconds")


def main() -> int:
    try:
        message = read_message(sys.stdin.buffer)
        if message.get("type") == "open-gallery":
            open_gallery()
            write_message(sys.stdout.buffer, {"ok": True})
            return 0

        transfer_id, file_name = stage_import(message)
        open_index(transfer_id)
        result = wait_for_import(transfer_id)
        result.setdefault("id", transfer_id)
        result.setdefault("fileName", file_name)
        write_message(sys.stdout.buffer, result)
        return 0 if result.get("ok") else 1
    except Exception as error:
        print(f"[Index Edge Host] {error}", file=sys.stderr)
        write_message(sys.stdout.buffer, {"ok": False, "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
