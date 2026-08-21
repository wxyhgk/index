import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class MacScreenCapturer: ScreenCapturing {

    static let shared = MacScreenCapturer()

    private static let topologyRetryDelayNanoseconds: UInt64 = 150_000_000
    /// 拓扑变化时最多重试一次（共 2 次尝试）。
    private let maxAttempts = 2
    private var topologyGeneration: UInt64 = 0
    private var cachedDisplayContent: (generation: UInt64, content: SCShareableContent)?
    private var screenParametersObserver: NSObjectProtocol?

    private init() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.displayTopologyDidChange()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    var isPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// 在同一份显示器拓扑上冻结全部活动显示器；不得返回部分成功结果。
    /// 拓扑在采集中变化时最多重新取一次。
    ///
    /// 主路径只走 ScreenCaptureKit：macOS 15 实测 `CGDisplayCreateImage` 与
    /// `/usr/sbin/screencapture` 都会被转发到同一个 replayd 代理（详见
    /// `docs/errors/2026-08-11-sidecar-capture-path-failure.md`），换 API 并不能
    /// 绕过系统故障，只会丢掉冻结架构的所见即所得。所有 SCK 请求都有 5 秒
    /// 单次完成门：故障会话里有界报错，健康会话里单屏约 0.1 秒。
    func captureDisplays() async throws -> [DisplaySnapshot] {
        guard isPermissionGranted else { throw CaptureError.noPermission }
        let session = try MacScreenCaptureBroker.shared.beginSession()
        var completedSuccessfully = false
        defer {
            MacScreenCaptureBroker.shared.finishSession(session)
            // replayd 重启或连接中断后，旧 SCShareableContent 对象不能继续复用。
            // 失败后的下一次用户请求重新枚举；这里不会自动重试当前请求。
            if !completedSuccessfully {
                cachedDisplayContent = nil
            }
        }

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()

            let generation = topologyGeneration
            let displays = currentDisplays()
            guard !displays.isEmpty else { throw CaptureError.noDisplays }

            // 共享内容只枚举一次：之后每块屏的过滤器都从这里取。
            // 这一步超时（5 秒门）即整个失败，不会逐屏放大等待。
            let content = try await displayContent(
                for: generation,
                in: session
            )
            let startedAt = Date()
            var snapshots: [DisplaySnapshot] = []
            var failedDisplays: [DisplayInfo] = []

            for display in displays {
                try Task.checkCancellation()
                guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                    NSLog("[Index] 共享内容中找不到显示器 displayID=%u name=%@", display.id, display.name)
                    failedDisplays.append(display)
                    continue
                }
                // 不排除自身进程：截图是「先冻结、后覆盖」，overlay 不在画面里，
                // 排除自身会把图库/设置等窗口从画面中挖掉。
                let filter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: [],
                    exceptingWindows: []
                )
                let config = SCStreamConfiguration()
                config.width = Int((display.frame.width * display.scale).rounded())
                config.height = Int((display.frame.height * display.scale).rounded())
                config.scalesToFit = false
                config.showsCursor = false
                config.captureResolution = .best
                config.ignoreShadowsDisplay = true
                config.colorSpaceName = CGColorSpace.sRGB

                do {
                    let image = try await MacScreenCaptureBroker.shared.captureImage(
                        filter: filter,
                        configuration: config,
                        in: session,
                        operationName: "display:\(display.id)"
                    )
                    guard abs(image.width - config.width) <= 1,
                          abs(image.height - config.height) <= 1 else {
                        NSLog(
                            "[Index] 显示器像素校验失败 displayID=%u name=%@ 请求=%dx%d 实得=%dx%d",
                            display.id, display.name, config.width, config.height, image.width, image.height
                        )
                        failedDisplays.append(display)
                        continue
                    }
                    snapshots.append(DisplaySnapshot(
                        display: display,
                        image: image,
                        imageScale: CGFloat(image.width) / display.frame.width
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CaptureError where error.stopsCaptureBatch {
                    throw error
                } catch {
                    NSLog(
                        "[Index] 显示器捕获失败 displayID=%u name=%@ error=%@",
                        display.id, display.name, String(describing: error)
                    )
                    failedDisplays.append(display)
                }
            }

            let topologyStillMatches = generation == topologyGeneration
                && DisplayTopology.matches(displays, currentDisplays())
            guard topologyStillMatches else {
                NSLog("[Index] 捕获期间显示器拓扑变化 generation=%llu attempt=%d", generation, attempt + 1)
                if attempt == 0 {
                    try await waitForTopologyToSettle()
                    continue
                }
                throw CaptureError.displayTopologyChanged
            }

            guard failedDisplays.isEmpty, snapshots.count == displays.count else {
                let names = failedDisplays.isEmpty ? displays.map(\.name) : failedDisplays.map(\.name)
                NSLog("[Index] 显示器捕获失败 names=%@", names.joined(separator: ", "))
                throw CaptureError.displayCaptureFailed(names)
            }

            let imageSummary = snapshots.map { snapshot in
                "\(snapshot.display.name)=\(snapshot.image.width)x\(snapshot.image.height)@\(String(format: "%.2f", snapshot.imageScale))x"
            }.joined(separator: ", ")
            NSLog(
                "[Index] 多屏冻结完成 generation=%llu elapsed=%.3fs count=%d images=%@",
                generation,
                Date().timeIntervalSince(startedAt),
                snapshots.count,
                imageSummary
            )
            completedSuccessfully = true
            return snapshots
        }

        throw CaptureError.displayTopologyChanged
    }

    private func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap(DisplayInfo.init(screen:))
    }

    private func waitForTopologyToSettle() async throws {
        try await Task.sleep(nanoseconds: Self.topologyRetryDelayNanoseconds)
    }

    private func displayTopologyDidChange() {
        topologyGeneration &+= 1
        cachedDisplayContent = nil
        NSLog("[Index] 显示器拓扑变化 generation=%llu", topologyGeneration)
    }

    private func displayContent(
        for generation: UInt64,
        in session: MacScreenCaptureBroker.Session
    ) async throws -> SCShareableContent {
        if let cachedDisplayContent,
           cachedDisplayContent.generation == generation {
            return cachedDisplayContent.content
        }

        let content = try await MacScreenCaptureBroker.shared.shareableContent(in: session)
        guard generation == topologyGeneration else {
            return content
        }
        cachedDisplayContent = (generation, content)
        return content
    }

    func captureWindow(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage {
        guard isPermissionGranted else { throw CaptureError.noPermission }
        let session = try MacScreenCaptureBroker.shared.beginSession()
        defer { MacScreenCaptureBroker.shared.finishSession(session) }
        // 窗口列表不能复用显示器冻结缓存：用户可能在选区期间新开/关闭窗口。
        let content = try await MacScreenCaptureBroker.shared.shareableContent(in: session)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !includeShadow
        config.backgroundColor = .clear
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await MacScreenCaptureBroker.shared.captureImage(
            filter: filter,
            configuration: config,
            in: session,
            operationName: "window:\(windowID)"
        )
        NSLog(
            "[Index] 整窗捕获: 请求 %dx%d 实得 %dx%d 阴影=%@",
            config.width,
            config.height,
            image.width,
            image.height,
            includeShadow ? "带" : "无"
        )
        return image
    }
}

