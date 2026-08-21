import Combine
import CoreML
import Foundation

/// MobileCLIP-S0 模型文件的磁盘位置。纯路径常量，
/// 单独抽出来是因为编码器在后台 actor 里也要读，不该被主 actor 隔离拦住。
enum CLIPModelLocation {
    /// ~/Library/Application Support/Index/models/mobileclip-s0/
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Index/models/mobileclip-s0", isDirectory: true)

    static let compiledImageModel = directory.appendingPathComponent("image.mlmodelc")
    static let compiledTextModel = directory.appendingPathComponent("text.mlmodelc")
    static let vocab = directory.appendingPathComponent("bpe_simple_vocab_16e6.txt")

    /// 已编译模型 + 词表齐备即视为就绪。
    static var modelsArePresent: Bool {
        [compiledImageModel, compiledTextModel, vocab]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// 下载清单。放在 `CLIPModelStore` 外面 —— @MainActor 类的 static 存储属性
/// 会被主 actor 隔离，而清单是纯数据，不该沾隔离。
enum CLIPModelManifest {

    struct RemoteFile {
        let url: URL
        /// 相对 `CLIPModelLocation.directory` 的落盘路径。
        let relativePath: String
        /// 远端实测大小（字节），用于跳过已完成的文件和计算进度。
        let bytes: Int64
    }

    private static let hfBase = "https://huggingface.co/apple/coreml-mobileclip/resolve/main/"

    /// 2026-07 实测的文件清单（HF API `/api/models/apple/coreml-mobileclip/tree/main`）。
    static let files: [RemoteFile] = {
        func hf(_ path: String, _ bytes: Int64) -> RemoteFile {
            RemoteFile(url: URL(string: hfBase + path)!, relativePath: path, bytes: bytes)
        }
        return [
            hf("mobileclip_s0_image.mlpackage/Manifest.json", 617),
            hf("mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/model.mlmodel", 153_260),
            hf("mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 22_717_696),
            hf("mobileclip_s0_text.mlpackage/Manifest.json", 617),
            hf("mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/model.mlmodel", 57_953),
            hf("mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 84_871_616),
            RemoteFile(
                url: URL(string: "https://raw.githubusercontent.com/fguzman82/CLIP-Finder2/main/CLIP-Finder2/bpe_simple_vocab_16e6.txt")!,
                relativePath: "bpe_simple_vocab_16e6.txt",
                bytes: 3_194_984
            )
        ]
    }()

    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.bytes }
}

/// MobileCLIP-S0 的下载、编译与缓存管理。
///
/// 模型不进 git、不进 app bundle —— 由用户在设置里主动下载（约 111 MB）。
/// 下载来源：
///   - 模型：huggingface.co/apple/coreml-mobileclip（Apple 官方 CoreML 版）。
///     mlpackage 是目录不是单文件，按下方清单逐文件走 HF 的 resolve API。
///   - BPE 词表：github.com/fguzman82/CLIP-Finder2（MIT），
///     与 open_clip 的 bpe_simple_vocab_16e6.txt.gz 解压后内容一致。
///
/// 编译后的 .mlmodelc 落在 `CLIPModelLocation.directory`，原始 mlpackage
/// 编译成功即删（省一半磁盘）。失败可整体重试：已下载且大小吻合的文件会跳过。
@MainActor
final class CLIPModelStore: ObservableObject {

    static let shared = CLIPModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case compiling
        case ready(diskBytes: Int64)
        case failed(String)
    }

    @Published private(set) var state: State

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// 需要下载的总量（约 111 MB），设置页按钮文案用。
    static let totalDownloadBytes = CLIPModelManifest.totalBytes

    private init() {
        state = CLIPModelLocation.modelsArePresent
            ? .ready(diskBytes: Self.directorySize())
            : .notDownloaded
    }

    // MARK: - 下载与编译

    /// 下载清单里的全部文件并编译成 .mlmodelc。可重入：进行中或已就绪直接返回。
    func ensureModels() async {
        switch state {
        case .ready, .downloading, .compiling:
            return
        case .notDownloaded, .failed:
            break
        }

        do {
            state = .downloading(progress: 0)
            try await downloadAll()
            state = .compiling
            try await compileAll()
            state = .ready(diskBytes: Self.directorySize())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 删除全部模型文件（含已编译产物），回到未下载状态。
    func removeModels() async {
        await CLIPEncoder.shared.unload()
        try? FileManager.default.removeItem(at: CLIPModelLocation.directory)
        state = .notDownloaded
    }

    private func downloadAll() async throws {
        let root = CLIPModelLocation.directory
        var doneBytes: Int64 = 0

        for file in CLIPModelManifest.files {
            let destination = root.appendingPathComponent(file.relativePath)

            // 重试路径：上次已完整落盘的文件直接跳过。
            let existingSize = (try? FileManager.default
                .attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            if existingSize == file.bytes {
                doneBytes += file.bytes
                state = .downloading(progress: Double(doneBytes) / Double(Self.totalDownloadBytes))
                continue
            }

            let (temporary, response) = try await URLSession.shared.download(from: file.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ModelStoreError.badResponse(file.relativePath)
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            doneBytes += file.bytes
            state = .downloading(progress: Double(doneBytes) / Double(Self.totalDownloadBytes))
        }
    }

    private func compileAll() async throws {
        let pairs: [(package: String, destination: URL)] = [
            ("mobileclip_s0_image.mlpackage", CLIPModelLocation.compiledImageModel),
            ("mobileclip_s0_text.mlpackage", CLIPModelLocation.compiledTextModel)
        ]
        for (package, destination) in pairs {
            let source = CLIPModelLocation.directory.appendingPathComponent(package)
            let compiled = try await MLModel.compileModel(at: source)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: compiled, to: destination)
            } catch {
                // 编译产物在系统临时目录，跨卷 move 可能失败 —— 退回复制。
                try FileManager.default.copyItem(at: compiled, to: destination)
                try? FileManager.default.removeItem(at: compiled)
            }
            // 原始 mlpackage 用完即删，磁盘只留编译产物。
            try? FileManager.default.removeItem(at: source)
        }
    }

    private nonisolated static func directorySize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: CLIPModelLocation.directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    enum ModelStoreError: LocalizedError {
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let file):
                return "下载 \(file) 失败（服务器返回异常），请重试"
            }
        }
    }
}
