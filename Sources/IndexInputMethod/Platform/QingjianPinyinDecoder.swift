import QingjianPinyinIME
import Foundation

/// Swift ownership wrapper for the Qingjian pinyin engine (Rust FFI).
/// 接口与 AOSPPinyinDecoder 对齐，controller 无需改动。
final class QingjianPinyinDecoder {
    private(set) var isAvailable = false
    private var lastComposition = ""

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        guard let dictURL = bundle.url(
            forResource: "dict",
            withExtension: "qj",
            subdirectory: nil
        ) else {
            NSLog("[IndexInputMethod] 找不到青简拼音词库 dict.qj")
            return
        }
        isAvailable = dictURL.path.withCString {
            qingjian_pinyin_open($0)
        }
        if !isAvailable {
            NSLog("[IndexInputMethod] 青简拼音词库加载失败")
        }
    }

    deinit {
        if isAvailable {
            qingjian_pinyin_close()
        }
    }

    /// 传入完整拼音串，返回候选列表。
    /// 内部逐键 push 到引擎，然后 query。
    func candidates(for pinyin: String, limit: Int = 90) -> [String] {
        guard isAvailable, !pinyin.isEmpty, limit > 0 else { return [] }
        // 拼音串变化时重建引擎状态
        if pinyin != lastComposition {
            qingjian_pinyin_clear()
            for char in pinyin {
                qingjian_pinyin_push(UInt16(char.asciiValue ?? 0))
            }
            lastComposition = pinyin
        }
        let count = qingjian_pinyin_query()
        let n = min(Int(count), limit)
        return (0..<n).compactMap { candidate(at: $0) }
    }

    /// 提交第 index 个候选（触发学习）。
    func choose(_ index: Int) {
        guard isAvailable, index >= 0 else { return }
        var utf16 = [UInt16](repeating: 0, count: 256)
        _ = utf16.withUnsafeMutableBufferPointer { buffer in
            qingjian_pinyin_commit(index, buffer.baseAddress, buffer.count)
        }
        lastComposition = ""
    }

    /// 清空拼音缓冲区。
    func reset() {
        guard isAvailable else { return }
        qingjian_pinyin_clear()
        lastComposition = ""
    }

    private func candidate(at index: Int) -> String? {
        var utf16 = [UInt16](repeating: 0, count: 128)
        let length = utf16.withUnsafeMutableBufferPointer { buffer in
            qingjian_pinyin_copy_candidate(index, buffer.baseAddress, buffer.count)
        }
        guard length > 0 else { return nil }
        return String(decoding: utf16.prefix(Int(length)), as: UTF16.self)
    }
}
