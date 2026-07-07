import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GridLayoutEngine
//
// 模块角色：网格平铺「受管集合」模型的纯状态机（无 AppKit / AX 依赖，完全可单测）。
//
// 语义（用户确认的默认取舍）：
//   - 「Tile Finder」= 把某 app 标记为网格受管（该标记存于 GridSettingsStore，不在本引擎）。
//   - 启用当下【不】动任何窗口——本引擎的受管集合初始为空。
//   - 该 app **新开**的窗口 → 加入受管集合，整个受管集合重排成网格；
//     启用前就已存在、且从未被「Tile now」纳入的窗口保持原位不动。
//   - 「Tile now」→ 把该 app **当前全部**窗口快照进受管集合并一次性排布（这是把老窗口纳入的唯一途径）。
//   - 受管窗口关闭 → 从集合移除，剩余窗口重排以填补空缺。
//
// 本引擎只操作不透明的「窗口 key」（String，形如 "pid:windowNumber"，与 Observer 的 key 一致）
// 与受管顺序（= 网格排布顺序，行优先、左上优先）。「某 app 是否受管」「窗口当前坐标排序」
// 「把 frame 写进 AX」都由调用方（GridTilingController）处理——保持本引擎纯粹、可测。
// ─────────────────────────────────────────────────────────────────────────────

/// 网格平铺受管集合的纯状态机。按 pid 维护有序的受管窗口 key 列表。
struct GridLayoutEngine {
    /// pid → 有序受管窗口 key（顺序即网格排布顺序）。
    private var managed: [pid_t: [String]] = [:]

    init() {}

    /// 「Tile now」：把该 app 当前全部窗口快照进受管集合（替换任何既有受管集合），
    /// 顺序由调用方按屏幕位置（左上→右下）预排序。返回需要排布的有序 key。
    /// 传入空列表 → 清空该 pid 的受管集合并返回空（无窗口可排）。
    @discardableResult
    mutating func tileNow(pid: pid_t, orderedWindowKeys: [String]) -> [String] {
        if orderedWindowKeys.isEmpty {
            managed[pid] = nil
            return []
        }
        managed[pid] = orderedWindowKeys
        return orderedWindowKeys
    }

    /// 受管 app 新开一个窗口。按默认取舍：**不**扫入启用前就存在的未受管窗口——
    /// 新窗口加入受管集合，返回重排后的有序受管 key。已在集合中（重复事件）则原样返回、不重复追加。
    @discardableResult
    mutating func windowOpened(pid: pid_t, windowKey: String) -> [String] {
        var set = managed[pid] ?? []
        if !set.contains(windowKey) {
            set.append(windowKey)
            managed[pid] = set
        }
        return set
    }

    /// 受管窗口关闭/销毁。从集合移除并返回剩余需重排的有序 key（无剩余则空数组）。
    /// 该窗口本就不受管 → 返回 nil（调用方据此判断「无需重排」）。
    @discardableResult
    mutating func windowClosed(pid: pid_t, windowKey: String) -> [String]? {
        guard var set = managed[pid], let idx = set.firstIndex(of: windowKey) else { return nil }
        set.remove(at: idx)
        if set.isEmpty {
            managed[pid] = nil
            return []
        }
        managed[pid] = set
        return set
    }

    /// 该 pid 当前的有序受管 key（排布顺序）。
    func managedKeys(pid: pid_t) -> [String] { managed[pid] ?? [] }

    /// 某窗口是否在受管集合内。
    func isManaged(pid: pid_t, windowKey: String) -> Bool {
        managed[pid]?.contains(windowKey) ?? false
    }

    /// 丢弃该 pid 的全部受管状态（app 退出时调用，避免 key 泄漏 / PID 复用串味）。
    mutating func forget(pid: pid_t) { managed[pid] = nil }

    /// 是否有任何受管窗口（供调用方快速判断本引擎是否处于活动状态）。
    var isEmpty: Bool { managed.isEmpty }
}
