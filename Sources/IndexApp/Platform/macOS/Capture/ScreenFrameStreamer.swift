import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 按需启停的 SCStream 帧流（对标 PixPin 的 PixScreenManager + PixScreenStreamer）。
///
/// 每块屏一个 SCStream，收帧时只 retain 最新 CVPixelBuffer（零拷贝）；
/// 转 CGImage 推迟到真正取快照 / 有订阅者时。截图快路径从缓存取最新帧。
///
/// **不常驻**：4 条 30fps 流会把 WindowServer 从 ~37% 推到 ~90%，即使 App 自身
/// 空闲也一样。首次截图走 SCScreenshotManager 慢路径，随后后台预热，
/// 20 秒无截图自动停流（scheduleIdleStop）。
///
/// 流排除自身 PID：overlay 窗口不会递归拍进背景，截图背景是「干净桌面」。
///
/// 注意：快路径取的是「按快捷键那一刻」的 latest frame（截图冻结语义的准实时版）。
/// 若后续要把截图精确到「确认选区那一刻」的帧，在确认流程再取一次 latestFrame 裁剪即可。
@MainActor
final class ScreenFrameStreamer {

    static let shared = ScreenFrameStreamer()

    /// 帧率上限（30fps）。实测 SCK 在静止屏幕仍会持续推帧，所以这里只缓存
    /// CVPixelBuffer（retain，零拷贝），转 CGImage 推迟到真正取快照时。
    private static let fps: Int32 = 30

    nonisolated private let frameStore = FrameStore()
    nonisolated private let subscriptionStore = SubscriptionStore()
    private let sampleQueue = DispatchQueue(label: "com.index.screen-frame-stream", qos: .userInitiated)

    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var outputs: [CGDirectDisplayID: FrameOutput] = [:]

    private(set) var isRunning = false
    private var isStarting = false
    private var isStopping = false
    /// 空闲自动停流；每次截图/预热都会顺延。
    private var idleStopTask: Task<Void, Never>?

    private init() {}

    // MARK: - 生命周期

