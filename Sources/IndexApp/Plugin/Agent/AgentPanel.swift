import AppKit
import SwiftUI

// MARK: - Agent 对话面板
//
// ⌘⇧A 调出浮动面板，用户输入问题，agent 自动调工具并返回回答。
// 消息列表展示对话历史 + 工具调用过程（灰色小字）。

// MARK: - 消息模型

struct AgentMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let text: String
    var toolCalls: [ToolCallInfo]?

    enum Role: Equatable {
        case user
        case assistant
        case tool
    }

    struct ToolCallInfo: Equatable {
        let name: String
        let args: String
    }
}

// MARK: - 面板

@MainActor
final class AgentPanel: NSPanel {

    private var localMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Agent"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setContentSize(NSSize(width: 640, height: 480))

        let view = AgentChatView()
        let hosting = NSHostingController(rootView: view)
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        if let screen = NSScreen.main {
            let size = frame.size
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        installMonitor()
        // 聚焦输入框
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = Self.findTextField(in: self.contentView) else { return }
            self.makeFirstResponder(textView)
        }
    }

    private static func findTextField(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }

    override func close() {
        removeMonitor()
        orderOut(nil)
    }

    private func installMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 { // Esc
                    self.close()
                    return nil
                }
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

// MARK: - 协调器

@MainActor
final class AgentCoordinator {

    static let shared = AgentCoordinator()

    private var panel: AgentPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show()
    }

    func show() {
        if panel == nil {
            panel = AgentPanel()
        }
        panel?.show()
    }

    func close() {
        panel?.close()
    }
}

// MARK: - SwiftUI 对话视图

struct AgentChatView: View {

    @StateObject private var viewModel = AgentChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if viewModel.isThinking {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Agent 思考中…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let lastID = viewModel.messages.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        } else if viewModel.isThinking {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 输入区
            HStack(spacing: 8) {
                TextField("输入问题…", text: $viewModel.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit {
                        viewModel.send()
                    }

                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.input.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
            }
            .padding(12)
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: AgentMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DS.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                // 工具调用过程
                if let calls = message.toolCalls, !calls.isEmpty {
                    ForEach(calls.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape")
                                .font(.caption2)
                            Text("\(calls[i].name)(\(calls[i].args))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Divider()
                        .padding(.vertical, 2)
                }
                Text(message.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))

        case .tool:
            HStack(spacing: 4) {
                Image(systemName: "wrench")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AgentChatViewModel: ObservableObject {

    @Published var messages: [AgentMessage] = []
    @Published var input = ""
    @Published var isThinking = false

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        input = ""
        messages.append(AgentMessage(role: .user, text: text, toolCalls: nil))
        isThinking = true

        Task {
            let response = await AgentPlugin.shared.ask(text)
            self.messages.append(AgentMessage(role: .assistant, text: response, toolCalls: nil))
            self.isThinking = false
        }
    }
}
