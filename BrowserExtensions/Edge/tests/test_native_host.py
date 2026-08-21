import base64
import io
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "native_host.py"
SPEC = importlib.util.spec_from_file_location("index_edge_native_host", HOST)
NATIVE_HOST = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(NATIVE_HOST)


def framed(value: dict) -> bytes:
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    return struct.pack("=I", len(payload)) + payload


def read_framed(data: bytes) -> dict:
    stream = io.BytesIO(data)
    (length,) = struct.unpack("=I", stream.read(4))
    return json.loads(stream.read(length).decode("utf-8"))


class NativeHostTests(unittest.TestCase):
    def test_opens_gallery_only_after_explicit_command(self):
        environment = os.environ.copy()
        environment["INDEX_BROWSER_SKIP_OPEN"] = "1"
        process = subprocess.run(
            [sys.executable, str(HOST)],
            input=framed({"type": "open-gallery"}),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )

        self.assertEqual(process.returncode, 0, process.stderr.decode())
        self.assertEqual(read_framed(process.stdout), {"ok": True})

    def test_stages_image_and_returns_transfer_id(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["INDEX_BROWSER_INBOX"] = directory
            environment["INDEX_BROWSER_SKIP_OPEN"] = "1"
            message = {
                "type": "import-image",
                "fileName": "MR-TADF.png",
                "mimeType": "image/png",
                "pageURL": "https://example.test/paper",
                "pageTitle": "Paper",
                "imageURL": "https://example.test/molecule.png",
                "dataBase64": base64.b64encode(b"demo-png").decode("ascii"),
            }
            process = subprocess.run(
                [sys.executable, str(HOST)],
                input=framed(message),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

            self.assertEqual(process.returncode, 0, process.stderr.decode())
            response = read_framed(process.stdout)
            self.assertTrue(response["ok"])
            item = Path(directory) / response["id"]
            self.assertEqual((item / "MR-TADF.png").read_bytes(), b"demo-png")
            metadata = json.loads((item / "metadata.json").read_text())
            self.assertEqual(metadata["pageURL"], "https://example.test/paper")

    def test_waits_for_index_import_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            transfer_id = str(uuid.uuid4())
            result_directory = Path(directory) / ".results"
            result_path = result_directory / f"{transfer_id}.json"

            def confirm_import():
                time.sleep(0.05)
                result_directory.mkdir(parents=True)
                result_path.write_text(
                    json.dumps({"ok": True, "fileName": "molecule.png"}),
                    encoding="utf-8",
                )

            previous = os.environ.get("INDEX_BROWSER_INBOX")
            os.environ["INDEX_BROWSER_INBOX"] = directory
            try:
                worker = threading.Thread(target=confirm_import)
                worker.start()
                response = NATIVE_HOST.wait_for_import(transfer_id)
                worker.join()
            finally:
                if previous is None:
                    os.environ.pop("INDEX_BROWSER_INBOX", None)
                else:
                    os.environ["INDEX_BROWSER_INBOX"] = previous

            self.assertEqual(response, {"ok": True, "fileName": "molecule.png"})
            self.assertFalse(result_path.exists())

    def test_rejects_unsupported_mime_type(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["INDEX_BROWSER_INBOX"] = directory
            environment["INDEX_BROWSER_SKIP_OPEN"] = "1"
            process = subprocess.run(
                [sys.executable, str(HOST)],
                input=framed({
                    "type": "import-image",
                    "fileName": "image.webp",
                    "mimeType": "image/webp",
                    "dataBase64": base64.b64encode(b"webp").decode("ascii"),
                }),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(read_framed(process.stdout)["ok"])
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
