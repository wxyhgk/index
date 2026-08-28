import AOSPPinyinIME
import Foundation

/// Swift ownership wrapper for the Apache-2.0 AOSP PinyinIME decoder.
/// The upstream engine is process-global, so the input method owns exactly one instance.
final class AOSPPinyinDecoder {
    private(set) var isAvailable = false

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        guard let systemDictionary = bundle.url(
            forResource: "dict_pinyin",
            withExtension: "dat",
            subdirectory: "PinyinIME"
        ) else {
            NSLog("[IndexInputMethod] 找不到 AOSP 拼音词库")
            return
        }

        do {
            let dataRoot = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Index/InputMethod", isDirectory: true)
            try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let userDictionary = dataRoot.appendingPathComponent("pinyin-user.dat")
            isAvailable = systemDictionary.path.withCString { systemPath in
                userDictionary.path.withCString { userPath in
                    index_pinyin_open(systemPath, userPath)
                }
            }
        } catch {
            NSLog("[IndexInputMethod] 无法创建拼音用户词库：\(error.localizedDescription)")
        }
    }

    deinit {
        if isAvailable {
            index_pinyin_flush()
            index_pinyin_close()
        }
    }

    /// 保留足够的候选供分页，但设置上限，避免每次按键复制无界数组。
    func candidates(for pinyin: String, limit: Int = 90) -> [String] {
        guard isAvailable, !pinyin.isEmpty, limit > 0 else { return [] }
        let candidateCount = pinyin.utf8CString.withUnsafeBufferPointer { buffer in
            index_pinyin_search(buffer.baseAddress, pinyin.utf8.count)
        }
        let count = min(Int(candidateCount), limit)
        return (0..<count).compactMap(candidate(at:))
    }

    func choose(_ index: Int) {
        guard isAvailable, index >= 0 else { return }
        _ = index_pinyin_choose(index)
    }

    func reset() {
        guard isAvailable else { return }
        index_pinyin_reset()
    }

    private func candidate(at index: Int) -> String? {
        var utf16 = [UInt16](repeating: 0, count: 128)
        let length = utf16.withUnsafeMutableBufferPointer { buffer in
            index_pinyin_copy_candidate(index, buffer.baseAddress, buffer.count)
        }
        guard length > 0 else { return nil }
        return String(decoding: utf16.prefix(Int(length)), as: UTF16.self)
    }
}
