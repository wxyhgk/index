#!/bin/zsh
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION_DIR="$REPOSITORY_ROOT/BrowserExtensions/Edge"
HOST_SCRIPT="$EXTENSION_DIR/native_host.py"
HOST_NAME="com.wxyhgk.index.edge"
EXPECTED_EXTENSION_ID="anhidejnknnfchdjgnkbkgnifophmgnm"
MANIFEST_DIR="$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
HOST_MANIFEST="$MANIFEST_DIR/$HOST_NAME.json"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$HOST_MANIFEST" ]]; then
        rm -- "$HOST_MANIFEST"
        echo "已移除 Edge Native Messaging 配置: $HOST_MANIFEST"
    else
        echo "未安装 Edge Native Messaging 配置。"
    fi
    exit 0
fi

OPEN_EXTENSIONS_PAGE=1
if [[ "${1:-}" == "--no-open" ]]; then
    OPEN_EXTENSIONS_PAGE=0
fi

if [[ ! -d "/Applications/Microsoft Edge.app" ]]; then
    echo "没有在 /Applications 找到 Microsoft Edge.app" >&2
    exit 1
fi
if [[ ! -f "$EXTENSION_DIR/manifest.json" || ! -f "$HOST_SCRIPT" ]]; then
    echo "Edge Demo 文件不完整: $EXTENSION_DIR" >&2
    exit 1
fi

ACTUAL_EXTENSION_ID="$(python3 - "$EXTENSION_DIR/manifest.json" <<'PY'
import base64
import hashlib
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
digest = hashlib.sha256(base64.b64decode(manifest["key"])).digest()[:16]
print("".join(chr(ord("a") + (byte >> 4)) + chr(ord("a") + (byte & 15)) for byte in digest))
PY
)"
if [[ "$ACTUAL_EXTENSION_ID" != "$EXPECTED_EXTENSION_ID" ]]; then
    echo "扩展固定 ID 校验失败: $ACTUAL_EXTENSION_ID" >&2
    exit 1
fi

chmod 755 "$HOST_SCRIPT"
mkdir -p "$MANIFEST_DIR"
python3 - "$HOST_MANIFEST" "$HOST_SCRIPT" "$EXPECTED_EXTENSION_ID" <<'PY'
import json
import os
import sys

target, host_script, extension_id = sys.argv[1:]
payload = {
    "name": "com.wxyhgk.index.edge",
    "description": "Index Microsoft Edge image import demo",
    "path": os.path.abspath(host_script),
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
with open(target, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
os.chmod(target, 0o600)
PY

echo "Edge Native Messaging 配置已安装。"
echo "扩展目录: $EXTENSION_DIR"
echo "固定扩展 ID: $EXPECTED_EXTENSION_ID"
echo
echo "下一步：在 Edge 打开 edge://extensions，开启开发人员模式，选择“加载解压缩的扩展”，然后选择上面的扩展目录。"
if [[ "$OPEN_EXTENSIONS_PAGE" == "1" ]]; then
    open -a "Microsoft Edge" "edge://extensions/" || true
fi