    /// App 启动时调用：已授权则建 per-display 常驻流。
    func start() async {
        idleStopTask?.cancel()
        idleStopTask = nil
        guard !isStarting, !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("[Index] 常驻帧流：未授权，跳过")
            return
        }
        await rebuild()
    }

    func stop() async {
        idleStopTask?.cancel()
        idleStopTask = nil
        guard isRunning, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        await teardownStreams()
        frameStore.removeAll()
        isRunning = false
        NSLog("[Index] 常驻帧流已停止")
    }

    /// 截图后调用：`seconds` 内没有新的截图就停流，避免 SCStream 空闲时
    /// 持续让 WindowServer 合成。重复调用会顺延计时。
    func scheduleIdleStop(after seconds: TimeInterval = 20) {
        idleStopTask?.cancel()
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    /// 拓扑变化 / 流崩溃时重建全部流。
    func rebuild() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await teardownStreams()
        await startStreams()
    }

    private func teardownStreams() async {
        for (displayID, stream) in streams {
            NSLog("[Index] 常驻帧流拆除 displayID=%u", displayID)
            await stopStreamCapture(stream)
        }
        streams.removeAll()
        outputs.removeAll()
    }

    private func startStreams() async {
        let displays = NSScreen.screens.compactMap(DisplayInfo.init(screen:))
        guard !displays.isEmpty else {
            isRunning = false
            return
        }
        do {
            let session = try MacScreenCaptureBroker.shared.beginSession()
            defer { MacScreenCaptureBroker.shared.finishSession(session) }
            let content = try await MacScreenCaptureBroker.shared.shareableContent(
                in: session,
                operationName: "frames:content"
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let selfApps = content.applications.filter { $0.processID == ownPID }
            for display in displays {
                guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                    NSLog("[Index] 常驻帧流：共享内容缺显示器 displayID=%u", display.id)
                    continue
                }
                let filter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: selfApps,
                    exceptingWindows: []
                )
                let config = makeConfig(for: display)
                let output = FrameOutput(displayID: display.id, frameStore: frameStore, streamer: self)
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                do {
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
                    try await MacScreenCaptureBroker.shared.startCapture(
                        stream,
                        in: session,
                        operationName: "frames:start:\(display.id)"
                    )
                    streams[display.id] = stream
                    outputs[display.id] = output
                } catch {
                    NSLog("[Index] 常驻帧流启动失败 displayID=%u error=%@", display.id, String(describing: error))
                }
            }
            isRunning = !streams.isEmpty
            NSLog("[Index] 常驻帧流启动完成 count=%d", streams.count)
        } catch {
            NSLog("[Index] 常驻帧流启动失败 error=%@", String(describing: error))
            isRunning = false
        }
    }

    private func makeConfig(for display: DisplayInfo) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int((display.frame.width * display.scale).rounded())
        config.height = Int((display.frame.height * display.scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        config.queueDepth = 3
        return config
    }

    /// 流停止（replayd 崩溃等）→ 重建。
    func handleStreamStopped(displayID: CGDirectDisplayID, error: Error) {
        // 主动 stop / rebuild 时的 teardown 不是崩溃，别触发重建回环。
        guard isRunning, !isStopping else { return }
        NSLog("[Index] 常驻帧流 displayID=%u 停止 error=%@，触发重建", displayID, String(describing: error))
        Task { @MainActor in
            await self.rebuild()
        }
    }

    private func stopStreamCapture(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            NSLog("[Index] 常驻帧流 stopCapture 失败: \(error)")
        }
    }

    // MARK: - 取帧（截图快路径）

    /// nonisolated：跨线程安全（frameStore 锁保护）。供 OverlayView init 等非 @MainActor 上下文取单屏最新帧。
    nonisolated func latestFrame(for displayID: CGDirectDisplayID) -> CGImage? {
        guard let buffer = frameStore.latest(displayID) else { return nil }
        return Self.makeImage(from: buffer)
    }

    func isReady(for displays: [DisplayInfo]) -> Bool {
        guard isRunning else { return false }
        return displays.allSatisfy { frameStore.latest($0.id) != nil }
    }

    func latestFrames(for displays: [DisplayInfo]) -> [CGDirectDisplayID: CGImage] {
        let validIDs = Set(displays.map(\.id))
        var result: [CGDirectDisplayID: CGImage] = [:]
        for (displayID, buffer) in frameStore.all() where validIDs.contains(displayID) {
            if let image = Self.makeImage(from: buffer) {
                result[displayID] = image
            }
        }
        return result
    }

    /// 从常驻流最新帧构造 [DisplaySnapshot]。任一屏缺帧或尺寸不符返回 nil（调用方回退慢路径）。
    func snapshots(for displays: [DisplayInfo]) -> [DisplaySnapshot]? {
        guard isRunning else { return nil }
        return Self.snapshotsFromFrames(displays, frames: latestFrames(for: displays))
    }

    /// 纯函数：校验尺寸 + 构造快照。便于单测（不依赖 SCK / 单例）。
    /// nonisolated：只依赖参数、不访问实例状态，可在非 @MainActor 上下文调用（供单测）。
    nonisolated static func snapshotsFromFrames(
        _ displays: [DisplayInfo],
        frames: [CGDirectDisplayID: CGImage]
    ) -> [DisplaySnapshot]? {
        guard !displays.isEmpty else { return nil }
        var result: [DisplaySnapshot] = []
        for display in displays {
            guard let image = frames[display.id] else { return nil }
            let expectedWidth = Int((display.frame.width * display.scale).rounded())
            let expectedHeight = Int((display.frame.height * display.scale).rounded())
            guard abs(image.width - expectedWidth) <= 1, abs(image.height - expectedHeight) <= 1 else {
                NSLog(
                    "[Index] 常驻帧流尺寸不符 displayID=%u 期望=%dx%d 实得=%dx%d",
                    display.id, expectedWidth, expectedHeight, image.width, image.height
                )
                return nil
            }
            result.append(DisplaySnapshot(
                display: display,
                image: image,
                imageScale: CGFloat(image.width) / display.frame.width
            ))
        }
        return result
    }

    // MARK: - 订阅（overlay 准实时背景）

    struct FrameSubscription: Sendable {
        let displayID: CGDirectDisplayID
        let token: UUID
    }

    /// 订阅某块屏的实时帧（overlay 准实时背景）。nonisolated：跨线程安全（store 锁保护）。
    @discardableResult
    nonisolated func subscribe(
        displayID: CGDirectDisplayID,
        handler: @escaping @MainActor (CGImage) -> Void
    ) -> FrameSubscription {
        let token = UUID()
        subscriptionStore.add(displayID, token, handler)
        return FrameSubscription(displayID: displayID, token: token)
    }

    nonisolated func unsubscribe(_ subscription: FrameSubscription) {
        subscriptionStore.remove(subscription.displayID, subscription.token)
    }

    /// 有没有订阅者。没有订阅时 FrameOutput 连 CGImage 都不建。
    nonisolated func hasSubscribers(for displayID: CGDirectDisplayID) -> Bool {
        subscriptionStore.hasHandlers(for: displayID)
    }

    /// 把 SCK 的 BGRA 像素缓冲转成 CGImage。只在取快照 / 有订阅者时调用。
    nonisolated static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let basePtr = base.assumingMemoryBound(to: UInt8.self)
        let pixelData = Data(bytes: basePtr, count: bytesPerRow * h)
        let cfData = pixelData as CFData
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// 推送新帧给订阅者（@MainActor，FrameOutput 通过 Task 调用）。
    func notifySubscribers(displayID: CGDirectDisplayID, image: CGImage) {
        let handlers = subscriptionStore.handlers(for: displayID)
        for handler in handlers {
            handler(image)
        }
    }
}

