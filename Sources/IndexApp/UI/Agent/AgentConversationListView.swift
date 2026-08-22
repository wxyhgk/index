import SwiftUI
import MarkdownUI

// MARK: - AI 对话历史（内容库子 tab）
//
// 左侧：对话列表（按时间倒序，显示会话名 + 首条消息摘要 + 消息数）
// 右侧：对话详情（Markdown 渲染 + 工具调用卡片，复用 AgentPanel 组件）

struct AgentConversationListView: View {

    @State private var conversations: [AgentConversationRecord] = []
    @State private var selectedID: Int64?
    @State private var selectedMessages: [AgentMessageRecord] = []
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：对话列表
            conversationList
                .frame(width: 260)

            Divider()

            // 右侧：对话详情
            conversationDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { refresh() }
    }

    // MARK: - 对话列表

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 页头
            HStack {
                Text("AI 对话")
                    .font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DS.font12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.s3)
            .padding(.top, DS.s4)
            .padding(.bottom, DS.s2)

            if conversations.isEmpty {
                ContentUnavailableView(
                    "暂无对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("用 ⌘⇧A 打开 Agent 面板开始对话")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(conversations) { conv in
                            ConversationRow(
                                conversation: conv,
                                isSelected: conv.id == selectedID
                            ) {
                                select(conv)
                            }
                        }
                    }
                    .padding(.horizontal, DS.s2)
                    .padding(.bottom, DS.s2)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 对话详情

    @ViewBuilder
    private var conversationDetail: some View {
        if let selectedID, !selectedMessages.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.s3) {
                    ForEach(selectedMessages) { record in
                        ConversationMessageBubble(record: record)
                    }
                }
                .padding(DS.s4)
            }
        } else {
            ContentUnavailableView(
                "选择一条对话",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("从左侧列表选择要查看的对话")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 数据

    private func refresh() {
        isRefreshing = true
        do {
            conversations = try AgentConversationStore.shared.listConversations(limit: 100)
            // 保持选中
            if let selectedID, !conversations.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                self.selectedMessages = []
            }
        } catch {
            NSLog("[Agent] 加载对话列表失败: \(error)")
        }
        isRefreshing = false
    }

    private func select(_ conv: AgentConversationRecord) {
        selectedID = conv.id
        do {
            selectedMessages = try AgentConversationStore.shared.messages(for: conv.id!)
        } catch {
            NSLog("[Agent] 加载对话消息失败: \(error)")
            selectedMessages = []
        }
    }
}

// MARK: - 对话列表行

private struct ConversationRow: View {
    let conversation: AgentConversationRecord
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.name)
                    .font(.system(size: DS.font13, weight: .medium))
                    .monospaced()
                    .lineLimit(1)
                Text(conversation.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)
            .background(
                isSelected ? DS.accentFillSelected : (isHovering ? DS.hoverFill : .clear),
                in: RoundedRectangle(cornerRadius: DS.radiusSmall)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("删除", role: .destructive) {
                if let id = conversation.id {
                    try? AgentConversationStore.shared.deleteConversation(id: id)
                }
            }
        }
    }
}

// MARK: - 对话消息气泡（复用 AgentPanel 的渲染逻辑）

private struct ConversationMessageBubble: View {
    let record: AgentMessageRecord

    var body: some View {
        switch record.role {
        case "user":
            HStack {
                Spacer()
                Text(record.text)
                    .padding(.horizontal, DS.s3)
                    .padding(.vertical, DS.s2)
                    .background(DS.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        case "assistant":
            VStack(alignment: .leading, spacing: DS.s2) {
                // 工具调用
                if let calls = parseToolCalls(), !calls.isEmpty {
                    ForEach(calls) { call in
                        ToolCallCard(call: call)
                    }
                }
                // 回答
                if !record.text.isEmpty {
                    if calls.isEmpty {
                        Markdown(record.text)
                            .markdownTheme(.gitHub)
                            .textSelection(.enabled)
                            .padding(.horizontal, DS.s3)
                            .padding(.vertical, DS.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Markdown(record.text)
                            .markdownTheme(.gitHub)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private var calls: [AgentMessage.ToolCallInfo] {
        parseToolCalls() ?? []
    }

    private func parseToolCalls() -> [AgentMessage.ToolCallInfo]? {
        guard let json = record.toolCallsJSON,
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let args = item["args"] as? String ?? ""
            let statusStr = item["status"] as? String ?? "done"
            let result = item["result"] as? String
            let status: AgentMessage.ToolCallInfo.Status
            switch statusStr {
            case "running": status = .running
            case "error": status = .error
            default: status = .done
            }
            return AgentMessage.ToolCallInfo(name: name, args: args, status: status, result: result)
        }
    }
}
