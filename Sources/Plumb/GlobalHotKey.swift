import AppKit
import Carbon.HIToolbox

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GlobalHotKey
//
// 模块角色：注册一个**系统级全局热键**（Carbon RegisterEventHotKey）。
//
// 为什么用 Carbon 而非 CGEvent tap：RegisterEventHotKey 不需要额外权限（不像事件 tap 需要
// 辅助功能/输入监控之外的授权），对「常驻菜单栏 agent 触发一个动作」这一场景最轻、最稳。
// 热键在任何前台 app 下都能触发（这正是「切到 Finder 按热键 Tile now」需要的）。
//
// 生命周期：由持有者（AppDelegate）作为属性强引用；deinit 注销热键与事件处理器。
// 回调在主线程投递（Carbon 事件在主 run loop，仍显式 hop 到 main 以满足 Swift 6 隔离）。
// ─────────────────────────────────────────────────────────────────────────────

final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: @Sendable () -> Void
    private static let signature: OSType = 0x504C4D42   // 'PLMB'
    nonisolated(unsafe) private static var counter: UInt32 = 0

    /// - keyCode: 虚拟键码（如 `UInt32(kVK_ANSI_T)`）。
    /// - modifiers: Carbon 修饰位掩码（如 `UInt32(cmdKey | optionKey)`）。
    /// - callback: 热键按下时在主线程调用（@Sendable；内部通常 `MainActor.assumeIsolated`）。
    /// 返回 nil 表示注册失败（组合被占用 / 事件处理器安装失败）。
    /// 本热键的唯一 id（Carbon EventHotKeyID.id）。事件处理器据此**只响应自己的热键**——
    /// 否则每个处理器都会对所有热键事件触发，导致多个热键互相串（⌥⌘T 与 ⌥⌘G 都执行两者）。
    private let idValue: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping @Sendable () -> Void) {
        self.callback = callback

        GlobalHotKey.counter += 1
        self.idValue = GlobalHotKey.counter
        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: GlobalHotKey.counter)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // 读出实际按下的热键 id，只处理**本实例**的热键（关键：处理器按事件类型安装，
                // 会收到所有热键事件，必须按 id 过滤，否则多热键互相串扰）。
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                // 只处理**本实例**的热键。若这不是本实例的热键（是另一个 GlobalHotKey 的事件），
                // **必须**返回 eventNotHandledErr 让事件沿处理器链继续传给兄弟处理器——每个实例都在
                // 同一个 application event target 上装了自己的处理器，Carbon 按「后装先调」的 LIFO 顺序
                // 调用它们。若这里返回 noErr（= 已处理、停止传播），最后注册的那个热键的处理器会**吞掉
                // 所有**热键事件，导致其它热键永远收不到。这正是「⌥⌘G 能用、⌃⌥⌘T 不触发」的真正根因：
                // G 后注册 → 其处理器先被调用 → 对 T 的事件返回 noErr 吃掉，T 的处理器永远轮不到。
                guard status == noErr,
                      pressedID.signature == GlobalHotKey.signature,
                      pressedID.id == me.idValue
                else { return OSStatus(eventNotHandledErr) }
                let cb = me.callback
                DispatchQueue.main.async { cb() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
