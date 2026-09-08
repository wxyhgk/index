import AppKit
import Foundation
import UniformTypeIdentifiers

/// 图库批量成品的 ZIP 出口。
///
/// 面板与文件系统副作用都留在 Platform；上层只负责把逐张渲染好的 PNG 交给 Writer。
/// PNG 本身已经压缩，因此 ZIP 使用 store 模式，避免为了几乎为零的体积收益再烧一遍 CPU。
enum BatchArchiveExporter {

    enum ArchiveError: LocalizedError {
        case archiveTooLarge
        case destinationAlreadyExists
        case noEntries

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: return "ZIP 超过当前导出器支持的 4 GB 限制"
            case .destinationAlreadyExists: return "目标文件已经存在"
            case .noEntries: return "没有可以写入 ZIP 的图片"
            }
        }
    }

    /// 用户明确选择一个 `.zip` 目标。覆盖确认由系统 NSSavePanel 负责。
    @MainActor
    static func chooseDestination(itemCount: Int) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedArchiveName()
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "把选中的 \(itemCount) 项导出为一个 ZIP（包含最新标注）"
        panel.prompt = "导出 ZIP"

        NSApp.activate(ignoringOtherApps: true)
        PanelPlacement.apply(to: panel, anchor: nil)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension.lowercased() == "zip" ? url : url.appendingPathExtension("zip")
    }

    nonisolated static func suggestedArchiveName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Index-\(formatter.string(from: now)).zip"
    }

    /// 只维护一个 PNG 的内存峰值。未 finish（取消、失败或析构）时临时文件会被清掉，
    /// 目标位置不会出现一份看似完整、实际只有半截的 ZIP。
    final class Writer: @unchecked Sendable {
        private struct Entry {
            let name: Data
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
        }

        private let destination: URL
        private let temporaryURL: URL
        private let allowsReplacingExisting: Bool
        private var handle: FileHandle?
        private var entries: [Entry] = []
        private var usedNames: Set<String> = []
        private var offset: UInt64 = 0
        private var isFinished = false

        init(destination: URL, allowsReplacingExisting: Bool = false) throws {
            self.destination = destination
            self.allowsReplacingExisting = allowsReplacingExisting
            temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).partial",
                isDirectory: false
            )
            guard !FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: temporaryURL)
        }

        deinit {
            guard !isFinished else { return }
            try? handle?.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        /// 返回 ZIP 内最终采用的名称；同名项按 `-2/-3…` 分配，且按大小写不敏感避让，
        /// 这样解压到默认不区分大小写的 APFS 上也不会互相覆盖。
        @discardableResult
        func appendPNG(_ data: Data, preferredName: String) throws -> String {
            guard let handle else { throw CocoaError(.fileNoSuchFile) }
            let name = allocateName(preferredName)
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max), data.count <= Int(UInt32.max),
                  offset <= UInt64(UInt32.max) else {
                throw ArchiveError.archiveTooLarge
            }

            let crc = CRC32.checksum(data)
            var local = Data()
            local.appendLE(UInt32(0x04034B50))
            local.appendLE(UInt16(20))                 // version needed
            local.appendLE(UInt16(1 << 11))            // UTF-8 filename
            local.appendLE(UInt16(0))                  // store (PNG is already compressed)
            local.appendLE(UInt16(0))                  // DOS time
            local.appendLE(UInt16(0))                  // DOS date
            local.appendLE(crc)
            local.appendLE(UInt32(data.count))
            local.appendLE(UInt32(data.count))
            local.appendLE(UInt16(nameData.count))
            local.appendLE(UInt16(0))                  // extra length
            local.append(nameData)

            let localOffset = UInt32(offset)
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: data)
            offset += UInt64(local.count + data.count)
            entries.append(Entry(
                name: nameData,
                crc32: crc,
                size: UInt32(data.count),
                localHeaderOffset: localOffset
            ))
            return name
        }

        @discardableResult
        func finish() throws -> URL {
            guard !entries.isEmpty else {
                cancel()
                throw ArchiveError.noEntries
            }
            guard entries.count <= Int(UInt16.max), offset <= UInt64(UInt32.max),
                  let handle else {
                cancel()
                throw ArchiveError.archiveTooLarge
            }

            let centralDirectoryOffset = UInt32(offset)
            for entry in entries {
                var central = Data()
                central.appendLE(UInt32(0x02014B50))
                central.appendLE(UInt16(20))            // version made by
                central.appendLE(UInt16(20))            // version needed
                central.appendLE(UInt16(1 << 11))       // UTF-8 filename
                central.appendLE(UInt16(0))             // store
                central.appendLE(UInt16(0))
                central.appendLE(UInt16(0))
                central.appendLE(entry.crc32)
                central.appendLE(entry.size)
                central.appendLE(entry.size)
                central.appendLE(UInt16(entry.name.count))
                central.appendLE(UInt16(0))             // extra length
                central.appendLE(UInt16(0))             // comment length
                central.appendLE(UInt16(0))             // disk number
                central.appendLE(UInt16(0))             // internal attributes
                central.appendLE(UInt32(0))             // external attributes
                central.appendLE(entry.localHeaderOffset)
                central.append(entry.name)
                try handle.write(contentsOf: central)
                offset += UInt64(central.count)
            }

            let centralSize = offset - UInt64(centralDirectoryOffset)
            guard centralSize <= UInt64(UInt32.max) else {
                cancel()
                throw ArchiveError.archiveTooLarge
            }
            var end = Data()
            end.appendLE(UInt32(0x06054B50))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(entries.count))
            end.appendLE(UInt16(entries.count))
            end.appendLE(UInt32(centralSize))
            end.appendLE(centralDirectoryOffset)
            end.appendLE(UInt16(0))
            try handle.write(contentsOf: end)
            try handle.synchronize()
            try handle.close()
            self.handle = nil

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                guard allowsReplacingExisting else {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw ArchiveError.destinationAlreadyExists
                }
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }
            isFinished = true
            return destination
        }

        func cancel() {
            guard !isFinished else { return }
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        private func allocateName(_ preferredName: String) -> String {
            let cleaned = Self.cleanEntryName(preferredName)
            let ext = (cleaned as NSString).pathExtension.isEmpty
                ? "png"
                : (cleaned as NSString).pathExtension
            let base = (cleaned as NSString).deletingPathExtension
            var candidate = "\(base).\(ext)"
            var counter = 2
            while usedNames.contains(candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )) {
                candidate = "\(base)-\(counter).\(ext)"
                counter += 1
            }
            usedNames.insert(candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ))
            return candidate
        }

        private static func cleanEntryName(_ raw: String) -> String {
            var name = (raw as NSString).lastPathComponent
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix(".") { name.removeFirst() }
            if name.isEmpty { name = "截图.png" }
            return (name as NSString).pathExtension.isEmpty ? "\(name).png" : name
        }
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