/// 线程安全帧缓存（sampleQueue 写、MainActor 读）。
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    /// 只 retain CVPixelBuffer；转 CGImage（一次整屏 memcpy）推迟到取快照时。
    private var frames: [CGDirectDisplayID: CVPixelBuffer] = [:]

    func update(_ displayID: CGDirectDisplayID, _ buffer: CVPixelBuffer) {
        lock.lock()
        frames[displayID] = buffer
        lock.unlock()
    }

    func latest(_ displayID: CGDirectDisplayID) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return frames[displayID]
    }

    func all() -> [CGDirectDisplayID: CVPixelBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func removeAll() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }
}

/// 线程安全订阅存储（subscribe 跨线程，notify 在 @MainActor 遍历调用）。
final class SubscriptionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [CGDirectDisplayID: [UUID: @MainActor (CGImage) -> Void]] = [:]

    func add(_ displayID: CGDirectDisplayID, _ token: UUID, _ handler: @escaping @MainActor (CGImage) -> Void) {
        lock.lock()
        subs[displayID, default: [:]][token] = handler
        lock.unlock()
    }

    func remove(_ displayID: CGDirectDisplayID, _ token: UUID) {
        lock.lock()
        subs[displayID]?.removeValue(forKey: token)
        if subs[displayID]?.isEmpty == true { subs[displayID] = nil }
        lock.unlock()
    }

    func handlers(for displayID: CGDirectDisplayID) -> [@MainActor (CGImage) -> Void] {
        lock.lock()
        defer { lock.unlock() }
        guard let dict = subs[displayID] else { return [] }
        return Array(dict.values)
    }

    func hasHandlers(for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subs[displayID]?.isEmpty == false
    }
}

/// 单块屏的 SCStream 输出（sampleQueue 上收帧 → 更新缓存 + 通知订阅者）。
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    let displayID: CGDirectDisplayID
    private let frameStore: FrameStore
    weak var streamer: ScreenFrameStreamer?

    init(displayID: CGDirectDisplayID, frameStore: FrameStore, streamer: ScreenFrameStreamer) {
        self.displayID = displayID
        self.frameStore = frameStore
        self.streamer = streamer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = Self.completePixelBuffer(from: sampleBuffer)
        else { return }

        // 热路径：只 retain 最新一帧，不拷贝像素。
        frameStore.update(displayID, pixelBuffer)

        // 没有订阅者（常规情况：overlay 用冻结帧）就到此为止，
        // 不再为每帧派发主线程 Task。
        guard let streamer, streamer.hasSubscribers(for: displayID),
              let image = ScreenFrameStreamer.makeImage(from: pixelBuffer)
        else { return }
        let displayID = self.displayID
        Task { @MainActor in
            streamer.notifySubscribers(displayID: displayID, image: image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let displayID = self.displayID
        Task { @MainActor [weak streamer] in
            streamer?.handleStreamStopped(displayID: displayID, error: error)
        }
    }

    /// 只接受 .complete 帧，返回其像素缓冲；不做任何拷贝。
    private static func completePixelBuffer(from sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard
            CMSampleBufferIsValid(sampleBuffer),
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return nil }
        return pixelBuffer
    }
}
