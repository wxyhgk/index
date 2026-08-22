import Foundation

/// `ShotAttributeWriter` 的存储层实现。后处理器跑在后台，这里负责回到主 actor。
/// 注入式：默认走 `ShotStore.shared`，测试可用 `FakeShotStore`。
struct ShotStoreAttributeWriter: ShotAttributeWriter {
    private let writer: @MainActor (Int64, String, AttributeValue) -> Void
    private let contentWriter: @MainActor (Int64, ContentKind, ContentPayload) -> Void

    /// 生产用：直接写 `ShotStore.shared`。
    init() {
        self.writer = { shotID, key, value in
            ShotStore.shared.writeAttribute(shotID: shotID, key: key, value: value)
        }
        self.contentWriter = { shotID, kind, payload in
            try? ShotStore.shared.saveContent(for: shotID, kind: kind, payload: payload, updateKind: false)
        }
    }

    /// 注入式：调用方提供落库闭包（Fake 可直接写内存）。
    init(
        writer: @escaping @MainActor (Int64, String, AttributeValue) -> Void,
        contentWriter: @escaping @MainActor (Int64, ContentKind, ContentPayload) -> Void = { _, _, _ in }
    ) {
        self.writer = writer
        self.contentWriter = contentWriter
    }

    /// 直接注入 `ShotWriting` 协议实例。
    init(store: any ShotWriting) {
        self.writer = { shotID, key, value in
            store.writeAttribute(shotID: shotID, key: key, value: value)
        }
        self.contentWriter = { shotID, kind, payload in
            try? store.saveContent(for: shotID, kind: kind, payload: payload, updateKind: false)
        }
    }

    func write(shotID: Int64, key: String, value: AttributeValue) async {
        let w = writer
        await MainActor.run {
            w(shotID, key, value)
        }
    }

    func saveContent(shotID: Int64, kind: ContentKind, payload: ContentPayload) async {
        let cw = contentWriter
        await MainActor.run {
            cw(shotID, kind, payload)
        }
    }
}
