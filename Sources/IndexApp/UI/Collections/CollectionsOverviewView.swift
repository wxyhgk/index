import SwiftUI

// ============================================================
// MARK: - 收藏 tab overview 布局
//
// 页头（标题 + 创建收藏集）+ 卡片网格（快速收藏 / 剪贴板收藏 / 专题集）。
// 数据由 CollectionsContent 传入，本视图不持有 @State（除了 hover）。
// ============================================================

struct CollectionsOverviewView: View {
    let store: ShotStore
    let viewModel: GalleryViewModel
    let collections: [ShotCollectionSummary]
    let favoritePreviews: [Shot]
    let clipboardFavorites: [ClipboardHistoryItem]
    let clipboardFavoritesThumbnails: [Int64: NSImage]
    let clipboardFavoritesAppIcons: [String: NSImage]
    @Binding var creating: Bool
    @Binding var newName: String
    @Binding var renameTarget: ShotCollectionSummary?
    @Binding var renameName: String
    @Binding var deleteTarget: ShotCollectionSummary?
    @Binding var errorMessage: String?
    let filteredCollections: [ShotCollectionSummary]
    let onOpen: (CollectionsNavigationState.Route) -> Void
    let onCreate: () -> Void
    let onCommitRename: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 340), spacing: DS.s3)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.s3) {
                    QuickFavoritesCard(store: store, previews: favoritePreviews) {
                        onOpen(.favorites)
                    }
                    ClipboardFavoritesCard(
                        items: clipboardFavorites,
                        thumbnails: clipboardFavoritesThumbnails,
                        appIcons: clipboardFavoritesAppIcons
                    ) { onOpen(.clipboardFavorites) }
                    ForEach(filteredCollections) { collection in
                        CollectionCard(collection: collection, store: store) {
                            onOpen(.collection(collection.id))
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

    private var header: some View {
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
                        .onSubmit(onCreate)
                    Button("创建", action: onCreate)
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
}
