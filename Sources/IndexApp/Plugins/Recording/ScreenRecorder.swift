import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecordingError: Error, LocalizedError {
    case unsupportedOS
    case alreadyRecording
    case notRecording
    case displayNotFound
    case nothingRecorded
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "选区录屏需要 macOS 15 或更高版本"
        case .alreadyRecording:
            return "已经在录制中"
        case .notRecording:
            return "当前没有进行中的录制"
        case .displayNotFound:
            return "找不到选区所在的显示器"
        case .nothingRecorded:
            return "没有录到任何有效画面"
        case .exportFailed:
            return "分段拼接导出失败"
        }
    }
}

/// 录制链路在运行期自行终止（例如显示器断开、磁盘写入失败）。同一会话的 stream / output
/// 可能各回调一次，事件 ID 让上层可以幂等收尾。
struct RecordingTerminationEvent {
    let id: UUID
    let error: Error
}

/// ScreenCaptureKit 的两个失败 delegate 可能并发到达；只允许第一个穿过。
final class RecordingTerminationRelay {
    private let lock = NSLock()
    private var hasEmitted = false
    private let handler: (Error) -> Void

    init(handler: @escaping (Error) -> Void) {
        self.handler = handler
    }

    func emit(_ error: Error) {
        lock.lock()
        guard !hasEmitted else {
            lock.unlock()
            return
        }
        hasEmitted = true
        lock.unlock()
        handler(error)
    }
}

/// 选区录屏。SCStream 直接产 mp4 文件（`SCRecordingOutput`，macOS 15+），
/// 不自建 AVAssetWriter 管线 —— 低版本明确报「需要 macOS 15」。
///
/// 状态机：idle → recording(segmentStartedAt) ⇄ paused → finishing → idle。
/// SCStream 没有原生暂停：暂停 = 停掉当前段（一个独立 mp4 分段），
/// 继续 = 开新段；最终停止时把全部分段拼成一个 mp4（见 `RecordingJob`）。
///
/// `isRecording` 同时是全局互斥位（**含暂停中**）：会话进行中
/// `CaptureCoordinator.begin` 会拒绝再开截图。
@MainActor
final class ScreenRecorder {

    static let shared = ScreenRecorder()

    enum State {
        case idle
        case starting
        case recording(segmentStartedAt: Date)
        case paused
        case finishing
    }

    private(set) var state: State = .idle

    /// 已完成段落的累计时长。计时显示 = 它 + 当前段已录时长，暂停期不走字。
    private var accumulated: TimeInterval = 0

    /// macOS 15 之前拿不到 `SCRecordingOutput`，存成 AnyObject 绕开
    /// 「存储属性不能按可用性注解」的限制，用的时候在可用性块里转回来。
    private var job: AnyObject?
    private var activeSessionID: UUID?

    /// 运行期失败的一次性终止事件。RecordingCoordinator 用它立即拆窗口与计时器。
    var onTermination: ((RecordingTerminationEvent) -> Void)?

