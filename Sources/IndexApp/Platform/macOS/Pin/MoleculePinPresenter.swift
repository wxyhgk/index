import AppKit
import WebKit

/// macOS 的交互式分子钉图实现。
///
/// 这是一种与图片钉图不同的内容类型：相机状态由 3Dmol.js 保留，鼠标拖动和
/// 滚轮直接控制分子；窗口边缘只负责改变视口尺寸，不会与图片钉图的滚轮缩放冲突。
@MainActor
final class MacMoleculePinPresenter: MoleculePinning {
    static let shared = MacMoleculePinPresenter()

    private var freezeHandler: MoleculeFreezeHandler?

    private init() {}

    func configureFreezeHandler(_ handler: @escaping MoleculeFreezeHandler) {
        freezeHandler = handler
    }

    func pinMolecule(xyz: String, atomCount: Int) {
        let source = MoleculeSourceAttachment(canonicalXYZ: xyz, atomCount: atomCount)
        let controller = MoleculePinWindowController(
            source: source,
            freezeHandler: freezeHandler
        )
        WindowRegistry.shared.present(controller, dockIcon: false, retain: true)
    }
}

@MainActor
private final class MoleculePinWindowController: NSWindowController, PinPassthroughControlling {
    private static let freezeMessageName = "moleculeFreeze"
    private static let initialSize = CGSize(width: 520, height: 440)
    private let normalTitle: String
    private let source: MoleculeSourceAttachment
    private let freezeHandler: MoleculeFreezeHandler?
    private var opacity: CGFloat = 1
    private var isPassthrough = false
    private var scriptMessageProxy: MoleculeScriptMessageProxy?

