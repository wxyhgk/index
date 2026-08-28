import SwiftUI

// MARK: - AI 对话历史（内容库子 tab）
//
// 左侧：对话列表（按时间倒序，显示会话名 + 首条消息摘要 + 消息数）
// 右侧：对话详情（Markdown 渲染 + 工具调用卡片，复用 AgentPanel 组件）

/// AI 历史页的窗口级会话。页面在子 Tab 间切换时会被 SwiftUI 移出视图树，
/// 数据不能跟着临时 View 的 @State 一起归零，否则每次回来都会先画空态再加载。
@MainActor
final class AgentConversationListSession: ObservableObject {
    static let shared = AgentConversationListSession()

    @Published private(set) var conversations: [AgentConversationRecord] = []
    @Published private(set) var selectedID: Int64?
    @Published private(set) var selectedMessages: [AgentMessageRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false

    private var refreshGeneration = 0

    func loadIfNeeded() async {
        guard !hasLoaded, !isRefreshing else { return }
        await refresh()
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        let loaded = await Task.detached(priority: .userInitiated) {
            try? AgentConversationStore.shared.listConversations(limit: 100)
        }.value ?? []
        guard generation == refreshGeneration else { return }

        conversations = loaded
        hasLoaded = true
        isRefreshing = false
        if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            selectedMessages = []
        }
    }

    func select(_ conversation: AgentConversationRecord) {
        selectedID = conversation.id
        guard let id = conversation.id else {
            selectedMessages = []
            return
        }
        do {
            selectedMessages = try AgentConversationStore.shared.messages(for: id)
        } catch {
            NSLog("[Agent] 加载对话消息失败: \(error)")
            selectedMessages = []
        }
    }

    func delete(_ conversation: AgentConversationRecord) async {
        guard let id = conversation.id else { return }
        do {
            try AgentConversationStore.shared.deleteConversation(id: id)
            if selectedID == id {
                selectedID = nil
                selectedMessages = []
            }
            await refresh()
        } catch {
            NSLog("[Agent] 删除对话失败: \(error)")
        }
    }
}

struct AgentConversationListView: View {

    @StateObject private var session: AgentConversationListSession

    @MainActor
    init(session: AgentConversationListSession? = nil) {
        _session = StateObject(wrappedValue: session ?? .shared)
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            conversationList
                .frame(width: AgentUIMetrics.conversationListWidth)

            conversationDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(DS.s3)
        .task { await session.loadIfNeeded() }
    }

    // MARK: - 对话列表

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 页头
            HStack(spacing: DS.s2) {
                Text("AI 对话")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await session.refresh() }
                } label: {
                    if session.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(ShellIconButtonStyle(side: 28))
                .disabled(session.isRefreshing)
                .help("刷新对话")
            }
            .padding(.horizontal, DS.s3)
            .padding(.top, DS.s3)
            .padding(.bottom, DS.s3)

            if !session.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.conversations.isEmpty {
                ContentUnavailableView(
                    "暂无对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("用 ⌘⇧A 打开 Agent 面板开始对话")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.s1) {
                        ForEach(session.conversations) { conv in
                            ConversationRow(
                                conversation: conv,
                                isSelected: conv.id == session.selectedID,
                                onDelete: { Task { await session.delete(conv) } }
                            ) {
                                session.select(conv)
                            }
                        }
                    }
                    .padding(.horizontal, DS.s2)
                    .padding(.bottom, DS.s3)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(DS.insetSurface, in: RoundedRectangle(
            cornerRadius: DS.radiusPanel,
            style: .continuous
        ))
    }

    // MARK: - 对话详情

    @ViewBuilder
    private var conversationDetail: some View {
        if session.selectedID != nil, !session.selectedMessages.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.s3) {
                    ForEach(session.selectedMessages) { record in
                        if let presentation = AgentMessagePresentation(record: record) {
                            AgentMessageBubble(presentation: presentation)
                        }
                    }
                }
                .padding(.horizontal, DS.s5)
                .padding(.vertical, DS.s4)
            }
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView(
                "选择一条对话",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("从左侧列表选择要查看的对话")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

// MARK: - 对话列表行

private struct ConversationRow: View {
    let conversation: AgentConversationRecord
    let isSelected: Bool
    let onDelete: () -> Void
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.s2) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: DS.font13, weight: .medium))
                    .foregroundStyle(isSelected ? DS.accent : Color.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.updatedAt.formatted(.dateTime.month().day()) + " 的对话")
                        .font(.system(size: DS.font13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: DS.s1) {
                        Text(conversation.updatedAt.formatted(.dateTime.hour().minute()))
                        Text("·")
                        Text(conversation.name)
                            .monospaced()
                    }
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.s2)
            .background(
                isSelected ? DS.accentFillSelected : (isHovering ? DS.hoverFill : .clear),
                in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
