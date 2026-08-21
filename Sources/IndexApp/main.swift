import AppKit

// main.swift 的顶层代码是 nonisolated 的，而 AppKit 全在主 actor 上，这里显式声明一次。
// delegate 必须是全局强引用 —— NSApplication.delegate 是 weak 的。
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = appDelegate
    // 菜单栏常驻，不在 Dock 显示。打开图库窗口时会临时切到 .regular。
    app.setActivationPolicy(.accessory)
    app.run()
}
