import AppKit

/// 把不可变的 Shot 附件投影为可编辑的 `.xyz` 工作副本，再交给系统默认应用。
/// 外部软件只会修改副本，不会悄悄改变截图所关联的原始坐标。
@MainActor
enum MoleculeSourceFilePresenter {
    static func openWorkingCopy(
        _ source: MoleculeSourceAttachment,
        shotID: Int64?
    ) throws {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("Molecule Working Copies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let identity = shotID.map(String.init) ?? UUID().uuidString
        let url = base.appendingPathComponent("molecule-\(identity).xyz")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(source.canonicalXYZ.utf8).write(to: url, options: .atomic)
        }
        guard NSWorkspace.shared.open(url) else {
            throw OpenError.noDefaultApplication
        }
    }

    enum OpenError: LocalizedError {
        case noDefaultApplication

        var errorDescription: String? {
            "系统没有可用于打开 .xyz 文件的默认应用。"
        }
    }
}
