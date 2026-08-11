import AppKit
import CoreGraphics
import ScreenCaptureKit

private let macScreenScreenshotTimeout: TimeInterval = 5

private final class CaptureContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
final class MacScreenCapturer: ScreenCapturing {

    static let shared = MacScreenCapturer()

    private static let topologyRetryDelayNanoseconds: UInt64 = 150_000_000
    private static let shareableContentTimeout: TimeInterval = 5

    private var topologyGeneration: UInt64 = 0
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

    /// 在同一份 NSScreen/CoreGraphics 拓扑上冻结全部活动显示器。
    /// 任意一块屏失败都不会返回半套结果；拓扑在采集中变化时最多重新取一次。
    func captureDisplays() async throws -> [DisplaySnapshot] {
        return try await captureDisplaysUsingCoreGraphics()
    }

    /// 普通全屏冻结直接读取各显示器的 CoreGraphics 帧缓冲。
    /// 这条路径返回 Retina 原生像素，而且不建立 ScreenCaptureKit/replayd 会话；
    /// ScreenCaptureKit 只保留给需要桌面无关窗口后备存储的整窗重拍。
    private func captureDisplaysUsingCoreGraphics() async throws -> [DisplaySnapshot] {
        guard isPermissionGranted else { throw CaptureError.noPermission }

        for attempt in 0..<2 {
            try Task.checkCancellation()

            let generation = topologyGeneration
            let displays = currentDisplays()
            guard !displays.isEmpty else { throw CaptureError.noDisplays }

            let startedAt = Date()
            var snapshots: [DisplaySnapshot] = []
            var failedDisplays: [DisplayInfo] = []

            for display in displays {
                try Task.checkCancellation()
                guard let image = CGDisplayCreateImage(display.id) else {
                    failedDisplays.append(display)
                    continue
                }

                let imageScaleX = CGFloat(image.width) / display.frame.width
                let imageScaleY = CGFloat(image.height) / display.frame.height
                guard imageScaleX.isFinite,
                      imageScaleY.isFinite,
                      abs(imageScaleX - imageScaleY) < 0.01
                else {
                    NSLog(
                        "[MacShot] CoreGraphics 显示器像素比例异常 displayID=%u name=%@ points=%.0fx%.0f pixels=%dx%d",
                        display.id,
                        display.name,
                        display.frame.width,
                        display.frame.height,
                        image.width,
                        image.height
                    )
                    failedDisplays.append(display)
                    continue
                }

                snapshots.append(DisplaySnapshot(
                    display: display,
                    image: image,
                    imageScale: imageScaleX
                ))
            }

            let topologyStillMatches = generation == topologyGeneration
                && DisplayTopology.matches(displays, currentDisplays())
            guard topologyStillMatches else {
                NSLog("[MacShot] CoreGraphics 捕获期间显示器拓扑变化 generation=%llu attempt=%d", generation, attempt + 1)
                if attempt == 0 {
                    try await waitForTopologyToSettle()
                    continue
                }
                throw CaptureError.displayTopologyChanged
            }

            guard failedDisplays.isEmpty, snapshots.count == displays.count else {
                let names = failedDisplays.isEmpty ? displays.map(\.name) : failedDisplays.map(\.name)
                NSLog("[MacShot] CoreGraphics 显示器捕获失败 names=%@", names.joined(separator: ", "))
                throw CaptureError.displayCaptureFailed(names)
            }

            let imageSummary = snapshots.map { snapshot in
                "\(snapshot.display.name)=\(snapshot.image.width)x\(snapshot.image.height)@\(String(format: "%.2f", snapshot.scale))x"
            }.joined(separator: ", ")
            NSLog(
                "[MacShot] CoreGraphics 多屏冻结完成 generation=%llu elapsed=%.3fs count=%d images=%@",
                generation,
                Date().timeIntervalSince(startedAt),
                snapshots.count,
                imageSummary
            )
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
        NSLog("[MacShot] 显示器拓扑变化 generation=%llu", topologyGeneration)
    }

    private func requestShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CaptureContinuationGate(continuation)
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let content {
                    gate.resume(with: .success(content))
                } else if let error {
                    gate.resume(with: .failure(error))
                } else {
                    gate.resume(with: .failure(CaptureError.screenCaptureUnavailable))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + Self.shareableContentTimeout
            ) {
                gate.resume(with: .failure(CaptureError.screenCaptureTimedOut))
            }
        }
    }

    private nonisolated static func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let gate = CaptureContinuationGate(continuation)
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let image {
                    gate.resume(with: .success(image))
                } else if let error {
                    gate.resume(with: .failure(error))
                } else {
                    gate.resume(with: .failure(CaptureError.screenCaptureUnavailable))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + macScreenScreenshotTimeout
            ) {
                gate.resume(with: .failure(CaptureError.screenCaptureTimedOut))
            }
        }
    }

    func captureWindow(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage {
        guard isPermissionGranted else { throw CaptureError.noPermission }
        // 窗口列表不能复用显示器冻结缓存：用户可能在选区期间新开/关闭窗口。
        let content = try await requestShareableContent()
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
        let image = try await Self.captureImage(filter: filter, configuration: config)
        NSLog(
            "[MacShot] 整窗捕获: 请求 %dx%d 实得 %dx%d 阴影=%@",
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
    case screenCaptureTimedOut
    case screenCaptureUnavailable
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
            return "MacShot 等待 ScreenCaptureKit 响应超时，已停止本次请求以避免继续卡住。系统自带截图可能仍可用。"
        case .screenCaptureUnavailable:
            return "MacShot 未从 ScreenCaptureKit 收到截图结果；系统自带截图可能仍可用。"
        case .displayCaptureFailed(let names):
            let displayDescription: String
            if names.count == 1 {
                displayDescription = "显示器「\(names[0])」"
            } else {
                displayDescription = "显示器：\(names.joined(separator: "、"))"
            }
            return "MacShot 的显示器捕获失败（\(displayDescription)）；macOS 系统截图可能仍可用。"
        case .windowNotFound:
            return "找不到目标窗口"
        case .cropFailed:
            return "选区裁剪失败"
        }
    }
}

@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool { MacScreenCapturer.shared.isPermissionGranted }
    @discardableResult
    static func request() -> Bool { MacScreenCapturer.shared.requestPermission() }
}
