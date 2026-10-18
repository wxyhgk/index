import AppKit
import SwiftUI

extension Notification.Name {
    static let agentPanelWillShow = Notification.Name("agentPanelWillShow")
}

// MARK: - Agent 对话面板
//
// ⌘⇧A 调出浮动面板，用户输入问题，agent 自动调工具并返回回答。
// 消息列表展示对话历史 + 工具调用卡片（状态图标 + 可折叠）。

// MARK: - 消息模型

struct AgentMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var text: String
    var toolCalls: [ToolCallInfo] = []

    enum Role: Equatable {
        case user
        case assistant
    }

    struct ToolCallInfo: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let args: String
        var status: Status = .running
        var result: String? = nil

        enum Status: Equatable {
            case running
            case done
            case error
        }
    }
}

// MARK: - 面板

@MainActor
final class AgentPanel: FloatingPanel {

    private let monitors = PanelEventMonitors()

    init() {
        let hosting = NSHostingController(rootView: AgentChatView())
        super.init(
            spec: PanelSpec.agent(size: AgentUIMetrics.panelDefaultSize),
            contentViewController: hosting
        )
        setContentSize(AgentUIMetrics.panelDefaultSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if let screen = NSScreen.main {
            let size = frame.size
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        // 不能调用 NSApp.activate：台前调度会把图库等所有 Index 窗口一起带出来。
        presentWithoutActivating()
        installMonitor()
        // 每次打开都是新对话
        NotificationCenter.default.post(name: .agentPanelWillShow, object: nil)
        // 聚焦输入框（延迟等 SwiftUI 完成布局）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let textView = Self.findTextField(in: self.contentView) else { return }
            self.makeFirstResponder(textView)
        }
    }

    static func findTextField(in view: NSView?) -> NSTextView? {
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
        monitors.installLocalKey { [weak self] event in
            guard let self else { return event }
            if event.keyCode == KeyCode.escape {
                self.close()
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        monitors.removeAll()
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

    /// 让 Agent 面板重新成为 key window 并聚焦输入框（剪贴板面板关闭后调用）。
    func refocus() {
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            guard let panel, let textView = AgentPanel.findTextField(in: panel.contentView) else { return }
            panel.makeFirstResponder(textView)
        }
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
                    LazyVStack(spacing: DS.s3) {
                        ForEach(viewModel.messages) { message in
                            AgentMessageBubble(presentation: AgentMessagePresentation(message: message))
                                .id(message.id)
                        }
                        if viewModel.isThinking {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                    }
                    .padding(DS.s4)
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
            HStack(spacing: DS.s2) {
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
            .padding(DS.s3)
        }
        .frame(
            minWidth: AgentUIMetrics.chatMinimumSize.width,
            minHeight: AgentUIMetrics.chatMinimumSize.height
        )
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 思考动画（三点跳动）

struct ThinkingIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(DS.dotInactive)
                            .frame(width: 5, height: 5)
                            .offset(y: dotOffset(index: i, t: t))
                    }
                }
                .frame(height: 12)
                Text("Agent 思考中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dotOffset(index: Int, t: TimeInterval) -> CGFloat {
        let phase = (t * 2 + Double(index) * 0.3).truncatingRemainder(dividingBy: 1.0)
        return -4 * sin(phase * .pi)
    }
}

// MARK: - ViewModel

@MainActor
final class AgentChatViewModel: ObservableObject {

    @Published var messages: [AgentMessage] = []
    @Published var input = ""
    @Published var isThinking = false

    private var conversationID: Int64?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reset),
            name: .agentPanelWillShow,
            object: nil
        )
    }

    @objc private func reset() {
        messages = []
        input = ""
        isThinking = false
        // 每次打开都是新对话
        do {
            let name = AgentConversationStore.shared.makeName()
            conversationID = try AgentConversationStore.shared.createConversation(name: name)
        } catch {
            NSLog("[Agent] 创建对话失败: \(error)")
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        input = ""
        messages.append(AgentMessage(role: .user, text: text))
        // 立即加一个空的 assistant 消息，工具调用会实时填进去
        messages.append(AgentMessage(role: .assistant, text: ""))
        isThinking = true

        // 保存 user 消息
        saveMessage(role: "user", text: text, toolCalls: nil)

        // 构建历史（最近 10 轮 user/assistant 文本对）
        let recent = messages.dropLast(2).suffix(20) // 最近 20 条 = 10 轮
        let historyToSend = recent.compactMap { msg -> [String: Any]? in
            switch msg.role {
            case .user: return ["role": "user", "content": msg.text]
            case .assistant:
                guard !msg.text.isEmpty else { return nil }
                return ["role": "assistant", "content": msg.text]
            }
        }

        Task {
            let response = await AgentPlugin.shared.ask(text, history: historyToSend) { [weak self] event in
                Task { @MainActor in
                    self?.handleEvent(event)
                }
            }
            // 最终回答
            if let lastIdx = self.messages.lastIndex(where: { $0.role == .assistant }) {
                self.messages[lastIdx].text = response
                // 保存 assistant 消息（含工具调用）
                self.saveMessage(role: "assistant", text: response, toolCalls: self.messages[lastIdx].toolCalls)
            }
            self.isThinking = false
        }
    }

    private func handleEvent(_ event: AgentEvent) {
        guard let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        switch event {
        case let .toolCallStarted(name, args):
            messages[lastIdx].toolCalls.append(
                AgentMessage.ToolCallInfo(name: name, args: args)
            )
        case let .toolCallFinished(name, result):
            // 找到最后一个同名 running 的调用
            if let idx = messages[lastIdx].toolCalls.lastIndex(where: { $0.name == name && $0.status == .running }) {
                messages[lastIdx].toolCalls[idx].status = .done
                messages[lastIdx].toolCalls[idx].result = result
            }
        case let .response(text):
            messages[lastIdx].text = text
        }
    }

    // MARK: - 持久化

    private func saveMessage(role: String, text: String, toolCalls: [AgentMessage.ToolCallInfo]?) {
        guard let conversationID else { return }
        let json = AgentToolCallCodec.encode(toolCalls ?? [])
        do {
            try AgentConversationStore.shared.appendMessage(
                conversationID: conversationID,
                role: role,
                text: text,
                toolCallsJSON: json
            )
        } catch {
            NSLog("[Agent] 保存消息失败: \(error)")
        }
    }

}
