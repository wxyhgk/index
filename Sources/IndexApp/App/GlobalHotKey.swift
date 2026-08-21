import AppKit
import Carbon.HIToolbox

/// 全局快捷键。用 Carbon 的 `RegisterEventHotKey` —— 它是目前唯一不需要辅助功能权限
/// 就能拿到系统级快捷键的公开 API。
///
/// 绑定按名字登记，设置里改了快捷键就整体重注册；Carbon 没有「修改」这种操作，
/// 只能全部注销再注册一遍。
@MainActor
final class GlobalHotKeyCenter {

    static let shared = GlobalHotKeyCenter()

    private struct Binding {
        let shortcut: KeyboardShortcut
        let handler: () -> Void
        /// 允许无修饰键的裸键（如 ⎋）。裸键会劫走全局按键，只能用于短暂的临时绑定。
        var allowsBareKey: Bool = false
    }

    private var bindings: [String: Binding] = [:]
    private var order: [String] = []
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private init() {}

    /// 登记一个绑定并立即生效。同名重复调用会覆盖。
    func bind(_ name: String, to shortcut: KeyboardShortcut, handler: @escaping () -> Void) {
        if bindings[name] == nil { order.append(name) }
        bindings[name] = Binding(shortcut: shortcut, handler: handler)
        rebuild()
    }

    /// 只换快捷键，保留原来的处理逻辑。
    func update(_ name: String, to shortcut: KeyboardShortcut) {
        guard let existing = bindings[name] else { return }
        bindings[name] = Binding(shortcut: shortcut, handler: existing.handler)
        rebuild()
    }

    /// 临时绑定，允许裸键（无修饰键）。目前只用于延时截图倒计时期间监听 ⎋。
    /// 用完必须 `unbind`，否则会一直劫走这个按键。
    func bindTransient(_ name: String, to shortcut: KeyboardShortcut, handler: @escaping () -> Void) {
        if bindings[name] == nil { order.append(name) }
        bindings[name] = Binding(shortcut: shortcut, handler: handler, allowsBareKey: true)
        rebuild()
    }

    /// 解除绑定并立即注销对应的系统快捷键。
    func unbind(_ name: String) {
        guard bindings[name] != nil else { return }
        bindings[name] = nil
        order.removeAll { $0 == name }
        rebuild()
    }

    private func rebuild() {
        installEventHandlerIfNeeded()

        for ref in refs where ref != nil {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()

        for (index, name) in order.enumerated() {
            guard
                let binding = bindings[name],
                binding.shortcut.isValid || binding.allowsBareKey
            else { continue }

            let id = UInt32(index + 1)
            handlers[id] = binding.handler

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.shortcut.keyCode,
                binding.shortcut.modifiers,
                EventHotKeyID(signature: OSType(0x4D534854), id: id),   // 'MSHT'
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr {
                refs.append(ref)
            } else {
                NSLog("[Index] 注册快捷键失败 \(name)=\(binding.shortcut.displayString), status=\(status)（可能已被占用）")
            }
        }
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    // Carbon 事件在主线程派发。
    MainActor.assumeIsolated {
        GlobalHotKeyCenter.shared.fire(id: id)
    }
    return noErr
}