    init(source: MoleculeSourceAttachment, freezeHandler: MoleculeFreezeHandler?) {
        self.source = source
        self.freezeHandler = freezeHandler
        normalTitle = "3D 分子 · \(source.atomCount) 个原子"
        let panel = MoleculePinPanel(
            contentRect: CGRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.title = normalTitle
        panel.titleVisibility = .visible
        panel.level = .floating
        panel.minSize = CGSize(width: 300, height: 260)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        PanelPlacement.detachFromAppStage(panel)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let proxy = MoleculeScriptMessageProxy()
        proxy.owner = self
        configuration.userContentController.add(
            proxy,
            name: Self.freezeMessageName
        )
        scriptMessageProxy = proxy

        let webView = MoleculeWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.onTogglePassthrough = { [weak self] in
            guard let self else { return }
            self.setPinPassthrough(!self.isPassthrough)
        }
        webView.onOpacityStep = { [weak self] step in
            self?.adjustOpacity(by: step)
        }
        webView.loadHTMLString(
            Self.page(xyz: source.canonicalXYZ, atomCount: source.atomCount),
            baseURL: nil
        )
        panel.contentView = webView

        if let screen = PanelPlacement.targetScreen(anchor: nil) {
            panel.setFrameOrigin(PanelPlacement.origin(
                panelSize: Self.initialSize,
                in: screen.visibleFrame
            ))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        PinPassthroughRegistry.shared.unregister(self)
        (window?.contentView as? WKWebView)?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.freezeMessageName)
        super.close()
    }

    fileprivate func receiveFreezeMessage(_ body: Any) {
        do {
            guard let freezeHandler else { throw FreezeError.handlerUnavailable }
            guard let dataURI = body as? String,
                  let comma = dataURI.firstIndex(of: ","),
                  dataURI[..<comma].contains("image/png"),
                  let data = Data(
                    base64Encoded: String(dataURI[dataURI.index(after: comma)...]),
                    options: .ignoreUnknownCharacters
                  ),
                  let image = ImageCodec.load(from: data)
            else { throw FreezeError.invalidPNG }
            guard let panel = window, let contentView = panel.contentView else {
                throw FreezeError.windowUnavailable
            }

            let windowContentRect = contentView.convert(contentView.bounds, to: nil)
            let globalRegion = panel.convertToScreen(windowContentRect)
            guard globalRegion.width > 0, globalRegion.height > 0 else {
                throw FreezeError.windowUnavailable
            }
            let scaleX = Double(image.width) / globalRegion.width
            let scaleY = Double(image.height) / globalRegion.height
            let snapshot = MoleculeFreezeSnapshot(
                image: image,
                globalRegion: globalRegion,
                scale: max(1, min(scaleX, scaleY))
            )
            try freezeHandler(snapshot, source)
            close()
        } catch {
            (window?.contentView as? WKWebView)?.evaluateJavaScript(
                "window.__indexFreezeFinished(false)"
            )
            AppAlert.error("无法定格 3D 分子", error: error, host: window)
        }
    }

    func setPinPassthrough(_ enabled: Bool) {
        guard isPassthrough != enabled, let panel = window else { return }
        isPassthrough = enabled
        if enabled {
            PinPassthroughRegistry.shared.register(self)
        } else {
            PinPassthroughRegistry.shared.unregister(self)
        }
        panel.ignoresMouseEvents = enabled
        panel.alphaValue = enabled ? min(opacity, 0.55) : opacity
        panel.title = enabled ? "\(normalTitle) · 穿透中（从菜单栏解除）" : normalTitle
    }

    private func adjustOpacity(by step: CGFloat) {
        opacity = min(1, max(0.2, opacity + step))
        window?.alphaValue = isPassthrough ? min(opacity, 0.55) : opacity
    }

    private static func page(xyz: String, atomCount: Int) -> String {
        let payload = Data(xyz.utf8).base64EncodedString()
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; worker-src blob:">
          <style>
            :root { color-scheme: dark; }
            html, body, #viewer { width: 100%; height: 100%; margin: 0; overflow: hidden; }
            body { background: radial-gradient(circle at 50% 42%, #293348, #111722 68%, #0b0f16); font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            #viewer { position: absolute; inset: 0; }
            #freeze { position: absolute; top: 12px; right: 12px; z-index: 3; padding: 7px 11px; border: 1px solid rgba(255,255,255,.18); border-radius: 9px; background: rgba(12,17,25,.78); color: rgba(255,255,255,.92); font: 600 12px -apple-system, BlinkMacSystemFont, sans-serif; cursor: pointer; backdrop-filter: blur(14px); }
            #freeze:hover { background: rgba(42,55,78,.9); }
            #freeze:disabled { opacity: .55; cursor: wait; }
            #status { position: absolute; left: 14px; right: 14px; bottom: 12px; z-index: 2; padding: 7px 10px; border: 1px solid rgba(255,255,255,.12); border-radius: 9px; background: rgba(12,17,25,.72); color: rgba(255,255,255,.72); font-size: 12px; text-align: center; pointer-events: none; backdrop-filter: blur(14px); transition: opacity .35s ease; }
            #status.ready { opacity: .72; }
            #status.error { bottom: 50%; transform: translateY(50%); color: #ffd5d5; border-color: rgba(255,100,100,.35); background: rgba(80,20,25,.82); }
          </style>
          <script src="https://cdn.jsdelivr.net/npm/3dmol@2.5.5/build/3Dmol-min.js"
                  integrity="sha384-OsczYbldvrHgslr9fFp/i4GiLSeuw9l+QIlv99ITw8soOwXcoGeflFMLg+CU/X1d"
                  crossorigin="anonymous"></script>
        </head>
        <body>
          <div id="viewer" aria-label="可交互的三维分子"></div>
          <button id="freeze" type="button" disabled>定格为图片</button>
          <div id="status">正在加载 \(atomCount) 个原子…</div>
          <script>
            const status = document.getElementById('status');
            const freeze = document.getElementById('freeze');
            window.__indexFreezeFinished = function(success) {
              if (!success) {
                freeze.disabled = false;
                freeze.textContent = '定格为图片';
              }
            };
            freeze.addEventListener('click', () => {
              if (!window.__indexViewer) return;
              freeze.disabled = true;
              freeze.textContent = '正在定格…';
              try {
                Promise.resolve(window.__indexViewer.pngURI()).then(uri => {
                  window.webkit.messageHandlers.\(freezeMessageName).postMessage(uri);
                }).catch(error => {
                  window.__indexFreezeFinished(false);
                  showError('定格失败：' + (error?.message || String(error)));
                });
              } catch (error) {
                window.__indexFreezeFinished(false);
                showError('定格失败：' + (error?.message || String(error)));
              }
            });
            function showError(message) {
              status.textContent = message;
              status.className = 'error';
            }
            function boot() {
              try {
                if (!window.$3Dmol) {
                  showError('无法加载 3Dmol.js，请检查网络连接后重试。');
                  return;
                }
                const bytes = Uint8Array.from(atob('\(payload)'), c => c.charCodeAt(0));
                const xyz = new TextDecoder().decode(bytes);
                const viewer = $3Dmol.createViewer(document.getElementById('viewer'), {
                  backgroundColor: '#111722',
                  // pngURI 只导出 WebGL 画布，不包含网页 CSS 背景；这里必须给
                  // 画布本身一个不透明底色，定格后的普通图片才与交互视图一致。
                  backgroundAlpha: 1,
                  antialias: true
                });
                window.__indexViewer = viewer;
                const model = viewer.addModel(xyz, 'xyz');
                if (!model || model.selectedAtoms({}).length !== \(atomCount)) {
                  showError('XYZ 已读取，但渲染器返回的原子数不一致。');
                  return;
                }
                viewer.setStyle({}, {
                  stick: { radius: 0.16, colorscheme: 'Jmol' },
                  sphere: { scale: 0.28, colorscheme: 'Jmol' }
                });
                viewer.zoomTo();
                viewer.render();
                freeze.disabled = false;
                window.addEventListener('resize', () => {
                  viewer.resize();
                  viewer.render();
                });
                status.textContent = '拖动旋转 · 滚轮缩放 · ⌘滚轮透明度 · ⌘T 穿透 · Esc 关闭';
                status.className = 'ready';
                setTimeout(() => { status.style.opacity = '0'; }, 4200);
              } catch (error) {
                showError('分子渲染失败：' + (error?.message || String(error)));
              }
            }
            if (window.$3Dmol) boot();
            else window.addEventListener('load', boot, { once: true });
          </script>
        </body>
        </html>
        """
    }
}

@MainActor
private final class MoleculeScriptMessageProxy: NSObject {
    weak var owner: MoleculePinWindowController?
}

extension MoleculeScriptMessageProxy: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        owner?.receiveFreezeMessage(body)
    }
}

private enum FreezeError: LocalizedError {
    case handlerUnavailable
    case invalidPNG
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .handlerUnavailable:
            return "定格服务尚未准备好，请关闭窗口后重试。"
        case .invalidPNG:
            return "3D 渲染器没有返回有效的 PNG 图像。"
        case .windowUnavailable:
            return "3D 分子窗口已经关闭。"
        }
    }
}

private final class MoleculeWebView: WKWebView {
    var onTogglePassthrough: (() -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            window?.close()
            return
        }
        if event.keyCode == 17, event.modifierFlags.contains(.command) { // Command-T
            onTogglePassthrough?()
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onOpacityStep?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
            return
        }
        super.scrollWheel(with: event)
    }
}

private final class MoleculePinPanel: PinnedContentPanel {
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
