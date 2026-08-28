import Foundation

/// 输入法只维护当前句子的短尾巴，不能把整篇文档持续送去检索。
public struct InputQueryBuffer: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case text(String)
        case deleteBackward
        case boundary
        case ignore
    }

    public private(set) var text = ""
    public let maximumLength: Int

    public init(maximumLength: Int = 64) {
        self.maximumLength = maximumLength
    }

    public mutating func consume(_ command: Command) -> String? {
        switch command {
        case .ignore:
            return query
        case .boundary:
            clear()
            return nil
        case .deleteBackward:
            guard !text.isEmpty else { return nil }
            text.removeLast()
        case let .text(value):
            append(value)
        }
        return query
    }

    public mutating func clear() {
        text = ""
    }

    public var query: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLongEnough(trimmed) else { return nil }
        return trimmed
    }

    private mutating func append(_ value: String) {
        for character in value {
            if Self.boundaries.contains(character) {
                text = ""
            } else if !character.isNewline {
                text.append(character)
            }
        }
        if text.count > maximumLength {
            text = String(text.suffix(maximumLength))
        }
    }

    private static func isLongEnough(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.unicodeScalars.contains(where: { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
        }) {
            return value.count >= 2
        }
        return value.count >= 3
    }

    private static let boundaries = Set<Character>("\n\r.!?。！？；;")
}
