import SwiftUI

// MARK: - 应用 destination

@MainActor
final class AppsNavigationState: ObservableObject {
    static let shared = AppsNavigationState()
    @Published var selectedAppID: String?
    var isDrilled: Bool { selectedAppID != nil }
    private init() {}
}

enum AppsOverviewSort: String, CaseIterable {
    case captureCount
    case recent
    case name

    var title: String {
        switch self {
        case .captureCount: return "按截图数量"
        case .recent: return "按最近使用"
        case .name: return "按名称"
        }
    }
}

/// 应用首页满宽展示来源聚合；钻入后在自己的工作区中装配网格与详情栏。
struct AppsDestination: GalleryDestination {
    static let destinationID = "destination.apps"

    let id = Self.destinationID
    let title = "应用"
    let symbol = "square.stack.3d.up"
    let order = 100

    func content() -> AnyView { AnyView(AppsContent()) }
    func inspector() -> AnyView? { nil }
}

private struct AppsContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel

    init(store: ShotStore = .shared, viewModel: GalleryViewModel? = nil) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("galleryInspectorShown") private var showInspector = true
    @AppStorage("appsOverviewSort") private var overviewSort = AppsOverviewSort.captureCount
    @ObservedObject private var navigation = AppsNavigationState.shared
    @State private var apps: [CapturedAppSummary] = []

    private let featuredColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 360), spacing: DS.s3)
    ]
    private let compactColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 280), spacing: DS.s3)
    ]

    var body: some View {
        Group {
            if let app = drilledApp {
                drilledWorkspace(app)
            } else {
                overview
            }
        }
        .task { reload() }
        .onReceive(store.libraryDidChangePublisher) { reload() }
        .onDisappear {
            clearFilterIfDrilled()
            navigation.selectedAppID = nil
        }
    }

    // MARK: 首页

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewHeader
            if matchingApps.isEmpty {
                appEmptyState
            } else {
                overviewScroll
            }
        }
        .floatingPanel()
    }

    private var overviewHeader: some View {
        HStack(alignment: .top, spacing: DS.s4) {
            VStack(alignment: .leading, spacing: DS.s1) {
                Text("应用")
                    .font(.largeTitle.weight(.bold))
                Text("\(matchingApps.count) 个应用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.s3)

            Menu {
                Picker("应用排序", selection: $overviewSort) {
                    ForEach(AppsOverviewSort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(overviewSort.title, systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.button)
            .fixedSize()
            .help("更改全部应用的排序")
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s5)
        .padding(.bottom, DS.s3)
    }

    private var overviewScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.s5) {
                if searchQuery.isEmpty {
                    appSection(title: "最近使用", apps: recentApps, featured: true)
                    if !frequentApps.isEmpty {
                        appSection(title: "常用应用", apps: frequentApps, featured: false)
                    }
                }
                appSection(
                    title: searchQuery.isEmpty ? "全部应用" : "匹配的应用",
                    apps: sortedAllApps,
                    featured: false
                )
            }
            .padding(.horizontal, DS.s5)
            .padding(.bottom, DS.s5)
        }
        .scrollContentBackground(.hidden)
    }

    private func appSection(
        title: String,
        apps: [CapturedAppSummary],
        featured: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            Text(title)
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: featured ? featuredColumns : compactColumns, spacing: DS.s3) {
                ForEach(apps) { app in
                    if featured {
                        FeaturedAppCard(app: app, store: store) { open(app) }
                    } else {
                        CompactAppCard(app: app) { open(app) }
                    }
                }
            }
        }
    }

    private var appEmptyState: some View {
        ContentUnavailableView {
            Label(
                searchQuery.isEmpty ? "还没有应用截图" : "没有匹配的应用",
                systemImage: searchQuery.isEmpty ? "square.stack.3d.up" : "magnifyingglass"
            )
        } description: {
            Text(searchQuery.isEmpty ? "截图后，来源应用会自动出现在这里" : "换个应用名称或清空搜索词")
        } actions: {
            if !searchQuery.isEmpty {
                Button("清除搜索") { viewModel.searchText = "" }
            } else {
                Button("开始截图") { CaptureCoordinator.shared.begin() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 二级 App 截图页

    private func drilledWorkspace(_ app: CapturedAppSummary) -> some View {
        HStack(alignment: .top, spacing: DS.Shell.panelGap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.s3) {
                    Button { closeDrill() } label: {
                        Label("应用", systemImage: "chevron.left")
                            .font(.system(size: DS.font13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    InspectorAppIcon(bundleID: app.bundleID, side: 34)
                    VStack(alignment: .leading, spacing: DS.s1 / 2) {
                        Text(app.name)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        Text("\(viewModel.displayShots.count) 个项目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: DS.s2)
                }
                .padding(.horizontal, DS.s5)
                .padding(.top, DS.s4)
                .padding(.bottom, DS.s2)

                GalleryGrid(store: store, viewModel: viewModel, chrome: .libraryPanel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingPanel()

            if showInspector {
                GalleryInspectorPanel(isPresented: $showInspector, store: store, viewModel: viewModel)
                    .frame(width: DS.Shell.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard(reduced: reduceMotion), value: showInspector)
    }

    // MARK: 派生集合

    private var searchQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingApps: [CapturedAppSummary] {
        guard !searchQuery.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
                || ($0.bundleID?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var recentApps: [CapturedAppSummary] {
        Array(matchingApps.sorted(by: recentlyCaptured).prefix(5))
    }

    private var frequentApps: [CapturedAppSummary] {
        let recentIDs = Set(recentApps.map(\.id))
        return Array(
            matchingApps
                .filter { !recentIDs.contains($0.id) }
                .sorted(by: mostCaptured)
                .prefix(7)
        )
    }

    private var sortedAllApps: [CapturedAppSummary] {
        switch overviewSort {
        case .captureCount: return matchingApps.sorted(by: mostCaptured)
        case .recent: return matchingApps.sorted(by: recentlyCaptured)
        case .name:
            return matchingApps.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func mostCaptured(_ lhs: CapturedAppSummary, _ rhs: CapturedAppSummary) -> Bool {
        if lhs.captureCount != rhs.captureCount { return lhs.captureCount > rhs.captureCount }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func recentlyCaptured(_ lhs: CapturedAppSummary, _ rhs: CapturedAppSummary) -> Bool {
        if lhs.lastCapturedAt != rhs.lastCapturedAt { return lhs.lastCapturedAt > rhs.lastCapturedAt }
        return mostCaptured(lhs, rhs)
    }

    private var drilledApp: CapturedAppSummary? {
        navigation.selectedAppID.flatMap { id in apps.first { $0.id == id } }
    }

    // MARK: 导航与数据

    private func open(_ app: CapturedAppSummary) {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            viewModel.clearSemanticResults()
            // 首页搜索筛的是 App；进入之后应显示该 App 的全部截图，而不是继续拿
            // App 名称或 bundleID 当截图全文关键词再筛一遍。
            viewModel.searchText = ""
            viewModel.filter = .app(app.identity)
            viewModel.reload()
            navigation.selectedAppID = app.id
        }
    }

    private func closeDrill() {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            clearFilterIfDrilled()
            navigation.selectedAppID = nil
        }
    }

    private func reload() {
        apps = store.capturedApps()
        if navigation.selectedAppID != nil, drilledApp == nil {
            clearFilterIfDrilled()
            navigation.selectedAppID = nil
        }
    }

    private func clearFilterIfDrilled() {
        guard case .app = viewModel.filter else { return }
        viewModel.filter = .all
        viewModel.reload()
    }
}

private struct FeaturedAppCard: View {
    let app: CapturedAppSummary
    let store: ShotStore
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.s3) {
                AppCardIdentity(app: app, iconSide: 34)
                HStack(spacing: DS.s2) {
                    ForEach(0..<3, id: \.self) { index in
                        if app.previews.indices.contains(index) {
                            let shot = app.previews[index]
                            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                                .frame(maxWidth: .infinity)
                                .frame(height: 70)
                                .background(DS.insetSurface)
                                .clipShape(previewShape)
                        } else {
                            previewShape
                                .fill(DS.insetSurface)
                                .frame(maxWidth: .infinity)
                                .frame(height: 70)
                        }
                    }
                }
            }
            .padding(DS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panelFill(.resting), in: cardShape)
            .overlay {
                let r = DS.rim(hovering ? .raised : .content, scheme, hovering: hovering)
                cardShape.strokeBorder(r.gradient, lineWidth: r.lineWidth)
                    .blendMode(reduceTransparency ? .normal : r.blend)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? DS.Lift.hoverScale : 1)
        .offset(y: hovering && !reduceMotion ? DS.Lift.hoverY : 0)
        .shadow(
            color: hoverShadow.color,
            radius: hoverShadow.radius,
            y: hoverShadow.y
        )
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityLabel("\(app.name)，\(app.captureCount) 张截图")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }
    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
    }
    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, hovering else { return .none }
        return DS.shadow(.raised, scheme)
    }
}

private struct CompactAppCard: View {
    let app: CapturedAppSummary
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            AppCardIdentity(app: app, iconSide: 32)
                .padding(DS.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.panelFill(.resting), in: cardShape)
                .overlay {
                    let r = DS.rim(hovering ? .raised : .content, scheme, hovering: hovering)
                    cardShape.strokeBorder(r.gradient, lineWidth: r.lineWidth)
                        .blendMode(reduceTransparency ? .normal : r.blend)
                        .allowsHitTesting(false)
                }
                .compositingGroup()
                .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? DS.Lift.hoverScale : 1)
        .offset(y: hovering && !reduceMotion ? DS.Lift.hoverY : 0)
        .shadow(
            color: hoverShadow.color,
            radius: hoverShadow.radius,
            y: hoverShadow.y
        )
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityLabel("\(app.name)，\(app.captureCount) 张截图")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }
    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, hovering else { return .none }
        return DS.shadow(.raised, scheme)
    }
}

private struct AppCardIdentity: View {
    let app: CapturedAppSummary
    let iconSide: CGFloat

    var body: some View {
        HStack(spacing: DS.s3) {
            InspectorAppIcon(bundleID: app.bundleID, side: iconSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: DS.font13, weight: .medium))
                    .lineLimit(1)
                Text("\(app.captureCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}