    /// 录制会话进行中（含暂停）。
    var isRecording: Bool {
        switch state {
        case .starting, .recording, .paused: return true
        case .idle, .finishing: return false
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// 已录制的净时长（只累计录制段，不含暂停期）。
    var elapsed: TimeInterval {
        if case .recording(let segmentStartedAt) = state {
            return accumulated + Date().timeIntervalSince(segmentStartedAt)
        }
        return accumulated
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 音频开关来源。注入式：`.shared` 入口默认走 `AppSettings.shared`，
    /// RecordingCoordinator 可传自己的设置切片。
    private let recording: any RecordingPreferences

    init(recording: any RecordingPreferences = AppSettings.shared) {
        self.recording = recording
    }

    /// 开始录制 `display` 上的 `region`（AppKit 全局坐标，点）。
    /// 音频开关在此刻从设置定格 —— 录制中途改设置不影响本次会话。
    func start(region: CGRect, display: DisplayInfo) async throws {
        guard case .idle = state else { throw RecordingError.alreadyRecording }
        guard #available(macOS 15.0, *) else { throw RecordingError.unsupportedOS }

        let sessionID = UUID()
        let job = try RecordingJob(
            region: region,
            display: display,
            outputURL: Self.makeOutputURL(),
            capturesSystemAudio: recording.recordSystemAudio,
            capturesMicrophone: recording.recordMicrophone,
            onRuntimeFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleRuntimeFailure(error, sessionID: sessionID)
                }
            }
        )
        self.job = job
        activeSessionID = sessionID
        state = .starting
        do {
            try await job.startSegment()
        } catch {
            if activeSessionID == sessionID {
                resetSessionState()
            }
            await job.abort()
            throw error
        }
        guard activeSessionID == sessionID, case .starting = state else {
            await job.abort()
            throw RecordingError.notRecording
        }
        accumulated = 0
        state = .recording(segmentStartedAt: Date())
    }

    /// 暂停：当前段收尾成一个分段文件。段收尾失败只丢该段，不打断暂停。
    func pause() async throws {
        guard case .recording(let segmentStartedAt) = state,
              #available(macOS 15.0, *), let job = job as? RecordingJob
        else { throw RecordingError.notRecording }

        accumulated += Date().timeIntervalSince(segmentStartedAt)
        state = .paused
        await job.pauseSegment()
    }

    /// 继续：开一个新分段。开段失败（权限被收回、显示器拔掉）留在暂停态并抛错。
    func resume() async throws {
        guard case .paused = state,
              #available(macOS 15.0, *), let job = job as? RecordingJob
        else { throw RecordingError.notRecording }

        try await job.startSegment()
        state = .recording(segmentStartedAt: Date())
    }

    /// 停止并收尾：结掉当前段（如在录），把全部分段拼成一个 mp4，返回其路径。
    func stop() async throws -> URL {
        switch state {
        case .recording(let segmentStartedAt):
            accumulated += Date().timeIntervalSince(segmentStartedAt)
        case .paused:
            break
        case .idle, .starting, .finishing:
            throw RecordingError.notRecording
        }
        guard #available(macOS 15.0, *), let job = job as? RecordingJob else {
            state = .idle
            throw RecordingError.notRecording
        }

        state = .finishing
        defer {
            resetSessionState()
        }
        return try await job.finish()
    }

    private func handleRuntimeFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        switch state {
        case .starting, .recording, .paused:
            break
        case .idle, .finishing:
            return
        }

        let failedJob = job
        resetSessionState()
        onTermination?(RecordingTerminationEvent(id: sessionID, error: error))

        // output 失败时 stream 仍可能活着；状态与 UI 先同步清掉，底层资源随后幂等停止。
        Task { @MainActor in
            if #available(macOS 15.0, *) {
                await (failedJob as? RecordingJob)?.abort()
            }
        }
    }

    private func resetSessionState() {
        state = .idle
        job = nil
        activeSessionID = nil
        accumulated = 0
    }

    // MARK: - 输出位置

    /// `~/Library/Application Support/Index/recordings/<时间戳>.mp4`
    private static func makeOutputURL() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("\(formatter.string(from: Date())).mp4")
    }
}

/// 一次录屏作业：管理分段（暂停/恢复各成一段）和最终拼接。
///
/// 分段文件放在输出同目录的 `.parts/<输出名>/part-N.mp4` 下，拼完即删。
/// 只有一段时直接改名成成品（没暂停过的常见路径，零拷贝零转码）；
/// 多段用 `AVMutableComposition` 顺序拼接、passthrough 导出。
/// 单段损坏（极短没写出关键帧、磁盘问题）跳过该段。
@available(macOS 15.0, *)
@MainActor
private final class RecordingJob {

    let outputURL: URL

    private let region: CGRect
    private let display: DisplayInfo
    private let capturesSystemAudio: Bool
    private let capturesMicrophone: Bool
    private let onRuntimeFailure: (Error) -> Void
    private let partsDirectory: URL

    /// 已成功收尾的分段。当前录制中的段不在里面。
    private var partURLs: [URL] = []
    private var segmentIndex = 0
    private var current: RecordingSession?

