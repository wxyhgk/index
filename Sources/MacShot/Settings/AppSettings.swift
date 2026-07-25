import AppKit
import Combine

/// 全部用户设置。`ObservableObject` 让 SwiftUI 直接绑定，
/// `didSet` 负责落盘和把变更推给需要的子系统（比如重新注册快捷键）。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// 选区确认后按回车做什么。
    enum EnterBehavior: String, CaseIterable, Identifiable {
        case copyAndFinish
        case finishOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .copyAndFinish: return "完成并复制"
            case .finishOnly:    return "完成（不复制）"
            }
        }

        var detail: String {
            switch self {
            case .copyAndFinish: return "结果放进剪贴板"
            case .finishOnly:    return "只入库，不动剪贴板"
            }
        }
    }

    private enum Keys {
        static let copyToClipboard = "copyToClipboard"
        static let runOCR = "runOCR"
        static let enterBehavior = "enterBehavior"
        static let defaultColorIndex = "defaultColorIndex"
        static let defaultWidthIndex = "defaultWidthIndex"
        static let captureShortcut = "captureShortcut"
        static let galleryShortcut = "galleryShortcut"
    }

    private let defaults = UserDefaults.standard

    // MARK: - 截图

    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    @Published var enterBehavior: EnterBehavior {
        didSet { defaults.set(enterBehavior.rawValue, forKey: Keys.enterBehavior) }
    }

    // MARK: - 标注默认值

    @Published var defaultColorIndex: Int {
        didSet { defaults.set(defaultColorIndex, forKey: Keys.defaultColorIndex) }
    }

    @Published var defaultWidthIndex: Int {
        didSet { defaults.set(defaultWidthIndex, forKey: Keys.defaultWidthIndex) }
    }

    // MARK: - 智能

    @Published var runOCR: Bool {
        didSet { defaults.set(runOCR, forKey: Keys.runOCR) }
    }

    // MARK: - 快捷键

    @Published var captureShortcut: KeyboardShortcut {
        didSet {
            store(captureShortcut, forKey: Keys.captureShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var galleryShortcut: KeyboardShortcut {
        didSet {
            store(galleryShortcut, forKey: Keys.galleryShortcut)
            onShortcutsChanged?()
        }
    }

    /// 由 AppDelegate 装上：快捷键一改就重新注册。
    var onShortcutsChanged: (() -> Void)?

    // MARK: -

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.copyToClipboard: true,
            Keys.runOCR: true,
            Keys.enterBehavior: EnterBehavior.copyAndFinish.rawValue,
            Keys.defaultColorIndex: 0,
            Keys.defaultWidthIndex: 1
        ])

        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        runOCR = defaults.bool(forKey: Keys.runOCR)
        enterBehavior = defaults.string(forKey: Keys.enterBehavior)
            .flatMap(EnterBehavior.init(rawValue:)) ?? .copyAndFinish
        defaultColorIndex = defaults.integer(forKey: Keys.defaultColorIndex)
        defaultWidthIndex = defaults.integer(forKey: Keys.defaultWidthIndex)
        captureShortcut = Self.load(Keys.captureShortcut, from: defaults) ?? .captureDefault
        galleryShortcut = Self.load(Keys.galleryShortcut, from: defaults) ?? .galleryDefault
    }

    func resetShortcuts() {
        captureShortcut = .captureDefault
        galleryShortcut = .galleryDefault
    }

    private func store(_ shortcut: KeyboardShortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}
