import Testing
@testable import Plumb

// GridLayoutEngine 受管集合状态机的行为测试。验证用户确认的默认取舍：
// 新窗口加入受管集合并重排；启用前存在的窗口只有「Tile now」才纳入；关闭则回填。

@Test
func enablingDoesNotManageAnyWindowUntilEvent() async throws {
    let engine = GridLayoutEngine()
    // 仅标记受管（发生在 store，不在引擎）——引擎受管集合应为空、不动任何窗口。
    #expect(engine.managedKeys(pid: 42).isEmpty)
    #expect(engine.isEmpty)
}

@Test
func newWindowsTileAmongThemselvesNotPreexisting() async throws {
    var engine = GridLayoutEngine()
    // 启用前已存在 "42:1"、"42:2" —— 它们从未进入引擎（未 Tile now），故保持原位。
    // 新开 "42:9"：只有它进入受管集合。
    let after1 = engine.windowOpened(pid: 42, windowKey: "42:9")
    #expect(after1 == ["42:9"])            // 首个新窗口：独占区域（1 格）

    let after2 = engine.windowOpened(pid: 42, windowKey: "42:10")
    #expect(after2 == ["42:9", "42:10"])   // 第二个新窗口：与前一个组成网格

    // 老窗口 "42:1"/"42:2" 不在受管集合内。
    #expect(engine.isManaged(pid: 42, windowKey: "42:1") == false)
    #expect(engine.isManaged(pid: 42, windowKey: "42:9"))
}

@Test
func tileNowSnapshotsAllCurrentWindows() async throws {
    var engine = GridLayoutEngine()
    // Tile now 传入当前全部窗口（调用方已按屏幕位置排序）。
    let laid = engine.tileNow(pid: 42, orderedWindowKeys: ["42:1", "42:2", "42:3", "42:4"])
    #expect(laid == ["42:1", "42:2", "42:3", "42:4"])
    #expect(engine.managedKeys(pid: 42).count == 4)
    #expect(engine.isManaged(pid: 42, windowKey: "42:1"))
}

@Test
func newWindowAfterTileNowJoinsAndReflows() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1", "42:2"])
    let after = engine.windowOpened(pid: 42, windowKey: "42:3")
    #expect(after == ["42:1", "42:2", "42:3"])   // 新窗口追加到末尾，全体重排
}

@Test
func closingManagedWindowReflowsRemaining() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1", "42:2", "42:3"])
    let remaining = engine.windowClosed(pid: 42, windowKey: "42:2")
    #expect(remaining == ["42:1", "42:3"])       // 中间关闭 → 剩余回填重排
}

@Test
func closingLastManagedWindowClearsState() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1"])
    let remaining = engine.windowClosed(pid: 42, windowKey: "42:1")
    #expect(remaining == [])                      // 空数组 = 无剩余需排
    #expect(engine.managedKeys(pid: 42).isEmpty)
    #expect(engine.isEmpty)
}

@Test
func closingUnmanagedWindowReturnsNil() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1"])
    // "42:99" 不受管 → nil（调用方据此不重排）。
    #expect(engine.windowClosed(pid: 42, windowKey: "42:99") == nil)
}

@Test
func duplicateOpenEventDoesNotDuplicateKey() async throws {
    var engine = GridLayoutEngine()
    engine.windowOpened(pid: 42, windowKey: "42:9")
    let again = engine.windowOpened(pid: 42, windowKey: "42:9")
    #expect(again == ["42:9"])                    // 重复事件不重复追加
}

@Test
func tileNowWithNoWindowsClearsSet() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1", "42:2"])
    let laid = engine.tileNow(pid: 42, orderedWindowKeys: [])
    #expect(laid == [])
    #expect(engine.managedKeys(pid: 42).isEmpty)
}

@Test
func forgetDropsPidState() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 42, orderedWindowKeys: ["42:1", "42:2"])
    engine.forget(pid: 42)
    #expect(engine.managedKeys(pid: 42).isEmpty)
    #expect(engine.isEmpty)
}

@Test
func managedSetsAreIsolatedPerPid() async throws {
    var engine = GridLayoutEngine()
    engine.tileNow(pid: 1, orderedWindowKeys: ["1:1"])
    engine.windowOpened(pid: 2, windowKey: "2:5")
    #expect(engine.managedKeys(pid: 1) == ["1:1"])
    #expect(engine.managedKeys(pid: 2) == ["2:5"])
    engine.forget(pid: 1)
    #expect(engine.managedKeys(pid: 2) == ["2:5"])   // 忘记 pid 1 不影响 pid 2
}
