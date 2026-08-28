import Foundation

/// Index 输入源内部的语言模式。平台层负责持久化，核心层只定义状态语义。
public enum InputLanguageMode: String, Equatable, Sendable {
    case chinese
    case english

    public var toggled: Self {
        self == .chinese ? .english : .chinese
    }
}

/// 把“轻点 Shift”与 Shift 组合键分开，避免 Shift+A 或系统快捷键误切换语言。
public struct ShiftLanguageSwitchState: Equatable, Sendable {
    private var shiftIsDown = false
    private var tapIsEligible = false

    public init() {}

    /// - Returns: 仅当一次没有参与任何组合键的 Shift 按下/释放周期完成时返回 true。
    public mutating func flagsChanged(
        shiftIsDown newShiftIsDown: Bool,
        hasBlockingModifiers: Bool
    ) -> Bool {
        if newShiftIsDown {
            if shiftIsDown {
                // 第二个 Shift、修饰键变化或重复的 flagsChanged 都不应算单击。
                tapIsEligible = false
            } else {
                tapIsEligible = !hasBlockingModifiers
            }
            shiftIsDown = true
            return false
        }

        guard shiftIsDown else { return false }
        shiftIsDown = false
        defer { tapIsEligible = false }
        return tapIsEligible && !hasBlockingModifiers
    }

    /// Shift 按住期间出现任何普通键，就把这次手势判定为组合键。
    public mutating func noteKeyDown() {
        if shiftIsDown {
            tapIsEligible = false
        }
    }

    public mutating func reset() {
        shiftIsDown = false
        tapIsEligible = false
    }
}
