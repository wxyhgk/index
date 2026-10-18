import AppKit
import SwiftUI

// MARK: - 搜索面板协调器
//
// 窗口壳在 `Platform/macOS/Windowing/SearchPanel.swift`；这里负责内容、
// 键盘语义和目标 App 记忆。键盘映射只保留一套：Esc 关闭，↑↓ 移动选择，
// 其余放行给搜索框（此前 `firstResponder is NSText` 的分支结果是等价的）。

@MainActor
final class SearchPanelCoordinator {

    private var panel: SearchPanel?
    private let viewModel: SearchPanelViewModel
    private var previousFrontmostApp: NSRunningApplication?

    init(viewModel: SearchPanelViewModel) {
        self.viewModel = viewModel
        viewModel.onPasteIntoPreviousApp = { [weak self] in
            self?.closeAndPasteIntoPreviousApp()
        }
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        showPanel()
    }

    func showPanel() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }
        if panel == nil {
            panel = makePanel()
        }
        panel?.show()
    }

    private func makePanel() -> SearchPanel {
        var spec = PanelSpec.search(size: SearchPanelMetrics.panelSize)
        spec.contentCornerRadius = DS.radiusPanel
        let hosting = NSHostingController(rootView: SearchPanelView(viewModel: viewModel))
        let panel = SearchPanel(spec: spec, contentViewController: hosting)
        panel.onClose = { [weak self] in
            self?.panel = nil
        }
        panel.onClickOutside = { [weak panel] in
            panel?.close()
        }
        panel.onKeyDown = { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case KeyCode.escape:
                self.panel?.close()
                return nil
            case KeyCode.up:
                self.viewModel.moveSelection(-1)
                return nil
            case KeyCode.down:
                self.viewModel.moveSelection(1)
                return nil
            default:
                return event
            }
        }
        return panel
    }

    func closePanel() {
        panel?.close()
    }

    /// 平台键盘注入统一走 ClipboardPasteDispatcher；商店版只恢复目标应用，
    /// 内容已经复制好，由用户使用系统 Cmd+V。
    func closeAndPasteIntoPreviousApp() {
        let target = previousFrontmostApp
        previousFrontmostApp = nil
        panel?.close()
        guard let target else { return }
        if IndexDistribution.supportsGlobalAccessibilityFeatures {
            ClipboardPasteDispatcher.paste(into: target)
        } else {
            target.activate(options: [])
        }
    }
}