enum CaptureError: Error, LocalizedError {
    case noPermission
    case noDisplays
    case displayTopologyChanged
    case screenCaptureTimedOut(String)
    case screenCaptureUnavailable
    case screenCaptureRequestInFlight(String?)
    case screenCaptureRequestQuarantined(String)
    case displayCaptureFailed([String])
    case windowNotFound
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "缺少「屏幕录制」权限"
        case .noDisplays:
            return "没有找到可捕获的显示器"
        case .displayTopologyChanged:
            return "显示器连接状态在截图过程中发生了变化，请稍候再试。"
        case .screenCaptureTimedOut:
            return "Index 等待 ScreenCaptureKit 响应超过 5 秒。Index 已停止等待，但系统请求可能仍在结束中；在它真正结束前不会发送新的捕获请求。"
        case .screenCaptureUnavailable:
            return "Index 未从 ScreenCaptureKit 收到截图结果。"
        case .screenCaptureRequestInFlight:
            return "Index 正在处理上一条屏幕捕获请求，请稍候再试。"
        case .screenCaptureRequestQuarantined:
            return "上一条 ScreenCaptureKit 请求超时后仍未结束。Index 已暂停发送新的捕获请求，避免继续影响系统截图服务；请稍候再试。"
        case .displayCaptureFailed(let names):
            let displayDescription: String
            if names.count == 1 {
                displayDescription = "显示器「\(names[0])」"
            } else {
                displayDescription = "显示器：\(names.joined(separator: "、"))"
            }
            return "Index 的显示器捕获失败（\(displayDescription)）。"
        case .windowNotFound:
            return "找不到目标窗口"
        case .cropFailed:
            return "选区裁剪失败"
        }
    }

    var stopsCaptureBatch: Bool {
        switch self {
        case .screenCaptureTimedOut,
             .screenCaptureUnavailable,
             .screenCaptureRequestInFlight,
             .screenCaptureRequestQuarantined:
            return true
        default:
            return false
        }
    }
}

@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool { MacScreenCapturer.shared.isPermissionGranted }
    @discardableResult
    static func request() -> Bool { MacScreenCapturer.shared.requestPermission() }
}
