import Foundation

// MARK: - 本地规则引擎（= agent 的离线执行方式）
//
// 规则 = 条件（匹配 shot 特征）+ 动作（调工具/改配置/打标记）。
// 零延迟、离线、可预测。后续接 LLM 时，规则引擎是 LLM 的"快速通道"：
// 简单判断走规则，复杂判断走 LLM。
//
// 规则是数据不是代码 —— 用户/agent 可以增删改规则，不改二进制。

struct Rule: Sendable {
    let id: String
    let description: String
    /// 条件：匹配 shot 特征。返回 true 则触发动作。
    let condition: @Sendable (HookContext) -> Bool
    /// 动作：满足条件时执行。
    let action: @Sendable (HookContext) async -> Void
}

@MainActor
final class RuleEngine: Sendable {

    private var rules: [Rule] = []

    /// 注册一条规则。
    func add(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
    }

    /// 摘掉一条规则。
    func remove(_ ruleID: String) {
        rules.removeAll { $0.id == ruleID }
    }

    /// 跑所有规则（条件命中的触发动作）。
    func run(context: HookContext) async {
        for rule in rules where rule.condition(context) {
            await rule.action(context)
        }
    }

    var ruleCount: Int { rules.count }

    // MARK: - 内置规则

    /// 注册内置规则。
    func registerBuiltins() {
        // 示例规则：截图含大量代码特征（缩进/关键字）→ 标记为 code 类型
        add(Rule(
            id: "auto-detect-code",
            description: "截图含代码特征时自动标记为 code 类型",
            condition: { context in
                guard let text = context.metadata?.ocrText, !text.isEmpty else { return false }
                // 简单启发式：含缩进 + 关键字
                let hasIndent = text.contains("    ") || text.contains("\t")
                let hasKeywords = ["func", "def", "class", "struct", "import", "var", "let"].contains { text.contains($0) }
                return hasIndent && hasKeywords
            },
            action: { _ in
                // 当前骨架：只打日志（后续接 saveContent 改 contentKind）
                NSLog("[Agent] 规则命中: auto-detect-code")
            }
        ))
    }
}
