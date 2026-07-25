import Foundation

/// `ShotAttributeWriter` 的存储层实现。后处理器跑在后台，这里负责回到主 actor。
struct ShotStoreAttributeWriter: ShotAttributeWriter {
    func write(shotID: Int64, key: String, value: AttributeValue) async {
        await MainActor.run {
            ShotStore.shared.writeAttribute(shotID: shotID, key: key, value: value)
        }
    }
}
