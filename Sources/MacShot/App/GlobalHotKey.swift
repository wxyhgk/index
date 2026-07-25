import AppKit
import Carbon.HIToolbox

/// 极简全局快捷键。用 Carbon 的 RegisterEventHotKey —— 它是目前唯一不需要辅助功能权限
/// 就能拿到系统级快捷键的公开 API。
@MainActor
final class GlobalHotKeyCenter {

    static let shared = GlobalHotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    struct Modifier {
        static let command = UInt32(cmdKey)
        static let control = UInt32(controlKey)
        static let option = UInt32(optionKey)
        static let shift = UInt32(shiftKey)
    }

    enum Key: UInt32 {
        case a = 0
        case s = 1
        case g = 5
    }

    func register(key: Key, modifiers: UInt32, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D534854), id: id)   // 'MSHT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.rawValue,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            refs.append(ref)
        } else {
            NSLog("[MacShot] 注册快捷键失败, status=\(status)（可能已被其它 App 占用）")
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
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            nil,
            nil
        )
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
