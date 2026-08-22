import os.signpost

/// 图库关键路径的轻量 signpost。仅用于 Instruments/Console，不参与产品状态。
enum GalleryPerformance {
    private static let log = OSLog(subsystem: "com.wxyhgk.index", category: "GalleryPerformance")

    static func galleryOpen() {
        os_signpost(.event, log: log, name: "Gallery Open")
    }

    static func firstPagePublished(count: Int) {
        os_signpost(.event, log: log, name: "Gallery First Page", "count=%{public}d", count)
    }

    static func firstThumbnailDecoded() {
        os_signpost(.event, log: log, name: "Gallery First Thumbnail")
    }

    static func searchFinished(generation: Int, count: Int) {
        os_signpost(
            .event,
            log: log,
            name: "Gallery Search Finished",
            "generation=%{public}d count=%{public}d",
            generation,
            count
        )
    }
}
