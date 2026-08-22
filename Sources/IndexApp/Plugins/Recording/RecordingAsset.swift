import AppKit

/// 图库里一个 Shot 对应的录屏资产状态。
///
/// recording 附件的存在定义「这是录屏」；磁盘文件是否还在只定义「现在能否播放」。
/// 两者不能混为一谈：用户移动/删除 mp4 后，封面 Shot 仍然是录屏索引，不能退化成
/// 普通截图并在双击或回车时误入标注编辑器。
enum RecordingAsset: Equatable {
    case screenshot
    case available(URL)
    case missing(URL)

    init(
        path: String?,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) {
        guard let path, !path.isEmpty else {
            self = .screenshot
            return
        }
        let url = URL(fileURLWithPath: path)
        self = fileExists(path) ? .available(url) : .missing(url)
    }

    var isRecording: Bool {
        switch self {
        case .screenshot: return false
        case .available, .missing: return true
        }
    }

    var availableURL: URL? {
        guard case let .available(url) = self else { return nil }
        return url
    }

    /// 双击与 Return 的唯一动作语义。右键「播放录屏」也消费同一结果。
    var playbackAction: RecordingPlaybackAction {
        switch self {
        case .screenshot: return .editCover
        case let .available(url): return .play(url)
        case let .missing(url): return .reportMissing(url)
        }
    }
}

enum RecordingPlaybackAction: Equatable {
    case editCover
    case play(URL)
    case reportMissing(URL)
}

/// 录屏资产动作的统一执行器。状态判定保持纯值；系统打开、访达和弹窗仍只经 Platform 门面。
@MainActor
enum RecordingAssetActions {
    static func performPrimary(
        _ asset: RecordingAsset,
        shotID: Int64?,
        presenter: any GalleryPresenting,
        hostWindow: NSWindow? = nil
    ) {
        switch asset.playbackAction {
        case .editCover:
            presenter.openEditor(shotID: shotID)
        case let .play(url):
            SystemNavigator.open(url: url)
        case let .reportMissing(url):
            reportMissing(url, hostWindow: hostWindow)
        }
    }

    static func play(_ asset: RecordingAsset, hostWindow: NSWindow? = nil) {
        switch asset.playbackAction {
        case let .play(url):
            SystemNavigator.open(url: url)
        case let .reportMissing(url):
            reportMissing(url, hostWindow: hostWindow)
        case .editCover:
            break
        }
    }

    static func reveal(_ asset: RecordingAsset, hostWindow: NSWindow? = nil) {
        switch asset {
        case let .available(url):
            SystemNavigator.revealInFinder(url)
        case let .missing(url):
            reportMissing(url, hostWindow: hostWindow)
        case .screenshot:
            break
        }
    }

    private static func reportMissing(_ url: URL, hostWindow: NSWindow?) {
        AppAlert.error(
            "找不到录屏文件",
            message: "这条录屏仍保留在图库中，但原始 MP4 已被移动或删除。\n\n原位置：\(url.path)",
            host: hostWindow
        )
    }
}
