import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tile Layout 菜单（可视化布局选择 + hover 实时预览）
//
// 「Tile Layout」子菜单：为前台 app 当前窗口数列出所有网格形态（每个列数一种），每项画一个**微缩网格
// 图标**（用真实的 WindowGeometry.gridFrames 渲染，与实际落位一致）。hover 某项 → 真实窗口即时铺成该布局
// （GridTilingController 的预览接口）；点选 → 持久化「该 app + 窗口数」的列数并保留；关闭菜单未点选 → 还原。
//
// 为什么用自定义 NSView 菜单项：NSMenuItem 无法画网格缩略图，也无法在 hover 时驱动副作用（实时预览）。
// 自定义 view + tracking area 是 AppKit 里做「菜单内可视选择 + hover 预览」的标准做法。
// ─────────────────────────────────────────────────────────────────────────────

/// 单个布局选项：左侧微缩网格图标 + 右侧「列×行」文字；hover 高亮并触发预览，点击提交。
final class TileLayoutOptionView: NSView {
    private let columns: Int
    private let windowCount: Int
    private let isChosen: Bool
    private let onHover: () -> Void
    private let onSelect: () -> Void

    private var highlighted = false

    init(columns: Int, windowCount: Int, isChosen: Bool, width: CGFloat,
         onHover: @escaping () -> Void, onSelect: @escaping () -> Void) {
        self.columns = columns
        self.windowCount = windowCount
        self.isChosen = isChosen
        self.onHover = onHover
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        highlighted = true
        needsDisplay = true
        onHover()
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onSelect()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 选中背景（系统强调色圆角条），与原生菜单高亮观感一致。
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 5, yRadius: 5).fill()
        }

        let fg: NSColor = highlighted ? .white : .labelColor
        let cellColor: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.9) : NSColor.secondaryLabelColor

        // 微缩网格图标：用真实 gridFrames（列数显式、去掉最小尺寸约束）渲染，形态与实际落位一致。
        let iconRect = NSRect(x: 16, y: 6, width: 34, height: 18)
        let frames = WindowGeometry.gridFrames(
            region: CGRect(x: iconRect.minX, y: iconRect.minY, width: iconRect.width, height: iconRect.height),
            count: windowCount, gutter: 1.5, minCellWidth: 0, minCellHeight: 0, columns: columns
        )
        cellColor.setFill()
        for f in frames {
            NSBezierPath(roundedRect: f, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // 文字：列×行（+ 已记忆布局打勾）。
        let rows = WindowGeometry.gridRows(count: windowCount, columns: columns)
        var label = "\(columns) × \(rows)"
        if isChosen { label += "  ✓" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: fg,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: 62, y: (bounds.height - size.height) / 2))
    }
}

/// 「Tile Layout」子菜单的持有者兼 delegate：菜单打开时按前台 app 窗口数重建选项 + 开始预览，
/// 关闭时还原（若未点选）。作为 AppDelegate 的强引用属性保活。
@MainActor
final class TileLayoutMenuController: NSObject, NSMenuDelegate {
    let menuItem: NSMenuItem
    private weak var gridController: GridTilingController?
    private let submenu = NSMenu(title: "Tile Layout")

    init(gridController: GridTilingController) {
        self.gridController = gridController
        self.menuItem = NSMenuItem(title: "Tile Layout", action: nil, keyEquivalent: "")
        super.init()
        menuItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        submenu.autoenablesItems = false
        submenu.delegate = self
        menuItem.submenu = submenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let gridController, let ctx = gridController.frontmostLayoutPickerContext() else {
            let item = NSMenuItem(title: "Focus an app with 2+ windows", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        // 抓快照 + 固定顺序，供 hover 预览与关闭还原。
        gridController.beginLayoutPreview()

        let width: CGFloat = 240
        for columns in WindowGeometry.candidateColumnCounts(for: ctx.windowCount) {
            let item = NSMenuItem()
            item.view = TileLayoutOptionView(
                columns: columns,
                windowCount: ctx.windowCount,
                isChosen: ctx.chosenColumns == columns,
                width: width,
                onHover: { [weak gridController] in gridController?.previewLayoutColumns(columns) },
                onSelect: { [weak gridController, weak menu] in
                    gridController?.commitLayoutColumns(columns)
                    menu?.cancelTracking()
                }
            )
            menu.addItem(item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // 未点选 → 还原到打开菜单前的窗口布局（commit 会置 previewCommitted=true，此处则不还原）。
        gridController?.cancelLayoutPreview()
    }
}
