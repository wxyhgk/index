import SwiftUI
import AppKit

// MARK: - 侧边栏
//
// 图库左栏：资料库 / 分类 / 标签 / 应用四组筛选入口（带计数与真实 App 图标），
// 标签的重命名与删除也在这里。附带侧边栏专用的 App 图标视图与其缓存。

struct GallerySidebar: View {

    @ObservedObject private var store = ShotStore.shared

    @State private var categories: [(name: String, count: Int)] = []
    @State private var tags: [(name: String, count: Int)] = []
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []
    @State private var total = 0
    /// 应用组超过 8 个时默认只显示前 5 个，点「显示全部」再展开。
    @State private var appsExpanded = false
    /// 右键「重命名」弹窗的目标标签，非 nil 即弹窗。
    @State private var renamingTag: String?
    @State private var renameText = ""
    /// 右键「删除」确认的目标标签。
    @State private var deletingTag: String?

    /// 应用组是否需要折叠（8 个以内没必要）。
    private var appsCollapsible: Bool { apps.count > 8 }

    private var visibleApps: [(name: String, bundleID: String?, count: Int)] {
        appsCollapsible && !appsExpanded ? Array(apps.prefix(5)) : apps
    }

    var body: some View {
        List(selection: filterBinding) {
            Section("资料库") {
                Label("全部截图", systemImage: "square.grid.2x2")
                    .badge(total)
                    .tag(ShotStore.GalleryFilter.all)
                Label {
                    Text("收藏")
                } icon: {
                    Image(systemName: "star")
                        .foregroundStyle(.yellow)
                }
                .badge(store.favoriteCount())
                .tag(ShotStore.GalleryFilter.favorites)
            }

            if !categories.isEmpty {
                Section("分类") {
                    ForEach(categories, id: \.name) { category in
                        HStack(spacing: DS.s2) {
                            Circle()
                                .fill(DS.categoryColor(category.name))
                                .frame(width: 8, height: 8)
                            Label(category.name, systemImage: icon(forCategory: category.name))
                        }
                        .badge(category.count)
                        .tag(ShotStore.GalleryFilter.category(category.name))
                    }
                }
            }

            // 用户自己的组织方式排在自动分类后面；一个标签都没有时整区不出现。
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.name) { tag in
                        Label(tag.name, systemImage: "tag")
                            .badge(tag.count)
                            .tag(ShotStore.GalleryFilter.tag(tag.name))
                            .contextMenu {
                                Button("重命名…") {
                                    renameText = tag.name
                                    renamingTag = tag.name
                                }
                                Button("删除标签…", role: .destructive) {
                                    deletingTag = tag.name
                                }
                            }
                    }
                }
            }

            if !apps.isEmpty {
                Section("应用") {
                    ForEach(visibleApps, id: \.name) { app in
                        HStack(spacing: DS.s2) {
                            AppIconView(bundleID: app.bundleID)
                            Text(app.name).lineLimit(1)
                        }
                        .badge(app.count)
                        .tag(ShotStore.GalleryFilter.app(app.name))
                    }
                    if appsCollapsible {
                        Button {
                            withAnimation { appsExpanded.toggle() }
                        } label: {
                            Label(
                                appsExpanded ? "收起" : "显示全部（\(apps.count) 个）",
                                systemImage: appsExpanded ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 聚合是几条小查询。标签的增删改不改变 shots 的数量，
        // 只跟数据量刷新会漏 —— 改订 store 的变更通知，每次都重查。
        // 通知发在 reload() 写库**之后**，这里直接读库拿到的已是新值。
        .task { refresh() }
        .onReceive(store.objectWillChange) { _ in refresh() }
        .alert(
            "重命名标签",
            isPresented: Binding(
                get: { renamingTag != nil },
                set: { if !$0 { renamingTag = nil } }
            ),
            presenting: renamingTag
        ) { tag in
            TextField("标签名", text: $renameText)
            Button("重命名") { store.renameTag(tag, to: renameText) }
            Button("取消", role: .cancel) {}
        } message: { tag in
            Text("所有打了「\(tag)」的截图都会改用新名字。")
        }
        .alert(
            "删除标签「\(deletingTag ?? "")」？",
            isPresented: Binding(
                get: { deletingTag != nil },
                set: { if !$0 { deletingTag = nil } }
            ),
            presenting: deletingTag
        ) { tag in
            Button("删除", role: .destructive) { store.deleteTag(tag) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只移除标签本身，截图不会被删除。")
        }
    }

    /// List 的 selection 是可选的，而筛选永远有值（默认「全部」）—— 在这里桥一下。
    private var filterBinding: Binding<ShotStore.GalleryFilter?> {
        Binding(
            get: { store.filter },
            set: { newValue in
                store.filter = newValue ?? .all
                store.reload()
            }
        )
    }

    private func refresh() {
        total = store.totalCount
        categories = store.categories()
        tags = store.allTags()
        apps = store.apps()
    }

    private func icon(forCategory name: String) -> String {
        switch name {
        case "代码": return "chevron.left.forwardslash.chevron.right"
        case "浏览器": return "globe"
        case "聊天": return "bubble.left.and.bubble.right"
        case "设计": return "paintpalette"
        case "终端": return "terminal"
        case "文档": return "doc.text"
        case "笔记": return "note.text"
        case "影音": return "play.rectangle"
        case "效率": return "checklist"
        default: return "tag"
        }
    }
}

/// 侧边栏里的真实 App 图标。按 bundleID 解析一次后缓存。
private struct AppIconView: View {
    let bundleID: String?

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .task(id: bundleID) {
            icon = AppIconCache.shared.icon(for: bundleID)
        }
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cache[bundleID] = icon
        return icon
    }
}
