import SwiftUI

// MARK: - Interaction rendering policy

private struct GalleryIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

/// The gallery should spend a scroll frame moving already-decoded pixels, not
/// starting work for cards that may leave the viewport before the next frame.
/// The value is scoped to the gallery scroll view; other CachedImage users keep
/// their normal eager-loading behavior.
private struct GalleryDefersThumbnailLoadingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var galleryIsScrolling: Bool {
        get { self[GalleryIsScrollingKey.self] }
        set { self[GalleryIsScrollingKey.self] = newValue }
    }

    var galleryDefersThumbnailLoading: Bool {
        get { self[GalleryDefersThumbnailLoadingKey.self] }
        set { self[GalleryDefersThumbnailLoadingKey.self] = newValue }
    }
}
