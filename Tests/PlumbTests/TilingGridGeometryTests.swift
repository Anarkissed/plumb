import CoreGraphics
import Testing
@testable import Plumb

// 多窗口网格平铺（互补区布局）的纯几何测试。坐标系为左下原点（与 tiledFrame 一致），
// 行 0 位于区域顶部（较大 y）。

@Test
func gridFourWindowsIs2x2NoGutter() async throws {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    let frames = WindowGeometry.gridFrames(region: region, count: 4, gutter: 0)

    #expect(frames.count == 4)
    // 行优先、左上角优先：top-left, top-right, bottom-left, bottom-right。
    #expect(frames[0] == CGRect(x: 0, y: 500, width: 500, height: 500))    // 顶行左
    #expect(frames[1] == CGRect(x: 500, y: 500, width: 500, height: 500))  // 顶行右
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 500, height: 500))      // 底行左
    #expect(frames[3] == CGRect(x: 500, y: 0, width: 500, height: 500))    // 底行右
}

@Test
func gridTwoWindowsIsSideBySide() async throws {
    let region = CGRect(x: 0, y: 0, width: 800, height: 600)

    let frames = WindowGeometry.gridFrames(region: region, count: 2, gutter: 0)

    #expect(frames.count == 2)
    #expect(frames[0] == CGRect(x: 0, y: 0, width: 400, height: 600))
    #expect(frames[1] == CGRect(x: 400, y: 0, width: 400, height: 600))
}

@Test
func gridThreeWindowsFillsShortLastRow() async throws {
    // 3 窗口：cols=2, rows=2。顶行 2 个各占半宽；末行 1 个铺满整行宽度。
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    let frames = WindowGeometry.gridFrames(region: region, count: 3, gutter: 0)

    #expect(frames.count == 3)
    #expect(frames[0] == CGRect(x: 0, y: 500, width: 500, height: 500))
    #expect(frames[1] == CGRect(x: 500, y: 500, width: 500, height: 500))
    #expect(frames[2] == CGRect(x: 0, y: 0, width: 1000, height: 500))   // 末行铺满
}

@Test
func gridAppliesGutterBetweenCells() async throws {
    let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    let frames = WindowGeometry.gridFrames(region: region, count: 4, gutter: 20)

    // 每轴：1000 - 1*20 = 980, /2 = 490。四周不留外边距。
    #expect(frames[0] == CGRect(x: 0, y: 510, width: 490, height: 490))     // 顶行左（x=0 贴左）
    #expect(frames[1] == CGRect(x: 510, y: 510, width: 490, height: 490))   // 顶行右（x=490+20）
    #expect(frames[3] == CGRect(x: 510, y: 0, width: 490, height: 490))     // 底行右（y=0 贴底）
}

@Test
func gridTallNarrowRegionStacksVertically() async throws {
    // 高窄区域（如小屏左半区 683×1024）+ 3 窗口 → 应竖向堆叠（单列全宽），
    // 而非分列成过窄的格子。这是修复「左右半区不生效」的核心行为。
    let region = CGRect(x: 0, y: 0, width: 683, height: 1024)

    let frames = WindowGeometry.gridFrames(region: region, count: 3, gutter: 0)

    #expect(frames.count == 3)
    // 单列：所有格子 x=0、宽度=整区宽（不被分列压窄）。
    #expect(frames.allSatisfy { $0.minX == 0 })
    #expect(frames.allSatisfy { abs($0.width - 683) <= 1 })
}

@Test
func gridMinCellWidthReducesColumns() async throws {
    // 600 宽的高区域，4 窗口：2 列会得到 300px 格（< 320 下限）→ 收敛到单列堆叠。
    let region = CGRect(x: 0, y: 0, width: 600, height: 1000)

    let frames = WindowGeometry.gridFrames(region: region, count: 4, gutter: 0, minCellWidth: 320)

    #expect(frames.count == 4)
    #expect(frames.allSatisfy { $0.minX == 0 })                 // 单列
    #expect(frames.allSatisfy { abs($0.width - 600) <= 1 })     // 全宽
}

@Test
func gridRespectsMinCellHeightAvoidingTooManyRows() async throws {
    // 1000×600, 3 窗口：单列每格 200px 高（< 260 下限，Finder 类会被 clamp）→ 改用 2 列
    //（2 上 + 1 下），格高 300。这是修复「Finder 竖向铺太多、底部留空」的核心。
    let region = CGRect(x: 0, y: 0, width: 1000, height: 600)

    let frames = WindowGeometry.gridFrames(region: region, count: 3, gutter: 0)

    #expect(frames.count == 3)
    #expect(abs(frames[0].width - 500) <= 1)     // 顶行两格各半宽（= 2 列）。
    #expect(abs(frames[1].width - 500) <= 1)
    #expect(abs(frames[2].width - 1000) <= 1)    // 末行 1 个铺满整行。
    #expect(frames.allSatisfy { $0.height >= 260 })   // 每格高度不低于下限。
}

