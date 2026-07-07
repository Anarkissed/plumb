import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GridTilingController
//
// 模块角色：网格平铺的运行时编排器。把纯状态机（GridLayoutEngine）、设置（GridTilingSettingsStore）
// 与坐标写入（WindowCenteringService.placeWindowElement）粘合起来，并暴露给 Observer / 菜单 / 热键。
//
// 事件语义（用户确认的默认取舍）：
//   - 受管 app **新开**窗口（Observer 的 kAXWindowCreated）→ 只把**那个新窗口**加入受管集合并重排；
//     启用前就存在、且从未被「Tile now」纳入的窗口保持原位（不扫入）。
//   - 「Tile now」（菜单 / 全局热键）→ 把前台 app 当前全部窗口快照进受管集合并一次排布。
//   - 受管窗口关闭 → 下一次相关事件（focusedChanged / 再次 create）时 reconcile 修剪并回填重排。
//   - app 退出 → forget(pid)，避免 PID 复用串味。
//
// v1 范围：受管集合按「参考屏」（第一个受管窗口所在屏）过滤，只在同一块屏上排网格；
// 跨屏重排属后续细化。所有 AX 写入复用已验证的 placeWindowElement（坐标空间探测 + 兜底）。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GridTilingController {
    private let service: WindowCenteringService
    private let store: GridTilingSettingsStore
    private var engine = GridLayoutEngine()
    /// 每 pid 一个待执行的去抖重排（见 scheduleReflow）。新事件取消并替换上一个，只在窗口数 settle 后重排一次。
    private var pendingReflow: [pid_t: DispatchWorkItem] = [:]
    /// 每 pid 记住「最近一次铺进的区域」（左下原点全局坐标）。**自动**重排（开/关窗）沿用它——这样在
    /// 「beside-anchor 半屏 split」里关一个窗口，剩余窗口继续铺在那半屏，不会突然放大到全屏。只有用户
    /// **主动 Tile Now**（快捷键/菜单）才把它重置为全区（cfg.region）。见 Issue 2。
    private var lastTiledRegion: [pid_t: CGRect] = [:]
    /// Issue 1 自愈：动画落位后延时校验，若某窗口远大于其格子（没缩下去 → 仍近全屏）就强制重排一次。
    private var oversizeHealWork: [pid_t: DispatchWorkItem] = [:]

    init(service: WindowCenteringService, store: GridTilingSettingsStore) {
        self.service = service
        self.store = store
    }

    // MARK: - 查询

    /// 某 app 是否被标记为网格受管（持久设置）。
    func isManagedApp(bundleIdentifier: String?) -> Bool {
        store.load().isManaged(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - 事件入口（供 Observer 调用）

    /// 受管 app 新开一个窗口。`createdElement` 是 kAXWindowCreated 通知携带的元素（通常即新窗口）。
    /// 只把该新窗口加入受管集合并重排——不扫入启用前就存在的窗口（默认取舍）。
    func handleWindowCreated(pid: pid_t, appElement: AXUIElement, createdElement: AXUIElement, bundleIdentifier: String?) {
        guard isManagedApp(bundleIdentifier: bundleIdentifier) else { return }
        guard let window = resolveCreatedWindow(createdElement, appElement: appElement), isEligible(window) else {
            DiagnosticLog.debug("grid: windowCreated but no eligible window pid=\(pid)")
            return
        }
        let k = key(pid: pid, window: window)
        engine.windowOpened(pid: pid, windowKey: k)
        DiagnosticLog.debug("grid: window opened pid=\(pid) key=\(k) managed=\(engine.managedKeys(pid: pid).count)")
        scheduleReflow(pid: pid, appElement: appElement)
    }

    /// 焦点变化 / 周期性事件：**不**扫入新窗口，仅 reconcile（修剪已关闭的受管窗口）后回填重排。
    /// 用于「关闭一个受管窗口后剩余窗口回填」的常见路径，复用已注册的 focusedChanged 通知，
    /// 无需新增 AX 通知注册。受管集合未变化 → 不重排（避免无谓重写）。
    func handleReconcile(pid: pid_t, appElement: AXUIElement, bundleIdentifier: String?) {
        guard isManagedApp(bundleIdentifier: bundleIdentifier) else { return }
        guard !engine.managedKeys(pid: pid).isEmpty else { return }
        if pruneClosed(pid: pid, appElement: appElement) {
            DiagnosticLog.debug("grid: reconcile pruned closed window(s) pid=\(pid) → reflow")
            scheduleReflow(pid: pid, appElement: appElement)
        }
    }

    /// **合并/去抖**自动平铺的重排：关窗/开窗时窗口数会短暂抖动（Finder 关窗后 AXWindows 列表滞后更新，
    /// 或窗口在开/关动画中短暂进出资格），若每个事件都立刻按当时数量重排，就会在「N 窗布局」与
    /// 「N±1 窗布局」之间来回抖（用户报告的 twitch）。改为：取消上一个待执行重排，延时 `delay` 后只做一次——
    /// 让窗口数先 settle，再按最终数量一次性排好，refresh 保持一致。用户主动的 Tile Now / 预览仍即时重排（不走此）。
    private func scheduleReflow(pid: pid_t, appElement: AXUIElement, delay: TimeInterval = 0.2) {
        pendingReflow[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingReflow[pid] = nil
                self.reflow(pid: pid, appElement: appElement)
            }
        }
        pendingReflow[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 「Tile now」（菜单 / ⌥⌘T）。**行为随前台 app 自适应**：
    ///   - 前台 app **本身受管** → 把它当前全部窗口铺进设置里选的区域（Full/半区），在它所在屏。
    ///   - 前台 app **不受管**（= 你正看着的「锚点」app，如 Split View 里钉住的 Claude Desktop）
    ///     → 把**其它受管 app**（如 Finder）的窗口铺进锚点窗口**没占用**的互补区，在锚点所在屏。
    /// 这正是「聚焦 Claude、按 ⌥⌘T → Finder 铺到 Claude 不在的那一侧」；也天然作用于聚焦所在的显示器。
    @discardableResult
    func tileNowFrontmost() -> Bool {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else {
            DiagnosticLog.debug("grid: tileNow — accessibility not trusted")
            return false
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            DiagnosticLog.debug("grid: tileNow — no frontmost app")
            return false
        }
        let pid = app.processIdentifier
        // 前台恰是 Plumb 自己（打开状态栏菜单可能短暂夺焦）→ 放弃；用 ⌥⌘T 热键（前台仍是用户所在 app）。
        if pid == ProcessInfo.processInfo.processIdentifier {
            DiagnosticLog.debug("grid: tileNow — frontmost is Plumb itself; use the ⌥⌘T hotkey instead of the menu")
            return false
        }

        if isManagedApp(bundleIdentifier: app.bundleIdentifier) {
            return tileManagedAppIntoRegion(pid: pid, app: app)
        }
        return tileManagedAppsBesideAnchor(anchorApp: app)
    }

    /// 前台受管 app：把它当前全部窗口铺进设置区域（走 engine 受管集合 + reflow）。
    private func tileManagedAppIntoRegion(pid: pid_t, app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        let wins = onScreenEligibleWindows(pid: pid, appElement: appElement)
        DiagnosticLog.debug("grid: tileNow(managed) pid=\(pid) bundle=\(app.bundleIdentifier ?? "?") eligible=\(wins.count)")
        guard !wins.isEmpty else { return false }
        engine.tileNow(pid: pid, orderedWindowKeys: orderedByPosition(wins).map(\.key))
        // 用户主动 Tile Now → 铺进全区（并记住），符合「主动 tile 才占满屏」的预期（Issue 2）。
        reflow(pid: pid, appElement: appElement, resetRegion: true)
        return true
    }

    /// 前台 app **在聚焦显示器的当前 Space 上、实际可见**的可平铺窗口。
    /// 用 CGWindowList 的屏上集合（`service.onScreenWindowFrames`）过滤 AX 窗口——只保留 frame 与某个
    /// 屏上窗口吻合的。这排除了别的 Space / 最小化的窗口（它们仍在 AX kAXWindows 里，且 AX 屏归属探测
    /// 不稳，是「窗口数在 6~8 间乱跳」的根因）。再按**聚焦屏**收窄：只保留在聚焦窗口所在显示器上的窗口
    /// （多屏时只铺你正看着的那块屏）。CG 不可用或匹配为空时回退到不过滤（避免「无反应」回归）。
    private func onScreenEligibleWindows(pid: pid_t, appElement: AXUIElement) -> [(key: String, element: AXUIElement)] {
        let wins = currentEligibleWindows(pid: pid, appElement: appElement)
        let onScreen = service.onScreenWindowFrames(pid: pid)
        guard !onScreen.isEmpty else { return wins }

        // 聚焦屏 = 前台 app 聚焦窗口所在显示器；据此把屏上集合收窄到该屏。探测不到 → 不按屏收窄。
        let focusedScreenFrame = self.focusedScreenFrame(appElement: appElement, pid: pid, onScreen: onScreen)
        let scoped = focusedScreenFrame.map { fsf in onScreen.filter { $0.screenFrame == fsf } } ?? onScreen
        let scopedFrames = (scoped.isEmpty ? onScreen : scoped).map(\.frame)

        let visible = wins.filter { w in
            guard let f = service.globalFrame(of: w.element, pid: pid) else { return true }  // 探测失败 → 保留
            return scopedFrames.contains { s in
                abs(s.minX - f.minX) <= 12 && abs(s.minY - f.minY) <= 12 &&
                abs(s.width - f.width) <= 12 && abs(s.height - f.height) <= 12
            }
        }
        return visible.isEmpty ? wins : visible
    }

    /// 聚焦显示器的 frame：前台 app 聚焦窗口所在屏。优先「聚焦窗口 frame 命中屏上某窗口 → 用其屏」；
    /// 退而用几何包含（窗口中心落在哪块屏）；再退到主屏。纯几何 / CG，稳定，不走易抖的 AX 屏探测。
    private func focusedScreenFrame(appElement: AXUIElement, pid: pid_t,
                                    onScreen: [(frame: CGRect, screenFrame: CGRect)]) -> CGRect? {
        guard let focused = appElement.axWindowElement(kAXFocusedWindowAttribute as CFString),
              let ff = service.globalFrame(of: focused, pid: pid) else {
            return NSScreen.main?.frame
        }
        if let hit = onScreen.first(where: { s in
            abs(s.frame.minX - ff.minX) <= 12 && abs(s.frame.minY - ff.minY) <= 12 &&
            abs(s.frame.width - ff.width) <= 12 && abs(s.frame.height - ff.height) <= 12
        }) {
            return hit.screenFrame
        }
        let center = CGPoint(x: ff.midX, y: ff.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame ?? NSScreen.main?.frame
    }

    /// 稳定的窗口排序（上→下、左→右），用于把窗口分配到网格格子。
    private func orderedByPosition(_ wins: [(key: String, element: AXUIElement)]) -> [(key: String, element: AXUIElement)] {
        wins.sorted { a, b in
            let pa = a.element.axPoint(kAXPositionAttribute as CFString) ?? .zero
            let pb = b.element.axPoint(kAXPositionAttribute as CFString) ?? .zero
            if abs(pa.y - pb.y) > 8 { return pa.y < pb.y }
            return pa.x < pb.x
        }
    }

    // MARK: - Tile Layout 菜单（每 app 记忆布局 + hover 实时预览）

    /// 「Tile Layout」子菜单构建 + 预览所需的前台 app 上下文。
    struct LayoutPickerContext {
        let pid: pid_t
        let bundleID: String
        let appElement: AXUIElement
        let windowCount: Int
        let chosenColumns: Int?   // 当前已记忆的列数（nil = 自动）。
    }

    private var previewSnapshot: [(element: AXUIElement, frame: (position: CGPoint, size: CGSize))] = []
    private var previewContext: LayoutPickerContext?
    private var previewCommitted = false

    /// 供菜单构建：前台 app + 其在参考屏上的可平铺窗口数。返回 nil 表示不适用
    ///（前台是 Plumb 自己 / 无 bundle / 可平铺窗口 < 2）。
    func frontmostLayoutPickerContext() -> LayoutPickerContext? {
        guard AccessibilityPermission.ensureTrusted(prompt: false),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        guard let rawBundle = app.bundleIdentifier else { return nil }
        let bundleID = AppTilingSettings.normalizeBundleID(rawBundle)
        let appElement = AXUIElementCreateApplication(pid)
        let wins = onScreenEligibleWindows(pid: pid, appElement: appElement)
        let axCount = currentEligibleWindows(pid: pid, appElement: appElement).count
        DiagnosticLog.debug("grid: layoutPickerContext bundle=\(bundleID) onScreen=\(wins.count) axTotal=\(axCount)")
        guard wins.count >= 2 else { return nil }
        // 不记忆布局 → 无「当前选中」勾选（选择只应用当下）。
        return LayoutPickerContext(pid: pid, bundleID: bundleID, appElement: appElement, windowCount: wins.count, chosenColumns: nil)
    }

    /// 子菜单打开时调用：抓取前台 app 可平铺窗口的原始 frame 快照（供关闭时还原），并**一次性**固定
    /// 窗口→格子顺序（此后各 hover 仅换列数、不重排，避免预览时窗口错位跳动）。
    func beginLayoutPreview() {
        cancelLayoutPreview()   // 清理上一次残留（未提交则已在 menuDidClose 还原）。
        guard let ctx = frontmostLayoutPickerContext() else { return }
        previewContext = ctx
        previewCommitted = false
        let wins = onScreenEligibleWindows(pid: ctx.pid, appElement: ctx.appElement)
        previewSnapshot = wins.compactMap { w in
            service.rawAXFrame(of: w.element).map { (w.element, $0) }
        }
        engine.tileNow(pid: ctx.pid, orderedWindowKeys: orderedByPosition(wins).map(\.key))
    }

    /// hover 某布局：把前台 app 窗口用该列数**瞬时**铺开（不持久化、不动画 → 连续 hover 不叠加抖动）。
    func previewLayoutColumns(_ columns: Int) {
        guard let ctx = previewContext else { return }
        reflow(pid: ctx.pid, appElement: ctx.appElement, columnsOverride: columns, animated: false)
    }

    /// 点选某布局：**只应用当下**（不持久化、不记忆），保留铺开结果，不再还原。之后的开/关窗自动重排
    /// 回到自动列数——不会「记住」这次选择再冒出来干扰（用户偏好）。
    func commitLayoutColumns(_ columns: Int) {
        guard let ctx = previewContext else { return }
        reflow(pid: ctx.pid, appElement: ctx.appElement, columnsOverride: columns, animated: false)
        previewCommitted = true
        DiagnosticLog.debug("grid: layout applied (not remembered) bundle=\(ctx.bundleID) count=\(ctx.windowCount) columns=\(columns)")
        previewContext = nil
        previewSnapshot = []
    }

    /// 关闭菜单且未点选：把窗口还原到快照的原始位置/尺寸。
    func cancelLayoutPreview() {
        if !previewCommitted, !previewSnapshot.isEmpty {
            for (el, f) in previewSnapshot { service.restoreRawAXFrame(f, to: el) }
        }
        previewSnapshot = []
        previewContext = nil
        previewCommitted = false
    }

    /// 前台是「锚点」（非受管）app：把其它受管 app 的窗口铺进锚点窗口没占用的互补区。
    ///
    /// 关键约束：AX 尺寸写入仅在目标 app 前台时生效——故对每个受管 app 先 `activate`、settle 后再写入
    ///（与 SelfTestTileApp 一致）。分组按 app 串行 activate + 延时写入。锚点窗口本身不被触碰。
    private func tileManagedAppsBesideAnchor(anchorApp: NSRunningApplication) -> Bool {
        let anchorPID = anchorApp.processIdentifier
        let anchorAppEl = AXUIElementCreateApplication(anchorPID)
        guard let focused = anchorAppEl.axWindowElement(kAXFocusedWindowAttribute as CFString) else {
            DiagnosticLog.debug("grid: tileNow(anchor) — anchor has no focused window")
            return false
        }
        guard let anchorFrame = service.globalFrame(of: focused, pid: anchorPID),
              let anchorScreen = service.screenForWindow(focused, pid: anchorPID) ?? NSScreen.main else {
            DiagnosticLog.debug("grid: tileNow(anchor) — cannot resolve anchor frame/screen")
            return false
        }
        let cfg = store.load()
        let usable = service.usableFrame(for: anchorScreen)
        guard let free = WindowGeometry.freeRegionBeside(occupied: anchorFrame, usable: usable) else {
            DiagnosticLog.debug("grid: tileNow(anchor) — no free region beside anchor (fills screen?) frame=\(anchorFrame) usable=\(usable)")
            return false
        }

        // 收集受管 app（排除锚点 app 自己）的窗口，按 app 分组。
        let anchorBundle = anchorApp.bundleIdentifier.map(AppTilingSettings.normalizeBundleID)
        var groups: [(pid: pid_t, appEl: AXUIElement, windows: [AXUIElement])] = []
        var total = 0
        for running in NSWorkspace.shared.runningApplications {
            guard let bid = running.bundleIdentifier.map(AppTilingSettings.normalizeBundleID),
                  cfg.managedBundleIDs.contains(bid), bid != anchorBundle else { continue }
            let mpid = running.processIdentifier
            let mAppEl = AXUIElementCreateApplication(mpid)
            let wins = currentEligibleWindows(pid: mpid, appElement: mAppEl).map(\.element)
            guard !wins.isEmpty else { continue }
            groups.append((mpid, mAppEl, wins))
            total += wins.count
        }
        guard total > 0 else {
            DiagnosticLog.debug("grid: tileNow(anchor) — no managed windows to tile beside anchor")
            return false
        }

        DiagnosticLog.debug("grid: tileNow(anchor) bundle=\(anchorApp.bundleIdentifier ?? "?") screen=\(anchorScreen.frame) free=\(free) apps=\(groups.count) totalWindows=\(total)")
        placeGroupsBeside(groups: groups, free: free, gutter: cfg.gutter, targetScreen: anchorScreen)
        return true
    }

    /// 串行处理各受管 app：activate → settle → 把该组窗口铺进 free 区域 → 下一组。
    ///
    /// **每个 app 独立铺满 free 区域**（像它是唯一被选中的 app）——不再把多个 app 的窗口挤进一个共享网格。
    /// 于是各 app 都拥有一套完整平铺，彼此叠放；⌘-Tab 在它们之间切换即可看到各自的完整平铺。
    /// activate 后需短暂 settle，AX 尺寸写入才对刚激活的 app 生效（见 tileManagedAppsBesideAnchor 注释）。
    private func placeGroupsBeside(
        groups: [(pid: pid_t, appEl: AXUIElement, windows: [AXUIElement])],
        free: CGRect,
        gutter: CGFloat,
        targetScreen: NSScreen
    ) {
        guard let group = groups.first else { return }
        let rest = Array(groups.dropFirst())
        NSRunningApplication(processIdentifier: group.pid)?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 本 app 独立成网格铺满 free（按其自身窗口数）。
                let frames = WindowGeometry.gridFrames(region: free, count: group.windows.count, gutter: gutter)
                for (i, w) in group.windows.enumerated() where i < frames.count {
                    do {
                        try self.service.placeWindowOnScreen(w, pid: group.pid, appElement: group.appEl, targetFrame: frames[i], targetScreen: targetScreen)
                    } catch {
                        DiagnosticLog.debug("grid: beside-anchor place FAILED pid=\(group.pid) error=\(error)")
                    }
                    // 读回实际 frame 与目标对比——若尺寸被 clamp（如 Finder 最小高度），此处可见。
                    let actual = self.service.globalFrame(of: w, pid: group.pid)
                    DiagnosticLog.debug("grid: beside-anchor pid=\(group.pid) target=\(frames[i]) actual=\(actual.map { String(describing: $0) } ?? "nil")")
                }
                // 记住这批窗口铺进的是 free 半区，并把它们纳入引擎受管——这样之后在这个 app 里开/关窗口时，
                // **自动重排**会继续铺在 free 半区（保持 split），不会跳回全屏（Issue 2）。
                self.lastTiledRegion[group.pid] = free
                self.engine.tileNow(pid: group.pid, orderedWindowKeys: self.orderedByPosition(
                    group.windows.map { (key: self.key(pid: group.pid, window: $0), element: $0) }
                ).map(\.key))
                self.placeGroupsBeside(groups: rest, free: free, gutter: gutter, targetScreen: targetScreen)
            }
        }
    }

    /// app 退出：丢弃其受管状态。
    func appTerminated(pid: pid_t) {
        pendingReflow[pid]?.cancel()
        pendingReflow[pid] = nil
        oversizeHealWork[pid]?.cancel()
        oversizeHealWork[pid] = nil
        lastTiledRegion[pid] = nil
        engine.forget(pid: pid)
    }

    // MARK: - 重排

    /// 把该 pid 的受管窗口（引擎有序）铺进目标区域网格。
    /// `columnsOverride` 非空时强制用该列数（实时预览用）；否则查「该 app+窗口数」记忆的列数，再否则自动推断。
    /// `animated=false` 用于实时预览：**瞬时**落位。
    /// `resetRegion=true`（用户主动 Tile Now）→ 铺进全区并记住；否则沿用 `lastTiledRegion`（保持半屏 split）。
    private func reflow(pid: pid_t, appElement: AXUIElement, columnsOverride: Int? = nil, animated: Bool = true, resetRegion: Bool = false) {
        _ = pruneClosed(pid: pid, appElement: appElement)
        let orderedKeys = engine.managedKeys(pid: pid)
        guard !orderedKeys.isEmpty else { return }

        let byKey = Dictionary(currentEligibleWindows(pid: pid, appElement: appElement).map { ($0.key, $0.element) },
                               uniquingKeysWith: { first, _ in first })
        // 按引擎顺序取出仍存在的窗口元素。
        var elements: [(key: String, element: AXUIElement)] = []
        for k in orderedKeys {
            if let e = byKey[k] { elements.append((k, e)) }
        }
        guard let first = elements.first else { return }

        // 参考屏 = 第一个受管窗口所在屏（探测失败则回退到主屏 / 前台窗口所在屏）。
        // v1 假设受管窗口在同一屏：全部铺进参考屏的区域网格，**不**再按屏过滤——
        // 旧实现用 screenForWindow 逐窗过滤，一旦探测返回 nil 就把所有窗口过滤空 → 静默什么都不做
        //（"Tile now 无反应" 的根因之一）。跨屏细化留待后续。
        guard let refScreen = service.screenForWindow(first.element, pid: pid) ?? NSScreen.main else {
            DiagnosticLog.debug("grid: reflow no reference screen pid=\(pid)")
            return
        }

        // 仅在参考屏上排网格：排除其它显示器上的同 app 窗口（它们不应占用本屏格子）。
        // 探测失败(nil) → 按「同屏」保留；过滤后为空则回退全部——双重兜底防「无反应」回归。
        if elements.count > 1 {
            let onRef = elements.filter { service.windowIsOnScreen($0.element, pid: pid, screen: refScreen) != false }
            if !onRef.isEmpty { elements = onRef }
        }

        let cfg = store.load()
        let usable = service.usableFrame(for: refScreen)
        let fullRegion = WindowGeometry.region(cfg.region.geometryRegion, of: usable)
        // 主动 Tile Now → 全区并记住；自动重排 → 沿用记住的区域（保持半屏 split）；都没有 → 全区。
        let region: CGRect
        if resetRegion {
            region = fullRegion
            lastTiledRegion[pid] = fullRegion
        } else {
            region = lastTiledRegion[pid] ?? fullRegion
        }
        // 布局选择「只应用一次、不记忆」（用户偏好：记忆会在使用中造成意外）。自动重排一律走**自动列数**推断；
        // `columnsOverride` 只在当下的实时预览 / 点选那一刻生效，不落盘、不影响之后的开/关窗重排。
        let cols = columnsOverride
        let frames = WindowGeometry.gridFrames(region: region, count: elements.count, gutter: cfg.gutter, columns: cols)
        DiagnosticLog.debug("grid: reflow pid=\(pid) windows=\(elements.count) region=\(region) frames=\(frames.count) cols=\(cols.map(String.init) ?? "auto") reset=\(resetRegion)")

        // 开始新一轮排布前，取消所有在飞的动画——否则连续 reflow（尤其 hover 预览）会把多套动画
        // 叠加到同一批窗口上互相覆盖，窗口在两个目标间反复横跳（twitch），并投递海量自铺 move/resize。
        service.abortActiveAnimations()

        var movedAny = false
        for (i, item) in elements.enumerated() where i < frames.count {
            // 幂等：窗口已在目标位（容差内）→ 跳过。若全部已就位则本次 reflow 零写入、零通知，
            // 从根上斩断「落位→通知→再排」的反馈抖动；也让重复 reflow 收敛为不动点。
            if let current = service.globalFrame(of: item.element, pid: pid),
               abs(current.minX - frames[i].minX) <= 6, abs(current.minY - frames[i].minY) <= 6,
               abs(current.width - frames[i].width) <= 6, abs(current.height - frames[i].height) <= 6 {
                continue
            }
            do {
                if animated {
                    // 带动画落位（多窗口并发，各自独立动画；结束后精确落位兜底）。
                    try service.placeWindowElementAnimated(item.element, pid: pid, appElement: appElement, targetFrame: frames[i])
                } else {
                    // 瞬时落位（预览/提交）：立刻吸附，无动画 → 无叠加。
                    try service.placeWindowElement(item.element, pid: pid, appElement: appElement, targetFrame: frames[i])
                }
                movedAny = true
                DiagnosticLog.debug("grid: placing (\(animated ? "animated" : "instant")) key=\(item.key) → \(frames[i])")
            } catch {
                DiagnosticLog.debug("grid: place FAILED pid=\(pid) key=\(item.key) error=\(error)")
            }
        }
        if !movedAny {
            DiagnosticLog.debug("grid: reflow no-op — all \(elements.count) window(s) already in place pid=\(pid)")
        }

        // Issue 1 自愈：动画落位后有时**某一个**窗口没缩进格子、仍近全屏（app 首次被要求平铺时最常见——
        // 疑似首帧尺寸写入被拒 / 坐标空间探测瞬时偏差）。延时校验：谁远大于自己的格子就瞬时强制重排一次。
        // 也把 target/actual 记进日志，便于定位根因。
        if movedAny {
            let placed = elements.enumerated().compactMap { (i, item) -> (AXUIElement, CGRect)? in
                i < frames.count ? (item.element, frames[i]) : nil
            }
            scheduleOversizeHeal(pid: pid, appElement: appElement, placed: placed)
        }
    }

    /// 落位后延时校验：谁的实际尺寸远超其目标格子（宽或高 > 目标 + 150px，即「没缩下去 / 仍近全屏」），
    /// 就瞬时强制重排一次并记录。只做一次（不循环），避免与顽固 app 死磕。
    private func scheduleOversizeHeal(pid: pid_t, appElement: AXUIElement, placed: [(AXUIElement, CGRect)]) {
        oversizeHealWork[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.oversizeHealWork[pid] = nil
                for (el, target) in placed {
                    guard let cur = self.service.globalFrame(of: el, pid: pid) else { continue }
                    if cur.width > target.width + 150 || cur.height > target.height + 150 {
                        DiagnosticLog.debug("grid: oversize-heal pid=\(pid) target=\(target) actual=\(cur) → re-place")
                        try? self.service.placeWindowElement(el, pid: pid, appElement: appElement, targetFrame: target)
                    }
                }
            }
        }
        oversizeHealWork[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 修剪受管集合里已不存在（关闭/最小化到无窗口编号）的窗口 key。返回是否有修剪发生。
    @discardableResult
    private func pruneClosed(pid: pid_t, appElement: AXUIElement) -> Bool {
        let present = Set(currentEligibleWindows(pid: pid, appElement: appElement).map(\.key))
        var changed = false
        for k in engine.managedKeys(pid: pid) where !present.contains(k) {
            engine.windowClosed(pid: pid, windowKey: k)
            changed = true
        }
        return changed
    }

    // MARK: - AX 枚举 / 键 / 资格

    private func currentEligibleWindows(pid: pid_t, appElement: AXUIElement) -> [(key: String, element: AXUIElement)] {
        appElement.axWindowElements(kAXWindowsAttribute as CFString)
            .filter { isEligible($0) }
            .map { (key: key(pid: pid, window: $0), element: $0) }
    }

    /// 与 Observer 同构的窗口 key：优先 AXWindowNumber，缺失回退 CFHash。
    private func key(pid: pid_t, window: AXUIElement) -> String {
        if let n = window.axPositiveInteger("AXWindowNumber" as CFString) {
            return "\(pid):\(n)"
        }
        return "\(pid):ax:\(CFHash(window))"
    }

    /// kAXWindowCreated 携带的元素通常即新窗口；若不是窗口角色，回退到 app 的当前聚焦窗口。
    private func resolveCreatedWindow(_ element: AXUIElement, appElement: AXUIElement) -> AXUIElement? {
        if element.axString(kAXRoleAttribute as CFString) == (kAXWindowRole as String) {
            return element
        }
        return appElement.axWindowElement(kAXFocusedWindowAttribute as CFString)
    }

    /// 网格资格：标准窗口（有可读尺寸；若能读到 subrole 则必须是 AXStandardWindow）。
    /// 排除面板 / 抽屉 / 表单等非标准窗口（与自动居中的资格取向一致，从简）。
    private func isEligible(_ window: AXUIElement) -> Bool {
        guard window.axSize(kAXSizeAttribute as CFString) != nil else { return false }
        // 最小化窗口（收进 Dock、屏上不可见）仍留在 AXWindows 列表里。若计入网格，就会为看不见的窗口
        // 预留一个格子 → 可见窗口按 N+1 排布、数量对不上（用户报告的 miscount）。排除之。
        if window.axBool(kAXMinimizedAttribute as CFString) == true { return false }
        // 全屏窗口（独占 Space）无法被 AX 移动/缩放——计入网格只会预留一个永远填不上的空格
        //（`place FAILED … fullscreenWindow`），令平铺永远缺一块。直接排除。
        if service.isFullscreen(window) { return false }
        if let subrole = window.axString(kAXSubroleAttribute as CFString) {
            return subrole == (kAXStandardWindowSubrole as String)
        }
        return true
    }
}
