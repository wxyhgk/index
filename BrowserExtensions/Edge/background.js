const MENU_ID = "save-image-to-index";
const NATIVE_HOST = "com.wxyhgk.index.edge";
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const SUPPORTED_MIME_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/heic",
  "image/heif",
  "image/tiff",
]);

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: "保存图片到 Index 图库",
      contexts: ["image"],
    });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU_ID || !info.srcUrl) return;
  void importImage(info, tab);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "open-index-gallery") return false;
  void sendNativeMessage({ type: "open-gallery" })
    .then((response) => {
      if (!response?.ok) throw new Error(response?.error || "Index 无法打开图库");
      sendResponse({ ok: true });
    })
    .catch((error) => {
      sendResponse({
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    });
  return true;
});

async function importImage(info, tab) {
  await setStatus("…", "正在发送图片到 Index");
  try {
    const response = await fetch(info.srcUrl, {
      credentials: "include",
      cache: "force-cache",
    });
    if (!response.ok) {
      throw new Error(`网页返回 HTTP ${response.status}`);
    }

    const blob = await response.blob();
    const mimeType = normalizedMimeType(blob.type, info.srcUrl);
    if (!SUPPORTED_MIME_TYPES.has(mimeType)) {
      throw new Error(`Demo 暂不支持 ${mimeType || "未知图片格式"}`);
    }
    if (blob.size === 0) throw new Error("图片内容为空");
    if (blob.size > MAX_IMAGE_BYTES) throw new Error("图片超过 25 MB");

    const dataBase64 = arrayBufferToBase64(await blob.arrayBuffer());
    const result = await sendNativeMessage({
      type: "import-image",
      fileName: suggestedFileName(info.srcUrl, mimeType),
      mimeType,
      pageURL: info.pageUrl || tab?.url || null,
      pageTitle: tab?.title || null,
      imageURL: info.srcUrl,
      dataBase64,
    });
    if (!result?.ok) throw new Error(result?.error || "本地连接器拒绝了图片");

    const fileName = result.fileName || "图片";
    await setStatus("✓", `已保存到 Index：${fileName}`);
    await showPageStatus(tab?.id, "success", "已保存到 Index", fileName);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[Index Edge Demo]", message);
    await setStatus("!", `保存失败：${message}`);
    await showPageStatus(tab?.id, "failure", "保存失败", message);
  }
  setTimeout(() => void setStatus("", "保存到 Index（Demo）"), 6000);
}

function sendNativeMessage(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST, message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
      } else {
        resolve(response);
      }
    });
  });
}

function normalizedMimeType(raw, sourceURL) {
  const value = (raw || "").split(";", 1)[0].trim().toLowerCase();
  if (value) return value;
  const extension = extensionFromURL(sourceURL);
  return {
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    heic: "image/heic",
    heif: "image/heif",
    tif: "image/tiff",
    tiff: "image/tiff",
  }[extension] || "";
}

