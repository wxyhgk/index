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

    @Published var route: Route?

    var chrome: GalleryDestinationChrome {
        switch route {
        case nil:
            return .overview
        case .favorites, .collection:
            return .drilledGrid
        case .clipboardFavorites:
            return CollectionsDestination.clipboardFavoritesChrome
        }
    }

    init(route: Route? = nil) {
        self.route = route
    }
}

struct CollectionsDestination: GalleryDestination {
    static let destinationID = "destination.collections"
    static let clipboardFavoritesChrome = GalleryDestinationChrome.clipboard

    let id = Self.destinationID
    let title = "收藏"
    let symbol = "rectangle.stack.badge.star"
    let order = 25
    let defaultChrome = GalleryDestinationChrome.overview
    private let navigation = CollectionsNavigationState()

    func badge(store: ShotStore) -> Int? {
        let count = store.collectionCount()
        return count > 0 ? count : nil
    }

    func badge(context: GalleryDestinationContext) -> Int? { badge(store: context.store) }
    func content(context: GalleryDestinationContext) -> AnyView {
        AnyView(CollectionsContent(
            store: context.store,
            viewModel: context.viewModel,
            navigation: navigation,
            destinationChrome: context.chrome
        ))
    }
}
