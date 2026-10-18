import SwiftUI
import AppKit

// ============================================================
// MARK: - 剪贴板卡片主体视图 + 原生 AppKit 控件
//
// CardBody View 及其 4 个 private 控件（TitleEditor / EditorView /
// ActionButton / SourceAppIcon）。private 类型必须与使用者同文件。
// ============================================================

struct ClipboardCardBody: View, Equatable {
    let item: ClipboardHistoryItem
    var textLineLimit: Int = 6
    var store: ClipboardHistoryStore
    var showsRenameAction = false
    var isRenaming = false
    var renameText = ""
    var onRenameTextChange: ((String) -> Void)?
    var onBeginRename: (() -> Void)?
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    static func == (lhs: ClipboardCardBody, rhs: ClipboardCardBody) -> Bool {
        lhs.item == rhs.item
            && lhs.textLineLimit == rhs.textLineLimit
            && lhs.store === rhs.store
            && lhs.showsRenameAction == rhs.showsRenameAction
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renameText == rhs.renameText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: ClipboardCardMetrics.headerHeight)
            contentArea
                .layoutPriority(-1)
            footer
                .frame(height: ClipboardCardMetrics.footerHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.thumbnailBacking(scheme))
        .clipShape(cardShape)
        .overlay {
            let rim = DS.rim(.content, scheme, hovering: false)
            cardShape
                .strokeBorder(rim.solidColor, lineWidth: rim.lineWidth)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: DS.s2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.s1) {
                    if isRenaming {
                        ClipboardCardTitleEditor(
                            text: renameText,
                            placeholder: ClipboardCardPresentation.typeLabel(for: item.kind),
                            onChange: { onRenameTextChange?($0) },
                            onCommit: { onCommitRename?($0) },
                            onCancel: { onCancelRename?() }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.s1)
                        .padding(.vertical, 2)
                        .background(DS.whiteOpacity(0.16), in: RoundedRectangle(
                            cornerRadius: DS.radiusSmall,
                            style: .continuous
                        ))
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                                .strokeBorder(DS.whiteOpacity(0.42), lineWidth: 1)
                        }
                    } else {
                        Text(ClipboardCardPresentation.displayTitle(for: item))
                            .font(.system(size: DS.font13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if showsRenameAction, let onBeginRename {
                            ClipboardCardActionButton(
                                systemName: "pencil",
                                help: "修改卡片名称",
                                action: onBeginRename
                            )
                            .frame(width: 18, height: 18)
                        }
                    }
                }
                Text(ClipboardCardPresentation.relativeTime(for: item.capturedAt))
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(DS.whiteOpacity(0.76))
                    .lineLimit(1)
            }
            Spacer(minLength: DS.s1)
            ClipboardSourceAppIcon(
                appName: item.sourceApp,
                fallbackSymbol: kindSymbol
            )
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.s3)
        .background(headerColor)
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            Rectangle()
                .fill(DS.thumbnailBacking(scheme))

            switch item.kind {
            case .text:
                Text(item.text ?? item.summary ?? "")
                    .font(.system(size: DS.font13))
                    .lineSpacing(2)
                    .lineLimit(textLineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(DS.s3)
            case .image:
                if let url = store.content(of: item).assetURL {
                    Color.clear
                        .overlay {
                            CachedImage(
                                url: url,
                                key: item.thumbnailCacheKey,
                                contentMode: .fill
                            )
                        }
                        .clipped()
                } else {
                    placeholderIcon("photo")
                }
            case .file:
                VStack(spacing: DS.s2) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: DS.font20 + 8))
                        .foregroundStyle(.tertiary)
                    Text(item.summary ?? "文件")
                        .font(.system(size: DS.font12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(DS.s2)
            }
        }
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: DS.s1) {
            Text(ClipboardCardPresentation.metadata(for: item))
                .font(.system(size: DS.font10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: DS.font10, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .accessibilityLabel("已固定")
            }
        }
        .padding(.horizontal, DS.s2)
        .background(DS.panelFill(.overlay))
    }

    private var headerColor: Color {
        if let cached = AppIconAccentColorProvider.shared.cached(forName: item.sourceApp) {
            return Color(nsColor: cached)
        }
        switch item.kind {
        case .text: return DS.clipboardTextBar
        case .image: return DS.clipboardImageBar
        case .file: return DS.clipboardFileBar
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }

    private func placeholderIcon(_ name: String) -> some View {
        VStack {
            Image(systemName: name)
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 卡片标题的原生输入控件。快捷面板是 non-activating NSPanel，SwiftUI
/// FocusState 在复用 rootView 的同一轮更新里可能请求得过早；这里在控件真正
/// 进入窗口后显式设置 first responder，并把回车、失焦、Esc 统一收口。
private struct ClipboardCardTitleEditor: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> ClipboardCardTitleEditorView {
        let editor = ClipboardCardTitleEditorView()
        let field = editor.field
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .systemFont(ofSize: DS.font13, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.field = field
        context.coordinator.editorView = editor
        editor.saveButton.target = context.coordinator
        editor.saveButton.action = #selector(Coordinator.save)
        editor.onMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocus()
        }
        context.coordinator.updateCallbacks(
            onChange: onChange,
            onCommit: onCommit,
            onCancel: onCancel
        )
        return editor
    }

    static func dismantleNSView(
        _ editor: ClipboardCardTitleEditorView,
        coordinator: Coordinator
    ) {
        coordinator.stopMonitoringOutsideClicks()
    }

    func updateNSView(_ editor: ClipboardCardTitleEditorView, context: Context) {
        context.coordinator.updateCallbacks(
            onChange: onChange,
            onCommit: onCommit,
            onCancel: onCancel
        )
        editor.field.placeholderString = placeholder
        if editor.field.stringValue != text, !context.coordinator.isEditing {
            editor.field.stringValue = text
        }
        context.coordinator.requestFocus()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        weak var editorView: ClipboardCardTitleEditorView?
        private var onChange: (String) -> Void
        private var onCommit: (String) -> Void
        private var onCancel: () -> Void
        private var focusGeneration = 0
        private var didAcquireFocus = false
        private var didFinish = false
        private var outsideClickMonitor: Any?
        fileprivate var isEditing = false

        init(
            onChange: @escaping (String) -> Void,
            onCommit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onChange = onChange
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func updateCallbacks(
            onChange: @escaping (String) -> Void,
            onCommit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onChange = onChange
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func requestFocus() {
            guard !didAcquireFocus, !didFinish else { return }
            focusGeneration &+= 1
            attemptFocus(generation: focusGeneration, remainingAttempts: 8)
        }

        private func attemptFocus(generation: Int, remainingAttempts: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.focusGeneration,
                      !self.didAcquireFocus,
                      !self.didFinish,
                      let field = self.field
                else { return }

                if let window = field.window,
                   window.makeFirstResponder(field),
                   field.currentEditor() != nil {
                    self.didAcquireFocus = true
                    field.currentEditor()?.selectAll(nil)
                    self.startMonitoringOutsideClicks()
                } else if remainingAttempts > 1 {
                    self.attemptFocus(
                        generation: generation,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
            didAcquireFocus = true
            startMonitoringOutsideClicks()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            finish(commit: true, value: field?.stringValue ?? "")
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false, value: textView.string)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true, value: textView.string)
                return true
            }
            return false
        }

        @objc func save() {
            finish(commit: true, value: field?.stringValue ?? "")
        }

        private func finish(commit: Bool, value: String) {
            guard !didFinish else { return }
            didFinish = true
            focusGeneration &+= 1
            stopMonitoringOutsideClicks()
            if commit {
                onCommit(value)
            } else {
                onCancel()
            }
        }

        private func startMonitoringOutsideClicks() {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self,
                      !self.didFinish,
                      let field = self.field,
                      let editorView = self.editorView,
                      event.window === field.window
                else { return event }

                guard ClipboardCardTitleEditorClickRouting.isOutsideEditor(
                    windowPoint: event.locationInWindow,
                    editorView: editorView
                ) else { return event }

                field.window?.makeFirstResponder(nil)
                return event
            }
        }

        func stopMonitoringOutsideClicks() {
            guard let outsideClickMonitor else { return }
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

enum ClipboardCardTitleEditorClickRouting {
    static func isOutsideEditor(windowPoint: NSPoint, editorView: NSView) -> Bool {
        let point = editorView.convert(windowPoint, from: nil)
        return !editorView.bounds.contains(point)
    }
}

/// 标题输入框与确认按钮属于同一个 AppKit 控件树，因此确认按钮不依赖
/// SwiftUI 在 mouseDown 和 mouseUp 之间保留同一棵虚拟卡片子树。
private final class ClipboardCardTitleEditorView: NSView {
    let field = NSTextField()
    let saveButton = NSButton()
    var onMoveToWindow: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.isBordered = false
        saveButton.imagePosition = .imageOnly
        saveButton.imageScaling = .scaleProportionallyDown
        saveButton.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "保存名称"
        )
        saveButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        saveButton.focusRingType = .none
        saveButton.toolTip = "保存名称"

        addSubview(field)
        addSubview(saveButton)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 18),
            saveButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: max(80, field.intrinsicContentSize.width + 22),
            height: max(18, field.intrinsicContentSize.height)
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

/// 使用真正的 NSButton 作为卡片内操作控件。虚拟列表的原生单击识别器
/// 可以据此区分"点卡片"和"点按钮"，避免选中刷新抢走按钮的 mouseUp。
private struct ClipboardCardActionButton: NSViewRepresentable {
    let systemName: String
    let help: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: systemName, accessibilityDescription: help) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        button.focusRingType = .none
        button.toolTip = help
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: systemName, accessibilityDescription: help)
        button.toolTip = help
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

private struct ClipboardSourceAppIcon: View {
    let appName: String?
    let fallbackSymbol: String

    @State private var icon: NSImage?

    var body: some View {
        iconContent
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                .strokeBorder(DS.whiteOpacity(0.28), lineWidth: 1)
        }
        .task(id: appName) {
            await loadIcon()
        }
        .help(appName ?? "未知来源")
        .accessibilityLabel(accessibilityName)
    }

    @ViewBuilder
    private var iconContent: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: DS.font15, weight: .semibold))
                .foregroundStyle(DS.whiteOpacity(0.88))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.whiteOpacity(0.16))
        }
    }

    private var accessibilityName: String {
        appName.map { "来源应用：\($0)" } ?? "未知来源应用"
    }

    private func loadIcon() async {
        icon = AppIconProvider.shared.cached(name: appName)
        if icon == nil {
            icon = await AppIconProvider.shared.icon(forName: appName)
        }
    }
}
