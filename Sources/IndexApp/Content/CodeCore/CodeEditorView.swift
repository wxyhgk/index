import SwiftUI

/// 主窗口内的代码编辑器。与 Markdown 编辑器一样由 GalleryWindowMode 承载，
/// 不创建独立窗口；正文和语言共用一次防抖自动保存。
struct CodeEditorModeView: View {
    let shot: Shot

    @ObservedObject private var store: ShotStore
    @EnvironmentObject private var windowMode: GalleryWindowMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var source: String
    @State private var language: String?
    @State private var savedSource: String
    @State private var savedLanguage: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    @MainActor
    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self._store = ObservedObject(wrappedValue: store)
        let content = store.codeContent(for: shot)
        let initialSource = content?.text ?? ""
        let initialLanguage = ContentCode.normalizedLanguage(content?.language)
        self._source = State(initialValue: initialSource)
        self._language = State(initialValue: initialLanguage)
        self._savedSource = State(initialValue: initialSource)
        self._savedLanguage = State(initialValue: initialLanguage)
    }

    var body: some View {
        ZStack {
            Color(nsColor: DS.windowBase).ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                Divider()
                CodeEditorSurface(text: $source)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 620)
        .onChange(of: source) { _, newSource in
            if language == nil {
                language = CodeLanguageDetector.detect(newSource)
            }
            scheduleSave()
        }
        .onChange(of: language) { _, _ in scheduleSave() }
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
            languagePicker
            saveStatus

            Button("保存") { persist() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges)
        }
        .padding(.leading, DS.Shell.trafficLightInset)
        .padding(.trailing, DS.Shell.windowMargin)
        .frame(height: 48)
    }

    private var languagePicker: some View {
        Picker("语言", selection: $language) {
            Text("自动检测").tag(Optional<String>.none)
            ForEach(languageChoices) { choice in
                Text(choice.displayName).tag(Optional(choice.id))
            }
        }
        .labelsHidden()
        .frame(width: 150)
        .help("代码语言")
    }

    private var languageChoices: [CodeLanguage] {
        guard let language,
              !CodeLanguage.builtins.contains(where: { $0.id == language })
        else { return CodeLanguage.builtins }
        return [CodeLanguage(id: language, displayName: language)] + CodeLanguage.builtins
    }

    @ViewBuilder
    private var saveStatus: some View {
        if let saveError {
            Text(saveError).foregroundStyle(.red).help(saveError)
        } else {
            Text(hasChanges ? "保存中…" : "已保存")
                .foregroundStyle(.secondary)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hasChanges)
        }
    }

    private var hasChanges: Bool {
        source != savedSource || ContentCode.normalizedLanguage(language) != savedLanguage
    }

    private func scheduleSave() {
        saveError = nil
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = nil
        guard hasChanges, let shotID = shot.id else { return }
        let normalizedLanguage = ContentCode.normalizedLanguage(language)
        do {
            try store.saveContent(
                for: shotID,
                kind: .code,
                payload: .code(source, language: normalizedLanguage),
                updateKind: false
            )
            CodePreviewCache.shared.update(text: source, language: normalizedLanguage, shotID: shotID)
            savedSource = source
            savedLanguage = normalizedLanguage
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            NSLog("[Index] 代码片段保存失败: \(error)")
        }
    }

    private func returnToGallery() {
        persist()
        store.reload()
        windowMode.returnToGallery()
    }
}
