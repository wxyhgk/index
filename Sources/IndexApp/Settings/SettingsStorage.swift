import SwiftUI

struct StorageSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var totalSize: String = "计算中…"
    @State private var shotCount: Int = 0

    private let store = ShotStore.shared

    var body: some View {
        SettingsPage {
            ToggleCardGrid {
                MiniCard("位置", icon: "folder") {
                    Text(store.rootDirectory.path)
                        .font(.system(size: DS.font11))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Button("在访达中显示") {
                        SystemNavigator.revealInFinder(store.rootDirectory)
                    }
                    .controlSize(.mini)
                }

                MiniCard("占用", icon: "internaldrive") {
                    HStack {
                        Text("截图").font(.system(size: DS.font12)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(shotCount)").font(.system(size: DS.font12, design: .monospaced))
                    }
                    HStack {
                        Text("磁盘").font(.system(size: DS.font12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(totalSize).font(.system(size: DS.font12, design: .monospaced))
                    }
                }

                MiniCard("自动清理", icon: "trash") {
                    HStack {
                        Text("启用").font(.system(size: DS.font12))
                        Spacer()
                        Toggle("", isOn: $settings.library.autoCleanupEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Picker("保留", selection: $settings.library.autoCleanupDays) {
                        ForEach(LibraryPrefs.autoCleanupChoices, id: \.self) { d in
                            Text("\(d)天").tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.library.autoCleanupEnabled)
                }
            }
        }
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
        at: url, includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        total += Int64(size)
    }
    return total
}