@Test
func gridWideShortRegionLaysOutInOneRow() async throws {
    // 宽扁区域（上半区 1600×500）+ 4 窗口 → 横向一排（4 列 1 行）。
    let region = CGRect(x: 0, y: 0, width: 1600, height: 500)

    let frames = WindowGeometry.gridFrames(region: region, count: 4, gutter: 0)

    #expect(frames.count == 4)
    #expect(frames.allSatisfy { abs($0.height - 500) <= 1 })    // 单行：全高
    #expect(frames.allSatisfy { $0.minY == 0 })
}

@Test
func gridSingleWindowFillsRegion() async throws {
    let region = CGRect(x: 10, y: 20, width: 400, height: 300)

    let frames = WindowGeometry.gridFrames(region: region, count: 1, gutter: 8)

    #expect(frames == [region])
}

@Test
func gridZeroCountIsEmpty() async throws {
    let frames = WindowGeometry.gridFrames(region: CGRect(x: 0, y: 0, width: 100, height: 100), count: 0)
    #expect(frames.isEmpty)
}

@Test
func regionLeftHalfIsComplementOfRightHalf() async throws {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    let left = WindowGeometry.region(.leftHalf, of: visible)
    let right = WindowGeometry.region(.rightHalf, of: visible)

    #expect(left == CGRect(x: 0, y: 25, width: 720, height: 875))
    #expect(right == CGRect(x: 720, y: 25, width: 720, height: 875))
    // 两半相接、不重叠、合起来是整块 visibleFrame。
    #expect(left.maxX == right.minX)
}

@Test
func regionTopHalfIsUpperPortion() async throws {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let top = WindowGeometry.region(.topHalf, of: visible)
    let bottom = WindowGeometry.region(.bottomHalf, of: visible)

    #expect(top == CGRect(x: 0, y: 400, width: 1000, height: 400))     // 顶 = 较大 y
    #expect(bottom == CGRect(x: 0, y: 0, width: 1000, height: 400))
    #expect(bottom.maxY == top.minY)
}

@Test
func freeRegionRightWhenWindowSnappedLeft() async throws {
    // 占用窗口贴左半（split 左）→ 互补区 = 右半全高竖条。
    let usable = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let occupied = CGRect(x: 0, y: 0, width: 800, height: 1000)

    let free = try #require(WindowGeometry.freeRegionBeside(occupied: occupied, usable: usable))
    #expect(free == CGRect(x: 800, y: 0, width: 800, height: 1000))
}

@Test
func freeRegionLeftWhenWindowSnappedRight() async throws {
    let usable = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let occupied = CGRect(x: 800, y: 0, width: 800, height: 1000)

    let free = try #require(WindowGeometry.freeRegionBeside(occupied: occupied, usable: usable))
    #expect(free == CGRect(x: 0, y: 0, width: 800, height: 1000))
}

@Test
func freeRegionBottomWhenWindowSnappedTop() async throws {
    // 占用窗口贴上半（全宽）→ 互补区 = 下半全宽横条。
    let usable = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let occupied = CGRect(x: 0, y: 500, width: 1600, height: 500)

    let free = try #require(WindowGeometry.freeRegionBeside(occupied: occupied, usable: usable))
    #expect(free == CGRect(x: 0, y: 0, width: 1600, height: 500))
}

@Test
func freeRegionNilWhenWindowFillsScreen() async throws {
    let usable = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    #expect(WindowGeometry.freeRegionBeside(occupied: usable, usable: usable) == nil)
}

@Test
func freeRegionRespectsScreenOriginOffset() async throws {
    // 副屏 usable 原点非零（多屏全局坐标）：互补区应落在同一坐标系里，不回到原点。
    let usable = CGRect(x: 2000, y: 100, width: 1440, height: 900)
    let occupied = CGRect(x: 2000, y: 100, width: 720, height: 900)   // 左半

    let free = try #require(WindowGeometry.freeRegionBeside(occupied: occupied, usable: usable))
    #expect(free == CGRect(x: 2720, y: 100, width: 720, height: 900)) // 右半，含 x=2000 偏移
}

// 端到端组合：把 4 个窗口铺进 visibleFrame 的左半区（用户把某 app 钉在右半时的目标场景）。
@Test
func gridInLeftHalfRegionForComplementaryTiling() async throws {
    let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    let leftHalf = WindowGeometry.region(.leftHalf, of: visible)
    let frames = WindowGeometry.gridFrames(region: leftHalf, count: 4, gutter: 0)

    // 全部落在左半区内（x < 800）。
    #expect(frames.count == 4)
    #expect(frames.allSatisfy { $0.maxX <= 800 })
    #expect(frames[0] == CGRect(x: 0, y: 500, width: 400, height: 500))
    #expect(frames[3] == CGRect(x: 400, y: 0, width: 400, height: 500))
}
