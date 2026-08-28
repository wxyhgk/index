import AppKit
import MarkdownUI
import SwiftUI

/// Agent UI 的组件级规格。只收口窗口 / 面板边界等具有产品语义的尺寸；
/// 动画相位、历史条数等算法参数仍留在各自逻辑旁边。
enum AgentUIMetrics {
    static let panelDefaultSize = NSSize(width: 640, height: 480)
    static let chatMinimumSize = CGSize(width: 400, height: 300)
    static let conversationListWidth: CGFloat = 248

    static let toolCardHorizontalPadding: CGFloat = 10
    static let toolCardSectionSpacing: CGFloat = 6
    static let toolCardLabelSpacing: CGFloat = 2
    static let toolCardBorderWidth: CGFloat = 0.5
}

/// 实时消息与持久化消息共用的渲染输入。存储模型、流式状态模型只负责适配，
/// SwiftUI 布局不再分别维护两套 role / Markdown / tool-call 分支。
struct AgentMessagePresentation: Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let role: Role
    let text: String
    let toolCalls: [AgentMessage.ToolCallInfo]

    init(message: AgentMessage) {
        role = message.role == .user ? .user : .assistant
        text = message.text
        toolCalls = message.toolCalls
    }

    init?(record: AgentMessageRecord) {
        switch record.role {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        text = record.text
        toolCalls = AgentToolCallCodec.decode(record.toolCallsJSON)
    }
}

enum AgentToolCallCodec {
    static func encode(_ calls: [AgentMessage.ToolCallInfo]) -> String? {
        guard !calls.isEmpty else { return nil }
        let items = calls.map { call -> [String: Any] in
            var item: [String: Any] = ["name": call.name, "args": call.args]
            switch call.status {
            case .running: item["status"] = "running"
            case .done: item["status"] = "done"
            case .error: item["status"] = "error"
            }
            if let result = call.result { item["result"] = result }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func decode(_ json: String?) -> [AgentMessage.ToolCallInfo] {
        guard let json,
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let status: AgentMessage.ToolCallInfo.Status
            switch item["status"] as? String {
            case "running": status = .running
            case "error": status = .error
            default: status = .done
            }
            return AgentMessage.ToolCallInfo(
                name: name,
                args: item["args"] as? String ?? "",
                status: status,
                result: item["result"] as? String
            )
        }
    }
}

struct AgentMessageBubble: View {
    let presentation: AgentMessagePresentation

    var body: some View {
        switch presentation.role {
        case .user:
            HStack {
                Spacer()
                Text(presentation.text)
                    .padding(.horizontal, DS.s3)
                    .padding(.vertical, DS.s2)
                    .background(DS.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusLarge))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: DS.s2) {
                ForEach(presentation.toolCalls) { call in
                    ToolCallCard(call: call)
                }

                if !presentation.text.isEmpty {
                    assistantMarkdown
                }
            }
        }
    }

    @ViewBuilder
    private var assistantMarkdown: some View {
        if presentation.toolCalls.isEmpty {
            Markdown(presentation.text)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .padding(.horizontal, DS.s3)
                .padding(.vertical, DS.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusLarge))
        } else {
            Markdown(presentation.text)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolCallCard: View {
    let call: AgentMessage.ToolCallInfo

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AgentUIMetrics.toolCardSectionSpacing) {
                statusIcon
                Text(call.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospaced()
                Spacer()
                if call.status != .running {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, AgentUIMetrics.toolCardHorizontalPadding)
            .padding(.vertical, DS.s2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard call.status != .running else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded && call.status != .running {
                VStack(alignment: .leading, spacing: AgentUIMetrics.toolCardSectionSpacing) {
                    if !call.args.isEmpty {
                        toolCallSection(title: "参数", text: call.args, lineLimit: 3)
                    }
                    if let result = call.result {
                        toolCallSection(title: "结果", text: result, lineLimit: 5)
                    }
                }
                .padding(.horizontal, AgentUIMetrics.toolCardHorizontalPadding)
                .padding(.bottom, DS.s2)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMedium)
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: AgentUIMetrics.toolCardBorderWidth
                )
        )
    }

    private func toolCallSection(title: String, text: String, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: AgentUIMetrics.toolCardLabelSpacing) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
