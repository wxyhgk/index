import AppKit
import ScreenCaptureKit

enum RecordingError: Error, LocalizedError {
    case unsupportedOS
    case alreadyRecording
    case notRecording
    case displayNotFound

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
        }
    }
}

/// 选区录屏。SCStream 直接产 mp4 文件（`SCRecordingOutput`，macOS 15+），
/// 不自建 AVAssetWriter 管线 —— 低版本明确报「需要 macOS 15」。
///
/// 状态机：idle → recording(startedAt) → finishing → idle。
/// `isRecording` 同时是全局互斥位：录制中 `CaptureCoordinator.begin` 会拒绝再开截图。
@MainActor
final class ScreenRecorder {

    static let shared = ScreenRecorder()

    enum State {
        case idle
        case recording(startedAt: Date)
        case finishing
    }

    private(set) var state: State = .idle

    /// macOS 15 之前拿不到 `SCRecordingOutput`，存成 AnyObject 绕开
    /// 「存储属性不能按可用性注解」的限制，用的时候在可用性块里转回来。
    private var session: AnyObject?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var startedAt: Date? {
        if case .recording(let date) = state { return date }
        return nil
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private init() {}

    /// 开始录制 `display` 上的 `region`（AppKit 全局坐标，点）。
    func start(region: CGRect, display: DisplayInfo) async throws {
        guard case .idle = state else { throw RecordingError.alreadyRecording }
        guard #available(macOS 15.0, *) else { throw RecordingError.unsupportedOS }

        let session = RecordingSession(
            region: region,
            display: display,
            outputURL: try Self.makeOutputURL()
        )
        try await session.start()
        self.session = session
        state = .recording(startedAt: Date())
    }

    /// 停止并收尾（写完 moov box），返回 mp4 路径。
    func stop() async throws -> URL {
        guard isRecording else { throw RecordingError.notRecording }
        guard #available(macOS 15.0, *), let session = session as? RecordingSession else {
            state = .idle
            throw RecordingError.notRecording
        }

        state = .finishing
        defer {
            state = .idle
            self.session = nil
        }
        try await session.stop()
        return session.outputURL
    }

    // MARK: - 输出位置

    /// `~/Library/Application Support/MacShot/recordings/<时间戳>.mp4`
    private static func makeOutputURL() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacShot/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("\(formatter.string(from: Date())).mp4")
    }
}

/// 一次录制会话：SCStream + SCRecordingOutput 的生命周期。
///
/// 关键配置：
///   · `sourceRect` 是**显示器局部**坐标、左上原点、单位「点」；输出尺寸另用
///     width/height 按 scale 指定，两者配合才能拿到 Retina 全分辨率的选区画面
///   · 过滤器排除自身进程 —— 红色录制边框、菜单栏图标都不会进画面
///   · `showsCursor = true`：录屏要看到光标（和截图相反）
@available(macOS 15.0, *)
private final class RecordingSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {

    let outputURL: URL

    private let region: CGRect
    private let display: DisplayInfo
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    /// 录制中途的失败（磁盘满、显示器断开）。stop 时抛给调用方。
    private var runtimeError: Error?

    init(region: CGRect, display: DisplayInfo, outputURL: URL) {
        self.region = region
        self.display = display
        self.outputURL = outputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw RecordingError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: content.applications.filter { $0.processID == ownPID },
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

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = outputURL
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
    }

    func stop() async throws {
        guard let stream else {
            if let runtimeError { throw runtimeError }
            return
        }
        self.stream = nil
        self.recordingOutput = nil
        // stopCapture 会等 SCRecordingOutput 把文件收尾，返回后 mp4 即完整可播。
        try await stream.stopCapture()
        if let runtimeError { throw runtimeError }
    }

    // MARK: - 失败回调（后台队列进来，只记录，stop 时统一抛出）

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        runtimeError = error
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        runtimeError = error
    }
}
