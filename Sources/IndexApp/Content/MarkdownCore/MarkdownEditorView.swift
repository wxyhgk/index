import SwiftUI

// MARK: - 主窗口 Markdown 编辑器
//
// Markdown 和标注、设置共用 GalleryWindowMode 的单窗口模式切换，不再创建第二个
// NSWindow。编辑器复用 MarkdownEditorSurface，保存仍写回 contentMarkdown。

struct MarkdownEditorModeView: View {
    let shot: Shot

    @ObservedObject private var store: ShotStore
    @EnvironmentObject private var windowMode: GalleryWindowMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var source: String
    @State private var savedSource: String
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self._store = ObservedObject(wrappedValue: store)
        let initialSource = store.markdownSource(for: shot) ?? MarkdownGenerator.generate(for: shot)
        self._source = State(initialValue: initialSource)
        self._savedSource = State(initialValue: initialSource)
    }

    var body: some View {
        ZStack {
            Color(nsColor: DS.windowBase).ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                Divider()
                MarkdownEditorSurface(text: $source)
                    .padding(DS.s3)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 620)
        .onChange(of: source) { _, _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            persist()
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.s3) {
            Button(action: returnToGallery) {
                Label("图库", systemImage: "chevron.left")
                    .font(.system(size: DS.font13, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Text(shot.primaryDisplayName)
                .font(.system(size: DS.font15, weight: .semibold))
                .lineLimit(1)

            Spacer()

            saveStatus

            Button("保存") { persist() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(source == savedSource)
        }
        .padding(.leading, DS.Shell.trafficLightInset)
        .padding(.trailing, DS.Shell.windowMargin)
        .frame(height: 48)
    }

    @ViewBuilder
    private var saveStatus: some View {
        if let saveError {
            Text(saveError)
                .foregroundStyle(.red)
                .help(saveError)
        } else {
            Text(source == savedSource ? "已保存" : "保存中…")
                .foregroundStyle(.secondary)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: source == savedSource)
        }
    }

    private func scheduleSave() {
        saveError = nil
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = nil
        guard source != savedSource, let shotID = shot.id else { return }
        do {
            try store.saveContent(
                for: shotID,
                kind: .markdown,
                payload: .markdown(source),
                updateKind: false
            )
            savedSource = source
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            NSLog("[Index] Markdown 保存失败: \(error)")
        }
    }

    private func returnToGallery() {
        persist()
        // 使用仓储当前的 activeListQuery 刷新，不重置用户的搜索或筛选。
        store.reload()
        windowMode.returnToGallery()
    }
}
