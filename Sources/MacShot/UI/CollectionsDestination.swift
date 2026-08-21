import SwiftUI

@MainActor
final class CollectionsNavigationState: ObservableObject {
    enum Route: Equatable {
        case favorites
        case collection(Int64)
    }

    static let shared = CollectionsNavigationState()
    @Published var route: Route?
    var isDrilled: Bool { route != nil }
    private init() {}
}

/// 星标是快速收件箱；专题收藏集是用户主动归类。两者在同一入口呈现，数据语义不混用。
struct CollectionsDestination: GalleryDestination {
    static let destinationID = "destination.collections"

    let id = Self.destinationID
    let title = "收藏"
    let symbol = "rectangle.stack.badge.star"
    let order = 25

    func badge(store: ShotStore = .shared) -> Int? {
        let count = store.collectionCount()
        return count > 0 ? count : nil
    }

    func badge() -> Int? { badge(store: .shared) }
    func content() -> AnyView { AnyView(CollectionsContent()) }
    func inspector() -> AnyView? { nil }
}

private struct CollectionsContent: View {
    @ObservedObject private var store: ShotStore
    @ObservedObject private var viewModel: GalleryViewModel
    @ObservedObject private var navigation = CollectionsNavigationState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("galleryInspectorShown") private var showInspector = true

