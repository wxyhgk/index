import Foundation

/// 常用虚拟键码。此前覆盖层和钉图窗口各写了一份私有 `Key` 枚举。
enum KeyCode {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let h: UInt16 = 4
    static let g: UInt16 = 5
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let r: UInt16 = 15
    static let t: UInt16 = 17
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let l: UInt16 = 37
    static let n: UInt16 = 45
    static let m: UInt16 = 46

    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let f2: UInt16 = 120

    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    static let arrows: Set<UInt16> = [left, right, down, up]
}