    init(
        region: CGRect,
        display: DisplayInfo,
        outputURL: URL,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        onRuntimeFailure: @escaping (Error) -> Void
    ) throws {
        self.region = region
        self.display = display
        self.outputURL = outputURL
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.onRuntimeFailure = onRuntimeFailure
        partsDirectory = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".parts", isDirectory: true)
            .appendingPathComponent(
                outputURL.deletingPathExtension().lastPathComponent,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: partsDirectory,
            withIntermediateDirectories: true
        )
    }

    func startSegment() async throws {
        let url = partsDirectory.appendingPathComponent("part-\(segmentIndex).mp4")
        segmentIndex += 1
        let session = RecordingSession(
            region: region,
            display: display,
            outputURL: url,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            onRuntimeFailure: { [weak self] session, error in
                Task { @MainActor [weak self] in
                    guard let self, self.current === session else { return }
                    self.onRuntimeFailure(error)
                }
            }
        )
        current = session
        do {
            try await session.start()
        } catch {
            if current === session { current = nil }
            throw error
        }
    }

    /// 停掉当前段。收尾失败（比如段极短没写出关键帧）只跳过该段。
    func pauseSegment() async {
        guard let session = current else { return }
        current = nil
        do {
            try await session.stop()
            partURLs.append(session.outputURL)
        } catch {
            NSLog("[Index] 录屏分段收尾失败，跳过该段: \(error)")
        }
    }

    func finish() async throws -> URL {
        await pauseSegment()
        let valid = partURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else {
            cleanup()
            throw RecordingError.nothingRecorded
        }

        if valid.count == 1 {
            try FileManager.default.moveItem(at: valid[0], to: outputURL)
        } else {
            try await Self.concatenate(parts: valid, into: outputURL)
        }
        cleanup()
        await Self.logTracks(of: outputURL)
        return outputURL
    }

    /// 运行期失败后的废弃路径：不产生成品，停止仍存活的 stream，并清掉全部分段。
    func abort() async {
        if let session = current {
            current = nil
            await session.abort()
        }
        cleanup()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: partsDirectory)
    }

    // MARK: - 分段拼接

    /// 按录制顺序把分段接成一条：轨道按「媒体类型 + 段内序号」对齐
    /// （系统声音和麦克风是两条独立音轨，不能混插到同一条）。
    /// passthrough 导出保持 SCRecordingOutput 写的 H.264/AAC 原样，不重编码。
    private static func concatenate(parts: [URL], into outputURL: URL) async throws {
        let composition = AVMutableComposition()
        var tracksByKey: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        var merged = 0

        for part in parts {
            do {
                let asset = AVURLAsset(url: part)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)
                guard duration > .zero,
                      tracks.contains(where: { $0.mediaType == .video })
                else {
                    NSLog("[Index] 录屏分段无有效画面，跳过: \(part.lastPathComponent)")
                    continue
                }

                let range = CMTimeRange(start: .zero, duration: duration)
                var indexInType: [AVMediaType: Int] = [:]
                for track in tracks {
                    let slot = indexInType[track.mediaType, default: 0]
                    indexInType[track.mediaType] = slot + 1
                    let key = "\(track.mediaType.rawValue)#\(slot)"

                    let target: AVMutableCompositionTrack
                    if let existing = tracksByKey[key] {
                        target = existing
                    } else if let created = composition.addMutableTrack(
                        withMediaType: track.mediaType,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                        tracksByKey[key] = created
                        target = created
                    } else {
                        continue
                    }
                    try target.insertTimeRange(range, of: track, at: cursor)
                }
                cursor = cursor + duration
                merged += 1
            } catch {
                NSLog("[Index] 录屏分段不可用，跳过: \(part.lastPathComponent) \(error)")
            }
        }

        guard merged > 0 else { throw RecordingError.nothingRecorded }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { throw RecordingError.exportFailed }
        try await exporter.export(to: outputURL, as: .mp4)
    }

    /// 成品轨道清单打进日志 —— 验证「音轨确实写进去了」的最直接证据。
    private static func logTracks(of url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks) else { return }
        let kinds = tracks.map(\.mediaType.rawValue).joined(separator: ", ")
        NSLog("[Index] 录屏完成 \(url.lastPathComponent)，轨道: [\(kinds)]")
    }
}

