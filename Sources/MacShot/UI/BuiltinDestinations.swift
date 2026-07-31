import SwiftUI

// MARK: - 内建选项
//
// 目前两个：截图库、应用。后续要加（录屏、暂存、回收站…）在这里各写一个类型、
// 在 `registerBuiltins` 里加一行。

/// 截图库：网格 + 详情面板。这是默认落点。
struct LibraryDestination: GalleryDestination {

    let id = "destination.library"
    let title = "截图库"
    let symbol = "square.grid.2x2"
    let order = 0

    func badge() -> Int? {
        let count = ShotStore.shared.totalCount
        return count > 0 ? count : nil
    }

    func content() -> AnyView {
        AnyView(LibraryContent())
    }

    /// 详情面板的开关是用户偏好，所以这里恒定返回面板，由容器按偏好决定显不显示。
    func inspector() -> AnyView? {
        AnyView(GalleryInspectorPanelHost())
    }
}

/// 截图库的中间内容：页头 + 网格。
private struct LibraryContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            GalleryPageHeader()
                .padding(.horizontal, DS.s2)
            GalleryGrid()
        }
    }
}

// ============================================================
// MARK: - 应用
// ============================================================

/// 应用：先看有哪些来源 App，点一个再看它的截图。
///
/// 「那张图是在哪个软件里截的」通常是人第一个想起来的线索，所以它值一个顶层入口。
/// 做成**两级**（先 App 卡片、再截图网格）而不是侧边栏里平铺一长串应用行 ——
/// 实测一个真实库里有 17 个来源 App、多数只有一两张，平铺进侧边栏会把它撑爆，
/// 而作为一屏卡片来浏览正好。
struct AppsDestination: GalleryDestination {

    let id = "destination.apps"
    let title = "应用"
    let symbol = "square.stack.3d.up"
    let order = 100

    func content() -> AnyView {
        AnyView(AppsContent())
    }

    /// 钻进某个 App 之后才有「选中的截图」，所以详情面板照常提供。
    func inspector() -> AnyView? {
        AnyView(GalleryInspectorPanelHost())
    }
}

private struct AppsContent: View {

    @ObservedObject private var store = ShotStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 聚合查询的结果。**绝不放进 body** —— 那是每帧一条 GROUP BY。
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []

    /// 钻进了哪个 App。nil = 还在 App 列表这一级。
    @State private var drilled: String?

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: DS.s3)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            header
            if drilled == nil {
                appGrid
            } else {
                GalleryGrid()
            }
        }
        .task { reload() }
        .onReceive(store.objectWillChange) { _ in reload() }
        // 离开这个选项时把筛选放掉，否则切回「截图库」会莫名其妙只剩一个 App 的图。
        .onDisappear { clearFilterIfDrilled() }
    }

    // MARK: 头部

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s3) {
            if let drilled {
                Button {
                    withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
                        clearFilterIfDrilled()
                        self.drilled = nil
                    }
                } label: {
                    Label("应用", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Text(drilled)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
            } else {
                Text("应用")
                    .font(.largeTitle.weight(.bold))
            }

            Spacer(minLength: DS.s2)

            Text(drilled == nil ? "\(apps.count) 个应用" : "\(store.displayShots.count) 个项目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, DS.s2)
    }

    // MARK: App 卡片

    private var appGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DS.s3) {
                ForEach(apps, id: \.name) { app in
                    AppCard(name: app.name, bundleID: app.bundleID, count: app.count) {
                        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
                            store.filter = .app(app.name)
                            store.reload()
                            drilled = app.name
                        }
                    }
                }
            }
            .padding(.horizontal, DS.s2)
            .padding(.bottom, DS.s4)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: 数据

    private func reload() {
        apps = store.apps()
        // 钻进去的那个 App 可能已经没有截图了（全删了 / 被清理），退回列表。
        if let drilled, !apps.contains(where: { $0.name == drilled }) {
            clearFilterIfDrilled()
            self.drilled = nil
        }
    }

    /// 只在「确实是自己设下的 App 筛选」时才清 —— 用户可能在别处改过筛选。
    private func clearFilterIfDrilled() {
        guard case .app = store.filter else { return }
        store.filter = .all
        store.reload()
    }
}

/// 一张 App 卡片：真实图标 + 名字 + 截图数。
private struct AppCard: View {

    let name: String
    let bundleID: String?
    let count: Int
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s3) {
                InspectorAppIcon(bundleID: bundleID, side: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(count) 张")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(DS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(DS.rim(.content, scheme, hovering: hovering).gradient, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
    }

    /// 深色靠亮度阶梯、浅色靠白底 —— 与卡片/面板同一套（见 spatial-ui-spec §8）。
    private var fill: Color {
        DS.surfaceFill(hovering ? .raised : .content, scheme)
    }
}

// ============================================================

extension GalleryDestinationRegistry {

    /// 登记处。`AppDelegate` 启动时调一次。
    static func registerBuiltins(into registry: GalleryDestinationRegistry) {
        registry.register(LibraryDestination())
        registry.register(AppsDestination())
    }
}
