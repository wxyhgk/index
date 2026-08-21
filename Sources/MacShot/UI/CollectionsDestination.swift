import SwiftUI

// ============================================================
// MARK: - 收藏 tab 入口
//
// 导航状态 + Destination 协议声明。
// 布局拆在 CollectionsContent / CollectionsOverviewView / CollectionsDetailView，
// 卡片组件拆在 CollectionCards / ClipboardFavoritesViews。
// ============================================================

@MainActor
final class CollectionsNavigationState: ObservableObject {
    enum Route: Equatable {
        case favorites
        case collection(Int64)
        case clipboardFavorites
    }

    static let shared = CollectionsNavigationState()
    @Published var route: Route?
    var isDrilled: Bool { route != nil }
    private init() {}
}

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