/// 一个录制分段：SCStream + SCRecordingOutput 的生命周期。
///
/// 关键配置：
///   · `sourceRect` 是**显示器局部**坐标、左上原点、单位「点」；输出尺寸另用
///     width/height 按 scale 指定，两者配合才能拿到 Retina 全分辨率的选区画面
///   · 过滤器排除自身进程 —— 红色录制边框、菜单栏图标都不会进画面
///   · `showsCursor = true`：录屏要看到光标（和截图相反）
///   · `capturesAudio` 收系统声音（排除自身进程的提示音）、
///     `captureMicrophone` 收默认麦克风，SCRecordingOutput 把音轨一起写进 mp4
@available(macOS 15.0, *)
private final class RecordingSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {

    let outputURL: URL

    private let region: CGRect
    private let display: DisplayInfo
    private let capturesSystemAudio: Bool
    private let capturesMicrophone: Bool
    private let onRuntimeFailure: (RecordingSession, Error) -> Void
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    /// 录制中途的失败（磁盘满、显示器断开）。stop 时抛给调用方。
    private var runtimeError: Error?
    private let failureLock = NSLock()
    private var isStopping = false
    private var terminationRelay: RecordingTerminationRelay!

    init(
        region: CGRect,
        display: DisplayInfo,
        outputURL: URL,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        onRuntimeFailure: @escaping (RecordingSession, Error) -> Void
    ) {
        self.region = region
        self.display = display
        self.outputURL = outputURL
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.onRuntimeFailure = onRuntimeFailure
        super.init()
        terminationRelay = RecordingTerminationRelay { [weak self] error in
            guard let self else { return }
            self.onRuntimeFailure(self, error)
        }
    }

    func start() async throws {
        let broker = MacScreenCaptureBroker.shared
        let captureSession = try broker.beginSession()
        defer { broker.finishSession(captureSession) }

        let content = try await broker.shareableContent(
            in: captureSession,
            operationName: "recording:shareable-content"
        )
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw RecordingError.displayNotFound
        }

        // 不排除自身进程 —— Agent 面板、图库窗口等也是自身进程的，
        // 用户可能想录到它们（如录 Agent 操作过程）。
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        // AppKit 全局（左下原点）→ 显示器局部（左上原点），单位保持「点」。
        config.sourceRect = CGRect(
            x: region.minX - display.frame.minX,
            y: display.frame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )
        config.width = Int((region.width * display.scale).rounded())
        config.height = Int((region.height * display.scale).rounded())
        config.scalesToFit = false
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = capturesSystemAudio
        if capturesSystemAudio {
            // 自己弹的提示音不进录音。
            config.excludesCurrentProcessAudio = true
        }
        config.captureMicrophone = capturesMicrophone

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = outputURL
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        try await broker.startCapture(
            stream,
            in: captureSession,
            operationName: "recording:start-stream"
        )

        self.stream = stream
        self.recordingOutput = output
    }

    func stop() async throws {
        markStopping()
        guard let stream else {
            if let runtimeError = recordedRuntimeError() { throw runtimeError }
            return
        }
        self.stream = nil
        self.recordingOutput = nil
        // stopCapture 会等 SCRecordingOutput 把文件收尾，返回后 mp4 即完整可播。
        try await stream.stopCapture()
        if let runtimeError = recordedRuntimeError() { throw runtimeError }
    }

    func abort() async {
        markStopping()
        guard let stream else { return }
        self.stream = nil
        recordingOutput = nil
        try? await stream.stopCapture()
    }

    private func markStopping() {
        failureLock.lock()
        isStopping = true
        failureLock.unlock()
    }

    private func recordedRuntimeError() -> Error? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return runtimeError
    }

    private func recordRuntimeFailure(_ error: Error) {
        failureLock.lock()
        if runtimeError == nil { runtimeError = error }
        let shouldEmit = !isStopping
        failureLock.unlock()
        if shouldEmit { terminationRelay.emit(error) }
    }

    // MARK: - 失败回调（后台队列进来，一次性上报并保留错误供 stop 抛出）

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordRuntimeFailure(error)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        recordRuntimeFailure(error)
    }
}