    @State private var collections: [ShotCollectionSummary] = []
    @State private var favoritePreviews: [Shot] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var renameTarget: ShotCollectionSummary?
    @State private var renameName = ""
    @State private var deleteTarget: ShotCollectionSummary?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 340), spacing: DS.s3)
    ]

    init(store: ShotStore = .shared, viewModel: GalleryViewModel? = nil) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? (store === ShotStore.shared ? .shared : GalleryViewModel(store: store))
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    var body: some View {
        Group {
            if let route = navigation.route {
                detail(route)
            } else {
                overview
            }
        }
        .task { reload() }
        .onReceive(store.libraryDidChangePublisher) { reload() }
        .onDisappear {
            clearScopedFilter()
            navigation.route = nil
        }
        .alert("重命名收藏集", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("收藏集名称", text: $renameName)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") { commitRename() }
        }
        .confirmationDialog(
            "删除收藏集？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("删除“\(target.name)”", role: .destructive) {
                viewModel.deleteCollection(id: target.id)
                deleteTarget = nil
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只会删除专题集和归类关系，不会删除其中的截图。")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewHeader
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.s3) {
                    QuickFavoritesCard(store: store, previews: favoritePreviews) { open(.favorites) }
                    ForEach(filteredCollections) { collection in
                        CollectionCard(collection: collection, store: store) {
                            open(.collection(collection.id))
                        }
                        .contextMenu {
                            Button("重命名…") {
                                renameName = collection.name
                                renameTarget = collection
                            }
                            Divider()
                            Button("删除收藏集…", role: .destructive) {
                                deleteTarget = collection
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.s5)
                .padding(.bottom, DS.s5)
            }
            .scrollContentBackground(.hidden)
        }
        .floatingPanel()
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            HStack(alignment: .top, spacing: DS.s4) {
                VStack(alignment: .leading, spacing: DS.s1) {
                    Text("收藏")
                        .font(.largeTitle.weight(.bold))
                    Text("快速收藏 + \(collections.count) 个专题集")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(DS.Motion.micro(reduced: reduceMotion)) { creating.toggle() }
                } label: {
                    Label("新建收藏集", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if creating {
                HStack(spacing: DS.s2) {
                    TextField("例如：MR-TADF 分子", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createCollection)
                    Button("创建", action: createCollection)
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") {
                        newName = ""
                        creating = false
                        errorMessage = nil
                    }
                }
                .frame(maxWidth: 520)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s5)
        .padding(.bottom, DS.s3)
    }

    private func detail(_ route: CollectionsNavigationState.Route) -> some View {
        HStack(alignment: .top, spacing: DS.Shell.panelGap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.s3) {
                    Button { closeDetail() } label: {
                        Label("收藏", systemImage: "chevron.left")
                            .font(.system(size: DS.font13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Image(systemName: route == .favorites ? "star.fill" : "rectangle.stack.fill")
                        .font(.system(size: DS.font24, weight: .medium))
                        .foregroundStyle(route == .favorites ? Color.yellow : Color.accentColor)
                    VStack(alignment: .leading, spacing: DS.s1 / 2) {
                        Text(title(for: route))
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        Text("\(viewModel.displayShots.count) 张图片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.s5)
                .padding(.top, DS.s4)
                .padding(.bottom, DS.s2)

                GalleryGrid(
                    store: store,
                    viewModel: viewModel,
                    scope: scope(for: route),
                    chrome: .libraryPanel
                )
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

    private var filteredCollections: [ShotCollectionSummary] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collections }
        return collections.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
        }
    }

    private func open(_ route: CollectionsNavigationState.Route) {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            let scope = scope(for: route)
            scope.activate(in: viewModel)
            navigation.route = route
        }
    }

    private func closeDetail() {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            clearScopedFilter()
            navigation.route = nil
        }
    }

    private func clearScopedFilter() {
        let isFavoriteFilter = viewModel.filter == .favorites
        guard isFavoriteFilter || isCollectionFilter else { return }
        viewModel.reset()
    }

    private var isCollectionFilter: Bool {
        if case .collection = viewModel.filter { return true }
        return false
    }

    private func scope(for route: CollectionsNavigationState.Route) -> GalleryContentScope {
        switch route {
        case .favorites: return .favorites
        case .collection(let id): return .collection(id: id, title: title(for: route))
        }
    }

    private func title(for route: CollectionsNavigationState.Route) -> String {
        switch route {
        case .favorites: return "快速收藏"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? "收藏集"
        }
    }

    private func reload() {
        collections = store.collectionSummaries()
        favoritePreviews = store.favoritePreviews()
        if case .collection(let id) = navigation.route,
           !collections.contains(where: { $0.id == id }) {
            clearScopedFilter()
            navigation.route = nil
        }
    }

    private func createCollection() {
        do {
            _ = try store.createCollection(name: newName)
            newName = ""
            creating = false
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        do {
            try store.renameCollection(id: target.id, to: renameName)
            renameTarget = nil
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct QuickFavoritesCard: View {
    let store: ShotStore
    let previews: [Shot]
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        CollectionCardShell(
            title: "快速收藏",
            subtitle: "点亮星标即可收进这里",
            count: store.favoriteCount(),
            previews: previews,
            icon: "star.fill",
            iconColor: .yellow,
            store: store,
            hovering: hovering,
            action: action
        )
        .onHover { hovering = $0 }
    }
}

private struct CollectionCard: View {
    let collection: ShotCollectionSummary
    let store: ShotStore
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        CollectionCardShell(
            title: collection.name,
            subtitle: collection.note.isEmpty ? "自定义专题集" : collection.note,
            count: collection.itemCount,
            previews: collection.previews,
            icon: "rectangle.stack.fill",
            iconColor: .accentColor,
            store: store,
            hovering: hovering,
            action: action
        )
        .onHover { hovering = $0 }
    }
}

private struct CollectionCardShell: View {
    let title: String
    let subtitle: String
    let count: Int
    let previews: [Shot]
    let icon: String
    let iconColor: Color
    let store: ShotStore
    let hovering: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    Image(systemName: icon)
                        .font(.system(size: DS.font18, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 30, height: 30)
                        .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusChip))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        Text("\(count) 张 · \(subtitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: DS.s2) {
                    ForEach(0..<3, id: \.self) { index in
                        if previews.indices.contains(index) {
                            let shot = previews[index]
                            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                                .frame(maxWidth: .infinity)
                                .frame(height: 82)
                                .background(DS.insetSurface)
                                .clipShape(previewShape)
                        } else {
                            previewShape.fill(DS.insetSurface)
                                .frame(maxWidth: .infinity)
                                .frame(height: 82)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.quaternary)
                                }
                        }
                    }
                }
            }
            .padding(DS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surfaceFill(hovering ? .raised : .content, scheme), in: cardShape)
            .overlay { cardShape.strokeBorder(DS.rim(.content, scheme, hovering: hovering).gradient) }
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 张图片")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }
    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
    }
}
