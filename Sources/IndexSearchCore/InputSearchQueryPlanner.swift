import Foundation

/// Plans retrieval interpretations without deciding what the input method will commit.
/// Raw Latin and the best decoded Chinese candidate are intentionally independent.
public enum InputSearchQueryPlanner {
    public static func queries(
        composition: String,
        pinyinCandidates: [String]
    ) -> [String] {
        var values: [String] = []
        let raw = composition.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 3 {
            values.append(raw)
        }
        if let chinese = pinyinCandidates.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           chinese.count >= 2,
           !values.contains(chinese) {
            values.append(chinese)
        }
        return values
    }
}
