import Foundation

/// Code 内容保存稳定的小写语言 ID；显示名称只属于界面，不写入数据库。
struct CodeLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String

    static let builtins: [CodeLanguage] = [
        .init(id: "swift", displayName: "Swift"),
        .init(id: "python", displayName: "Python"),
        .init(id: "javascript", displayName: "JavaScript"),
        .init(id: "typescript", displayName: "TypeScript"),
        .init(id: "json", displayName: "JSON"),
        .init(id: "shell", displayName: "Shell"),
        .init(id: "sql", displayName: "SQL"),
        .init(id: "rust", displayName: "Rust"),
        .init(id: "go", displayName: "Go"),
        .init(id: "java", displayName: "Java"),
        .init(id: "kotlin", displayName: "Kotlin"),
        .init(id: "c", displayName: "C"),
        .init(id: "cpp", displayName: "C++"),
        .init(id: "html", displayName: "HTML"),
        .init(id: "css", displayName: "CSS"),
        .init(id: "yaml", displayName: "YAML"),
        .init(id: "markdown", displayName: "Markdown"),
    ]

    static func displayName(for id: String?) -> String {
        guard let id = ContentCode.normalizedLanguage(id) else { return "纯文本" }
        return builtins.first(where: { $0.id == id })?.displayName ?? id
    }
}

/// 快速、确定性的本地检测。它只在新建和“自动检测”时执行，不进入卡片滚动路径。
enum CodeLanguageDetector {
    static func detect(_ source: String) -> String? {
        let sample = String(source.prefix(16_384))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if looksLikeJSON(trimmed) { return "json" }
        if containsAny(sample, ["interface ", "type ", ": string", ": number", " as const", "unknown"]) {
            return "typescript"
        }
        if containsAny(sample, ["fn main", "let mut ", "impl ", "use std::", "pub struct", "Result<"]) {
            return "rust"
        }
        if containsAny(sample, ["package main", "func main()", "fmt.", "go func", ":= "]) {
            return "go"
        }
        if containsAny(sample, ["const ", "console.log", "=>", "document.", "require(", "export default"]) {
            return "javascript"
        }
        if containsAny(sample.uppercased(), ["SELECT ", "INSERT INTO ", "UPDATE ", "CREATE TABLE ", "ALTER TABLE ", "DELETE FROM "]) {
            return "sql"
        }
        if trimmed.hasPrefix("#!") || containsAny(sample, ["#!/bin/", "set -e", "export ", "${", "$("]) {
            return "shell"
        }
        if containsAny(sample.lowercased(), ["<!doctype html", "<html", "<body", "<div", "</"]) {
            return "html"
        }
        if containsAny(sample, ["#include <", "std::", "cout <<", "nullptr", "template <"]) {
            return "cpp"
        }
        if containsAny(sample, ["#include <", "printf(", "malloc(", "int main("]) {
            return "c"
        }
        if containsAny(sample, ["fun main", "val ", "data class ", "companion object"]) {
            return "kotlin"
        }
        if containsAny(sample, ["public static void main", "System.out.", "public class ", "private final "]) {
            return "java"
        }
        if containsAny(sample, ["import SwiftUI", "import Foundation", "@MainActor", "guard let ", "func ", "struct "]) {
            return "swift"
        }
        if containsAny(sample, ["def ", "from ", "print(", "if __name__ ==", "self."]) {
            return "python"
        }
        if containsAny(sample, ["---\n", "version: ", "services:\n", "name: "]) { return "yaml" }
        if containsAny(sample, ["# ", "## ", "```", "- [ ] "]) { return "markdown" }
        if containsAny(sample, ["{\n", "}\n", ";\n"]) { return "css" }
        return nil
    }

    private static func containsAny(_ source: String, _ tokens: [String]) -> Bool {
        tokens.contains { source.contains($0) }
    }

    private static func looksLikeJSON(_ source: String) -> Bool {
        guard let first = source.first, first == "{" || first == "[",
              let data = source.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
