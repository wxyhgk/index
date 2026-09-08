import AppKit
import SwiftUI

/// 图库页面向窗口宿主发出的意图。
///
/// 页面只描述“打开编辑器 / 定位 / 预览”等动作，不直接抓取
/// `GalleryWindowController.shared`。默认值保持现有运行行为；测试、Preview 和
/// 将来的多窗口宿主可以通过 Environment 注入另一组实现。
struct GalleryPageCommands {
    private let openEditorAction: @MainActor (Int64?) -> Void
    private let openMarkdownEditorAction: @MainActor (Int64?) -> Void
    private let openCodeEditorAction: @MainActor (Int64?) -> Void
    private let openSettingsAction: @MainActor () -> Void
    private let returnToGalleryAction: @MainActor () -> Void
    private let presentQuickLookAction: @MainActor () -> Void
    private let selectOnlyAction: @MainActor (Int64?) -> Void
    private let clearTextFocusAction: @MainActor () -> Void
    private let hostWindowProvider: @MainActor () -> NSWindow?
    private let performRecordingPrimaryAction: @MainActor (RecordingAsset, Int64?) -> Void

    init(
        openEditor: @escaping @MainActor (Int64?) -> Void,
        openMarkdownEditor: @escaping @MainActor (Int64?) -> Void,
        openCodeEditor: @escaping @MainActor (Int64?) -> Void,
        openSettings: @escaping @MainActor () -> Void,
        returnToGallery: @escaping @MainActor () -> Void,
        presentQuickLook: @escaping @MainActor () -> Void,
        selectOnly: @escaping @MainActor (Int64?) -> Void,
        clearTextFocus: @escaping @MainActor () -> Void,
        hostWindow: @escaping @MainActor () -> NSWindow?,
        performRecordingPrimary: @escaping @MainActor (RecordingAsset, Int64?) -> Void
    ) {
        openEditorAction = openEditor
        openMarkdownEditorAction = openMarkdownEditor
        openCodeEditorAction = openCodeEditor
        openSettingsAction = openSettings
        returnToGalleryAction = returnToGallery
        presentQuickLookAction = presentQuickLook
        selectOnlyAction = selectOnly
        clearTextFocusAction = clearTextFocus
        hostWindowProvider = hostWindow
        performRecordingPrimaryAction = performRecordingPrimary
    }

    @MainActor func openEditor(shotID: Int64?) { openEditorAction(shotID) }
    @MainActor func openMarkdownEditor(shotID: Int64?) { openMarkdownEditorAction(shotID) }
    @MainActor func openCodeEditor(shotID: Int64?) { openCodeEditorAction(shotID) }
    @MainActor func openSettings() { openSettingsAction() }
    @MainActor func returnToGallery() { returnToGalleryAction() }
    @MainActor func presentQuickLook() { presentQuickLookAction() }
    @MainActor func select(only shotID: Int64?) { selectOnlyAction(shotID) }
    @MainActor func clearTextFocus() { clearTextFocusAction() }
    @MainActor var hostWindow: NSWindow? { hostWindowProvider() }

    @MainActor
    func performPrimaryRecordingAction(_ asset: RecordingAsset, shotID: Int64?) {
        performRecordingPrimaryAction(asset, shotID)
    }

    /// 单例只封装在默认装配处；具体页面不再依赖它。
    static var live: GalleryPageCommands {
        GalleryPageCommands(
            openEditor: { GalleryWindowController.shared.mode.openEditor(shotID: $0) },
            openMarkdownEditor: {
                GalleryWindowController.shared.mode.openMarkdownEditor(shotID: $0)
            },
            openCodeEditor: {
                GalleryWindowController.shared.mode.openCodeEditor(shotID: $0)
            },
            openSettings: { GalleryWindowController.shared.mode.openSettings() },
            returnToGallery: { GalleryWindowController.shared.mode.returnToGallery() },
            presentQuickLook: { GalleryWindowController.shared.quickLook.present() },
            selectOnly: { GalleryWindowController.shared.selection.select(only: $0) },
            clearTextFocus: {
                let window = GalleryWindowController.shared.window
                if window?.firstResponder is NSTextView {
                    window?.makeFirstResponder(nil)
                }
            },
            hostWindow: { GalleryWindowController.shared.window },
            performRecordingPrimary: { asset, shotID in
                RecordingAssetActions.performPrimary(
                    asset,
                    shotID: shotID,
                    presenter: GalleryWindowController.shared
                )
            }
        )
    }
}

private struct GalleryPageCommandsKey: EnvironmentKey {
    static var defaultValue: GalleryPageCommands { .live }
}

extension EnvironmentValues {
    var galleryPageCommands: GalleryPageCommands {
        get { self[GalleryPageCommandsKey.self] }
        set { self[GalleryPageCommandsKey.self] = newValue }
    }
}