function suggestedFileName(sourceURL, mimeType) {
  let name = "";
  try {
    name = decodeURIComponent(new URL(sourceURL).pathname.split("/").pop() || "");
  } catch (_) {
    // data: 等 URL 没有可用文件名，下面生成稳定的时间戳名称。
  }
  name = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-").trim();
  if (!name || name.length > 140) name = `web-image-${Date.now()}`;

  const supported = new Set(["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]);
  if (!supported.has(name.split(".").pop()?.toLowerCase())) {
    name += `.${extensionForMimeType(mimeType)}`;
  }
  return name;
}

function extensionForMimeType(mimeType) {
  return {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/tiff": "tiff",
  }[mimeType] || "png";
}

function extensionFromURL(sourceURL) {
  try {
    const name = new URL(sourceURL).pathname.split("/").pop() || "";
    return name.split(".").pop()?.toLowerCase() || "";
  } catch (_) {
    return "";
  }
}

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

async function setStatus(text, title) {
  const color = text === "!" ? "#D93025" : text === "✓" ? "#188038" : "#1A73E8";
  await Promise.all([
    chrome.action.setBadgeText({ text }),
    chrome.action.setBadgeBackgroundColor({ color }),
    chrome.action.setTitle({ title }),
  ]);
}

async function showPageStatus(tabId, kind, title, detail) {
  if (!Number.isInteger(tabId)) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: (statusKind, statusTitle, statusDetail) => {
        const existing = document.getElementById("index-browser-import-status");
        existing?.remove();

        const host = document.createElement("div");
        host.id = "index-browser-import-status";
        host.style.cssText = [
          "all:initial",
          "position:fixed",
          "top:20px",
          "left:50%",
          "transform:translateX(-50%)",
          "z-index:2147483647",
          "pointer-events:none",
          "max-width:calc(100vw - 32px)",
        ].join(";");
        const shadow = host.attachShadow({ mode: "closed" });
        const success = statusKind === "success";

        const style = document.createElement("style");
        style.textContent = `
          * { box-sizing: border-box; }
          .notice {
            pointer-events: auto;
            display: flex;
            align-items: center;
            gap: 10px;
            width: max-content;
            max-width: min(560px, calc(100vw - 32px));
            min-height: 52px;
            padding: 7px 8px 7px 10px;
            overflow: hidden;
            border: 1px solid rgba(0, 0, 0, .10);
            border-radius: 12px;
            background: rgba(250, 250, 251, .94);
            color: #202124;
            box-shadow: 0 12px 38px rgba(0, 0, 0, .22), 0 2px 8px rgba(0, 0, 0, .10);
            -webkit-backdrop-filter: blur(24px) saturate(1.35);
            backdrop-filter: blur(24px) saturate(1.35);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            opacity: 0;
            transform: translateY(-10px) scale(.98);
            transition: opacity .22s ease, transform .28s cubic-bezier(.2, .9, .2, 1.08);
          }
          .notice.visible { opacity: 1; transform: translateY(0) scale(1); }
          .notice.leaving { opacity: 0; transform: translateY(-8px) scale(.985); }
          .icon {
            display: grid;
            place-items: center;
            flex: 0 0 28px;
            width: 28px;
            height: 28px;
            border-radius: 50%;
            color: white;
            background: ${success ? "#1f8f55" : "#c7372f"};
            font: 700 16px/1 -apple-system, BlinkMacSystemFont, sans-serif;
          }
          .copy { min-width: 0; max-width: 330px; }
          .title { font-size: 13px; line-height: 18px; font-weight: 650; white-space: nowrap; }
          .detail {
            margin-top: 1px;
            overflow: hidden;
            color: #6b6f76;
            font-size: 12px;
            line-height: 16px;
            text-overflow: ellipsis;
            white-space: nowrap;
          }
          .actions {
            display: flex;
            align-items: center;
            gap: 2px;
            margin-left: 4px;
            padding-left: 5px;
            border-left: 1px solid rgba(0, 0, 0, .10);
          }
          button {
            appearance: none;
            border: 0;
            border-radius: 7px;
            background: transparent;
            color: #2767d8;
            font: 600 12px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            cursor: pointer;
          }
          button:hover { background: rgba(0, 0, 0, .06); }
          button:focus-visible { outline: 2px solid #4c8bf5; outline-offset: 1px; }
          button:disabled { cursor: default; opacity: .55; }
          .view { min-height: 30px; padding: 0 9px; }
          .close {
            display: grid;
            place-items: center;
            width: 30px;
            height: 30px;
            margin-left: 2px;
            color: #62666d;
            font-size: 18px;
            font-weight: 400;
          }
          @media (prefers-color-scheme: dark) {
            .notice {
              border-color: rgba(255, 255, 255, .13);
              background: rgba(39, 40, 43, .94);
              color: #f4f4f5;
              box-shadow: 0 14px 42px rgba(0, 0, 0, .48), 0 2px 8px rgba(0, 0, 0, .28);
            }
            .detail { color: #b4b6bb; }
            button { color: #82adff; }
            button:hover { background: rgba(255, 255, 255, .09); }
            .close { color: #c3c5ca; }
            .actions { border-left-color: rgba(255, 255, 255, .13); }
          }
          @media (prefers-reduced-motion: reduce) {
            .notice { transition-duration: .01ms; }
          }
        `;

        const panel = document.createElement("div");
        panel.className = "notice";
        panel.setAttribute("role", success ? "status" : "alert");
        panel.setAttribute("aria-live", success ? "polite" : "assertive");

        const icon = document.createElement("div");
        icon.className = "icon";
        icon.setAttribute("aria-hidden", "true");
        icon.textContent = success ? "✓" : "!";

        const copy = document.createElement("div");
        copy.className = "copy";
        const titleNode = document.createElement("div");
        titleNode.className = "title";
        titleNode.textContent = statusTitle;
        const detailNode = document.createElement("div");
        detailNode.className = "detail";
        detailNode.textContent = statusDetail;
        detailNode.title = statusDetail;
        copy.append(titleNode, detailNode);

        const actions = document.createElement("div");
        actions.className = "actions";
        if (success) {
          const view = document.createElement("button");
          view.className = "view";
          view.type = "button";
          view.textContent = "查看";
          view.addEventListener("click", () => {
            view.disabled = true;
            view.textContent = "打开中…";
            chrome.runtime.sendMessage({ type: "open-index-gallery" }, (response) => {
              const error = chrome.runtime.lastError;
              if (error || !response?.ok) {
                view.disabled = false;
                view.textContent = "重试";
                detailNode.textContent = response?.error || error?.message || "无法打开 Index";
              } else {
                dismiss();
              }
            });
          });
          actions.append(view);
        }

        const close = document.createElement("button");
        close.className = "close";
        close.type = "button";
        close.setAttribute("aria-label", "关闭通知");
        close.textContent = "×";
        close.addEventListener("click", () => dismiss());
        actions.append(close);
        panel.append(icon, copy, actions);
        shadow.append(style, panel);
        document.documentElement.append(host);

        let dismissalTimer;
        let dismissed = false;
        function dismiss() {
          if (dismissed) return;
          dismissed = true;
          clearTimeout(dismissalTimer);
          panel.classList.add("leaving");
          setTimeout(() => host.remove(), 300);
        }
        function scheduleDismiss(delay) {
          clearTimeout(dismissalTimer);
          dismissalTimer = setTimeout(dismiss, delay);
        }

        panel.addEventListener("mouseenter", () => clearTimeout(dismissalTimer));
        panel.addEventListener("mouseleave", () => scheduleDismiss(2500));
        requestAnimationFrame(() => panel.classList.add("visible"));
        scheduleDismiss(success ? 6000 : 9000);
      },
      args: [kind, title, detail],
    });
  } catch (_) {
    // edge://、扩展页等禁止注入的页面仍可通过工具栏徽标查看结果。
  }
}
