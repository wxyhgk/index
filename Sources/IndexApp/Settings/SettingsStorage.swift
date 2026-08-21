import SwiftUI

// MARK: - 存储

struct StorageSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var totalSize: String = "计算中…"
    @State private var shotCount: Int = 0

    private let store = ShotStore.shared

    var body: some View {
        Form {
            Section("位置") {
                LabeledContent("目录") {
                    Text(store.rootDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("在访达中显示") {
                    SystemNavigator.revealInFinder(store.rootDirectory)
                }
                .controlSize(.small)
            }

            Section("占用") {
                LabeledContent("截图数量", value: "\(shotCount)")
                LabeledContent("磁盘占用", value: totalSize)
            }

            Section("自动清理") {
                Toggle("自动清理旧截图", isOn: $settings.library.autoCleanupEnabled)

                Picker("保留时长", selection: $settings.library.autoCleanupDays) {
                    ForEach(LibraryPrefs.autoCleanupChoices, id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.library.autoCleanupEnabled)

                Text("启动时删除超过保留时长的旧截图，每次最多 \(StorageJanitor.batchLimit) 张，删不完的下次接着删。收藏的、打过标签的和标注过的永远不删 —— 你亲手留下的痕迹反过来定义了什么值得留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("原图按内容哈希存放，同样的画面只会占一份空间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    private func measure() async {
        shotCount = store.shots.count
        let root = store.rootDirectory
        let bytes = await Task.detached(priority: .utility) {
            directorySize(of: root)
        }.value
        totalSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private func directorySize(of url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        total += Int64(size)
    }
    return total
}
