import Foundation

/// CLIP 文本 BPE 分词器。
///
/// 移植自 CLIP-Finder2 的 `CLIP_Tokenizer.swift`
/// （https://github.com/fguzman82/CLIP-Finder2，MIT License），
/// 其本身是 open_clip `tokenizer.py` 的 Swift 改写
/// （https://github.com/mlfoundations/open_clip）。
///
/// 词表 `bpe_simple_vocab_16e6.txt` 与 open_clip 同名文件内容一致（已解压），
/// 随模型一起由 `CLIPModelStore` 下载，不进 app bundle。
///
/// 输出契约：`encode(_:)` 返回**定长 77** 的 token 序列 ——
/// `<start_of_text>` + BPE tokens + `<end_of_text>`，超长截断（末位强制回 EOT），
/// 不足补 0。这正是 MobileCLIP 文本编码器的输入格式。
final class CLIPTokenizer {

    /// 一对相邻子词。BPE 合并规则表的 key。
    private struct BytePair: Hashable {
        let a: String
        let b: String
    }

    /// MobileCLIP 文本输入的上下文长度。
    static let contextLength = 77

    private let bpeRanks: [BytePair: Int]
    private let tokensToIds: [String: Int32]
    private let byteEncoder: [UInt8: String]
    private var cache: [String: String] = [:]

    private let startToken = "<start_of_text>"
    private let endToken = "<end_of_text>"
    private let sotTokenID: Int32
    private let eotTokenID: Int32

    /// open_clip 的分词正则：撇号缩写 / 连续字母 / 单个数字 / 其它符号串。
    private static let wordPattern: NSRegularExpression = {
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+"#
        // 模式是编译期常量，构造不可能失败。
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    enum TokenizerError: Error {
        case vocabUnreadable
        case vocabTruncated
    }

    init(vocabURL: URL) throws {
        guard let bpeData = try? String(contentsOf: vocabURL, encoding: .utf8) else {
            throw TokenizerError.vocabUnreadable
        }
        let lines = bpeData.components(separatedBy: .newlines)
        // 与 open_clip 一致：跳过首行版本头，取前 48894 条合并规则。
        let mergeCount = 49152 - 256 - 2
        guard lines.count > mergeCount else { throw TokenizerError.vocabTruncated }
        let merges = lines[1...mergeCount]

        let (byteEncoder, byteOrder) = Self.bytesToUnicode()
        self.byteEncoder = byteEncoder

        // 词表顺序：256 个字节字符 → 各自加 </w> 的词尾变体 → 合并产物 → 两个特殊符。
        var vocab = byteOrder.map { byteEncoder[$0]! }
        vocab += vocab.map { $0 + "</w>" }
        vocab += merges.map { $0.replacingOccurrences(of: " ", with: "") }
        vocab += [startToken, endToken]

        tokensToIds = Dictionary(uniqueKeysWithValues: zip(vocab, (0..<vocab.count).map(Int32.init)))

        var ranks: [BytePair: Int] = [:]
        for (index, merge) in merges.enumerated() {
            let parts = merge.split(separator: " ").map(String.init)
            guard parts.count == 2 else { continue }
            ranks[BytePair(a: parts[0], b: parts[1])] = index
        }
        bpeRanks = ranks

        sotTokenID = tokensToIds[startToken]!
        eotTokenID = tokensToIds[endToken]!
        cache = [startToken: startToken, endToken: endToken]
    }

    /// 文本 → 定长 77 的 token 序列（含起止符，零填充）。
    func encode(_ text: String) -> [Int32] {
        var tokens = [sotTokenID] + tokenize(text) + [eotTokenID]
        if tokens.count > Self.contextLength {
            tokens = Array(tokens.prefix(Self.contextLength))
            tokens[Self.contextLength - 1] = eotTokenID
        }
        return tokens + Array(repeating: 0, count: Self.contextLength - tokens.count)
    }

    // MARK: - BPE 内部实现

    private func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for word in byteEncode(cleanAndLowercase(text)) {
            for token in bpe(token: word).split(separator: " ") {
                if let id = tokensToIds[String(token)] {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private func cleanAndLowercase(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// 按 open_clip 正则切词，再把每个词的 UTF-8 字节映射成可见 Unicode 字符。
    private func byteEncode(_ text: String) -> [String] {
        let matches = Self.wordPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).utf8.compactMap { byteEncoder[$0] }.joined()
        }
    }

    private func bpe(token: String) -> String {
        if let cached = cache[token] { return cached }

        var word = Array(token).map(String.init)
        guard !word.isEmpty else { return token }
        word[word.count - 1] += "</w>"

        var pairs = Self.pairs(of: word)
        while true {
            let ranked = pairs.compactMap { pair in bpeRanks[pair].map { (pair, $0) } }
            guard let (bigram, _) = ranked.min(by: { $0.1 < $1.1 }) else { break }

            var merged: [String] = []
            var i = 0
            while i < word.count {
                guard let j = word[i...].firstIndex(of: bigram.a) else {
                    merged.append(contentsOf: word[i...])
                    break
                }
                merged.append(contentsOf: word[i..<j])
                i = j
                if i < word.count - 1, word[i] == bigram.a, word[i + 1] == bigram.b {
                    merged.append(bigram.a + bigram.b)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
            if word.count == 1 { break }
            pairs = Self.pairs(of: word)
        }

        let result = word.joined(separator: " ")
        cache[token] = result
        return result
    }

    private static func pairs(of word: [String]) -> Set<BytePair> {
        var set = Set<BytePair>()
        for i in 0..<word.count - 1 {
            set.insert(BytePair(a: word[i], b: word[i + 1]))
        }
        return set
    }

    /// GPT-2 式字节 → 可见 Unicode 字符映射（避免词表里出现控制字符）。
    private static func bytesToUnicode() -> ([UInt8: String], [UInt8]) {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        let mapping = Dictionary(
            uniqueKeysWithValues: zip(bs.map(UInt8.init), cs.map { String(UnicodeScalar($0)!) })
        )
        return (mapping, bs.map(UInt8.init))
    }
}
