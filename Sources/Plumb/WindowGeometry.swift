import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WindowGeometry
//
// 模块角色：纯几何计算（无 AppKit 依赖，完全可单测）。
//
// 职责：把"居中 / 约束 / 平铺 / 可用区 inset"这些数学下沉为纯函数：
//   - centeredOrigin   ：在 visibleFrame 内居中（含 best-effort 夹取，不溢出）。
//   - constrainedOrigin：把任意原点约束进 bounds（用于把远离屏幕的窗口先拉回可视区）。
//   - tiledFrame       ：visibleFrame 内缩四向 insets 得到平铺目标（带防负/防塌缩保护）。
//   - insetsFromVisibleFrame：从 frame 与 visibleFrame 反推逐边 inset（让 Dock 在
//     左/右/下、菜单栏在顶的逐屏差异可独立测试）。
//
// 不变量：所有返回坐标都四舍五入到整数像素（与 AX 写入一致，便于测试断言）。
// ─────────────────────────────────────────────────────────────────────────────

enum WindowGeometry {
    static func centeredOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        // Center relative to the usable region (visibleFrame). If the window is larger than the visible area on
        // an axis, we keep the centered origin (best-effort) instead of clamping to an edge.
        let centeredX = visibleFrame.midX - windowSize.width / 2.0
        let centeredY = visibleFrame.midY - windowSize.height / 2.0

        var x = centeredX
        var y = centeredY

        if windowSize.width <= visibleFrame.width {
            let minX = visibleFrame.minX
            let maxX = visibleFrame.maxX - windowSize.width
            x = clamp(centeredX, min: minX, max: max(minX, maxX))
        }

        if windowSize.height <= visibleFrame.height {
            let minY = visibleFrame.minY
            let maxY = visibleFrame.maxY - windowSize.height
            y = clamp(centeredY, min: minY, max: max(minY, maxY))
        }

        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    static func constrainedOrigin(origin: CGPoint, windowSize: CGSize, bounds: CGRect) -> CGPoint {
        let minX = bounds.minX
        let maxX = bounds.maxX - windowSize.width
        let minY = bounds.minY
        let maxY = bounds.maxY - windowSize.height

        let lowerX = Swift.min(minX, maxX)
        let upperX = Swift.max(minX, maxX)
        let lowerY = Swift.min(minY, maxY)
        let upperY = Swift.max(minY, maxY)

        let constrainedX = clamp(origin.x, min: lowerX, max: upperX)
        let constrainedY = clamp(origin.y, min: lowerY, max: upperY)

        return CGPoint(x: constrainedX.rounded(), y: constrainedY.rounded())
    }

    /// visibleFrame 内缩四向 insets 得到平铺目标（带防负/防塌缩保护）。
    ///
    /// - 逐侧 clamp 到非负，并限制单侧不超过 `(dim-1)/2`，保证同轴两侧之和 ≤ dim-1，
    ///   永不把帧塌缩到 <1px。
    /// - visibleFrame 为左下原点坐标系（NSScreen 约定）：`bottom` 加到 minY，`top` 从高度里扣。
    /// - 结果四舍五入到整像素（与 AX 写入一致，便于测试断言）。
    static func tiledFrame(visibleFrame: CGRect, insets: TileInsets) -> CGRect {
        let maxInsetX = max(0, (visibleFrame.width - 1) / 2)
        let maxInsetY = max(0, (visibleFrame.height - 1) / 2)

        let left = min(max(0, insets.left), maxInsetX)
        let right = min(max(0, insets.right), maxInsetX)
        let top = min(max(0, insets.top), maxInsetY)
        let bottom = min(max(0, insets.bottom), maxInsetY)

        let x = visibleFrame.minX + left
        let y = visibleFrame.minY + bottom
        let width = max(1, visibleFrame.width - left - right)
        let height = max(1, visibleFrame.height - top - bottom)

        return CGRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    /// 平铺目标的左上角锚定 fallback：当 app 把窗口尺寸 snap 到非目标尺寸时，
    /// 保持目标左/上边距不变，按实际尺寸重算右/下边距（而非重新居中）。
    ///
    /// 用于 `finalizePhaseB`：终端类 app（如 electerm 按字符行网格 snap 高度）或 Pages
    /// 这类对窗口尺寸有限制的文档 app，可能拒绝缩放到目标尺寸。此时若用 `centeredOrigin`
    /// 重新居中，会破坏平铺要求的左上角锚定和四向 insets，导致窗口整体漂移。本 helper
    /// 改为以 `targetFrame` 的左上角为锚点：左/上边距严格等于目标 insets，右/下边距随实际
    /// 尺寸放宽（顶部贴 `targetFrame.maxY`，左贴 `targetFrame.minX`）。
    ///
    /// 返回 bottom-left 原点坐标系下的 origin（与 `tiledFrame` / `centeredOrigin` 一致），
    /// 四舍五入到整像素（与 AX 写入一致）。
    static func topLeftAnchoredOrigin(targetFrame: CGRect, actualSize: CGSize) -> CGPoint {
        CGPoint(
            x: targetFrame.minX,
            y: targetFrame.maxY - actualSize.height   // 顶部对齐 targetFrame.maxY，底部由 actualSize 决定
        )
    }

    /// 平铺尺寸受 app 限制时的最终锚定 fallback。
    ///
    /// 宽度仍保持左边距；高度分两类：
    /// - 实际高度比目标矮：保顶部，底部间距放宽（Terminal/electerm 字符网格 snap）。
    /// - 实际高度比目标高：保底部，顶部少量外扩（Numbers 外接屏会把高度读回 visibleFrame 高度）。
    static func constrainedTileFallbackOrigin(targetFrame: CGRect, actualSize: CGSize) -> CGPoint {
        let y = actualSize.height > targetFrame.height
            ? targetFrame.minY
            : targetFrame.maxY - actualSize.height
        return CGPoint(x: targetFrame.minX, y: y.rounded())
    }

    /// 「妥协形态」：app 拒绝目标尺寸时，Plumb 愿意留下的最终 frame。
    ///
    /// 即 `constrainedTileFallbackOrigin` 推出的完整 CGRect（宽度保左距；高度矮→保顶、高→保底）。
    /// 这是**唯一的**妥协形态纯函数：`emitFinalAnchor` 锚定时用它推出 origin，完成判定用它推出
    /// 应被接受的完整 frame。由此「锚定愿意留下的任何形态，判定必然接受」——循环从构造上消除
    ///（根因 D：Numbers 把高度读回 visibleFrame 后，旧 `frameCoversTiledTarget` 的 24px 外扩容差
    /// 既会接受、也会拒绝同一形态，造成反复重铺）。
    static func expectedFallbackFrame(targetFrame: CGRect, actualSize: CGSize) -> CGRect {
        CGRect(origin: constrainedTileFallbackOrigin(targetFrame: targetFrame, actualSize: actualSize), size: actualSize)
    }

    /// 判断 frame 是否正好等于「妥协形态」（origin 由 `expectedFallbackFrame` 决定，size 用实际值）。
    /// 四维统一容差（默认 3px）：origin 与 size 都必须紧贴妥协形态。这是「app 真硬限、已保底锚定」
    /// 的唯一可接受宽松条件——既不像 `frameMatchesTiledTarget` 那样要求 size≈target（妥协形态 size ≠ target），
    /// 也不像旧 `frameCoversTiledTarget` 那样允许 24px 外扩（会吞掉用户设置的 inset）。
    static func frameMatchesFallbackProduct(
        _ frame: CGRect,
        target: CGRect,
        tolerance: CGFloat = 3
    ) -> Bool {
        guard abs(frame.width - target.width) <= tolerance else { return false }
        let product = expectedFallbackFrame(targetFrame: target, actualSize: frame.size)
        return abs(frame.minX - product.minX) <= tolerance &&
            abs(frame.minY - product.minY) <= tolerance &&
            abs(frame.width - product.width) <= tolerance &&
            abs(frame.height - product.height) <= tolerance
    }

    /// 平铺完成严格判定：**逐边语义**——四向边距是否都落在可接受区间内。
    ///
    /// 用途：区分「真正落到平铺目标」与「贴底但顶部缺口」等错误形态——后者若被放行，
    /// 会 markCentered + processedPIDs 锁在错误几何上（如 Numbers 新建文档顶距翻倍 bug：
    /// 贴底、高度矮 16px，旧「minY 严格 + height ≤16」判定放行，但顶距被吃掉 16px）。
    ///
    /// 容差策略（逐边，互不掩盖）：
    ///   - **左边（锚定边，严格）**：`|frame.minX − target.minX| ≤ 3`
    ///   - **底边（锚定边，向内宽松）**：`frame.minY − target.minY ∈ [−3, +16]`
    ///   - **顶边（关键约束）**：`frame.maxY − target.maxY ∈ [−6, +6]`
    ///   - **右边**：`frame.maxX − target.maxX ∈ [−16, +6]`
    ///
    /// 语义解释：
    ///   - 底边/右边允许向内收 ≤16px：兼容 Terminal/electerm 等按字符网格 snap 尺寸的 app 的
    ///     「保顶/保左」妥协（缺口落到底距/右距变宽）。这些 app 尺寸确实无法精确到位，但 origin
    ///     正确，应判定为完成并锁 PID，避免每次切 App 重平铺的回归。
    ///   - 顶边 ±6、右边向外 +6：origin 严格 3px + 尺寸噪声 3px 的合成上界；超过 6px 的顶边缺口
    ///     意味着顶距被明显吃掉，必须拒绝（这正是本次 bug：贴底矮 16 → maxY 缺 16 → 拒）。
    ///   - 底边向外 ≤3：不许吃底距（贴底是目标，但向下出屏会让底距消失，必须拒绝）。
    ///
    /// 顶距与底距「非对称」的原因：top 缺口直接吃掉用户设置顶距（外观为顶距翻倍），是本次
    /// bug 的形态；bottom 缺口是 Terminal 类「保顶 snap」的合法妥协（顶距正确、底距放宽）。
    /// 两者分别用 ±6 / [+16,−3] 容差独立处理，避免互相掩盖。
    static func frameMatchesTiledTarget(_ frame: CGRect, target: CGRect) -> Bool {
        // 左边（锚定边，严格）：不允许横向漂移（iWork resize 后 origin 漂移会破坏左右边距）。
        let leftOff = frame.minX - target.minX
        guard abs(leftOff) <= 3 else { return false }

        // 底边（锚定边）：向内收 ≤16px 合法（保顶 snap 妥协），向外最多出屏 3px（不许吃底距）。
        let bottomOff = frame.minY - target.minY
        guard bottomOff >= -3, bottomOff <= 16 else { return false }

        // 顶边（关键）：±6 合成上界（origin 3px + 尺寸噪声 3px）。顶边缺口意味着顶距被吃。
        let topOff = frame.maxY - target.maxY
        guard topOff >= -6, topOff <= 6 else { return false }

        // 右边：向内收 ≤16px 合法（字符网格 snap），向外最多 +6px。
        let rightOff = frame.maxX - target.maxX
        guard rightOff >= -16, rightOff <= 6 else { return false }

        return true
    }

    /// 平铺完成兜底判定：窗口没有向内露出空白，并且只少量外扩。
    ///
    /// Numbers 可能拒绝目标高度、读回更高窗口。最终锚定会优先保底部间距，让多出的高度
    /// 向顶部外扩；这种不是「未铺满」，继续重试只会循环。若 app 的最小高度仍略高于
    /// 可用高度减 bottom inset，macOS 会把顶部夹到可见区顶端，底部最多会少几像素；
    /// 这种不可达目标接受，小于等于容差。完整吞掉 bottom inset 的贴底状态仍拒绝。
    ///
    /// ⚠️ 外扩容差收紧到 3px（与内露白同阈）。旧实现 top 24px / bottom 6px 的外扩容差
    /// 大于典型 insets，是「锁死在肉眼可见错误间距」的合法化通道——用户设置的 inset 常常
    /// 只有 10-16px，24px 外扩会直接吞掉它。3px 是「坐标空间探测噪声 / 系统顶部夹取」的
    /// 合理上界，超过 3px 的外扩必须走 `frameMatchesFallbackProduct`（妥协形态相等）而非本方法。
    static func frameCoversTiledTarget(
        _ frame: CGRect,
        target: CGRect,
        inwardGapTolerance: CGFloat = 3,
        outwardOvershootTolerance: CGFloat = 3,
        bottomOvershootTolerance: CGFloat = 3
    ) -> Bool {
        let leftInwardGap = frame.minX - target.minX
        let rightInwardGap = target.maxX - frame.maxX
        let bottomInwardGap = frame.minY - target.minY
        let topInwardGap = target.maxY - frame.maxY

        let leftOvershoot = target.minX - frame.minX
        let rightOvershoot = frame.maxX - target.maxX
        let bottomOvershoot = target.minY - frame.minY
        let topOvershoot = frame.maxY - target.maxY

        return leftInwardGap <= inwardGapTolerance &&
            rightInwardGap <= inwardGapTolerance &&
            bottomInwardGap <= inwardGapTolerance &&
            topInwardGap <= inwardGapTolerance &&
            leftOvershoot <= inwardGapTolerance &&
            rightOvershoot <= outwardOvershootTolerance &&
            bottomOvershoot <= bottomOvershootTolerance &&
            topOvershoot <= outwardOvershootTolerance
    }

    /// 统一平铺完成判定（唯一真源）：一个 frame 是否应被接受为「平铺完成」。
    ///
    /// 三选一，按此顺序短路：
    ///   1. `frameMatchesTiledTarget` —— 真正落到平铺目标（逐边语义：左严格 3px、底向内宽松 16px、
    ///      顶 ±6px、右 −16/+6px；防止「贴底短高」吃掉顶距）。
    ///   2. `frameMatchesFallbackProduct` —— 等于「妥协形态」（四维 3px）。这是 app 拒绝目标尺寸后
    ///      `emitFinalAnchor` 愿意留下的唯一妥协 frame；判定必然接受 → 锚定与判定同源，循环消除。
    ///   3. `frameCoversTiledTarget` —— 完整覆盖目标、四向外扩 ≤ 3px 的几何兜底（应对系统顶部夹取
    ///      产生的 ±3px 不可达误差，不再吞 inset）。
    ///
    /// 抽成 nonisolated 纯函数，供 `emitFinalAnchor` / `tileReachedTarget` / `isWindowAtTiledTarget`
    ///（经服务层薄封装）共用，并直接单元测试。
    static func frameSatisfiesFinalTiledTarget(_ frame: CGRect, target: CGRect) -> Bool {
        if frameMatchesTiledTarget(frame, target: target) { return true }
        if frameMatchesFallbackProduct(frame, target: target) { return true }
        if frameCoversTiledTarget(frame, target: target) { return true }
        return false
    }

    /// 把“全屏 frame 与可用 visibleFrame”之间的逐边 inset 计算下沉为纯函数。
    /// 让 Dock 在左/右/下、菜单栏在顶部的逐屏差异可被独立测试。
    static func insetsFromVisibleFrame(frame: CGRect, visible: CGRect) -> ScreenSelection.EdgeInsets {
        ScreenSelection.EdgeInsets(
            left: visible.minX - frame.minX,
            right: frame.maxX - visible.maxX,
            top: frame.maxY - visible.maxY,
            bottom: visible.minY - frame.minY
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Multi-window grid tiling (complementary-region layout)
    //
    // 把「一个矩形区域」均分给 N 个窗口的纯几何。区域来自调用方：可以是整块
    // visibleFrame，也可以是它的左/右/上/下半区（当用户用系统 tiling 把某个 app 钉在
    // 另一半时，Plumb 把选中的窗口铺进互补的这一半）。与 tiledFrame 共用左下原点坐标系，
    // 结果可直接喂给同一套 AX 写入路径。
    // ─────────────────────────────────────────────────────────────────────────

    /// visibleFrame 的一个子区域。用于「互补区平铺」：用户把某个窗口钉在一半，
    /// Plumb 把选中窗口铺进另一半（或整块）。
    enum ScreenRegion {
        case full
        case leftHalf, rightHalf
        case topHalf, bottomHalf
    }

    /// 取 visibleFrame 的指定子区域（左下原点坐标系，NSScreen 约定）。
    static func region(_ region: ScreenRegion, of visibleFrame: CGRect) -> CGRect {
        let halfW = visibleFrame.width / 2
        let halfH = visibleFrame.height / 2
        switch region {
        case .full:
            return visibleFrame
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfW, height: visibleFrame.height)
        case .rightHalf:
            return CGRect(x: visibleFrame.midX, y: visibleFrame.minY, width: halfW, height: visibleFrame.height)
        case .topHalf:
            // 顶部 = 更大的 y（左下原点）。
            return CGRect(x: visibleFrame.minX, y: visibleFrame.midY, width: visibleFrame.width, height: halfH)
        case .bottomHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfH)
        }
    }

    /// 把 `region` 均分成一个网格，返回 `count` 个窗口目标 frame（行优先，左上角优先）。
    ///
    /// **列数按区域宽高比自适应**（而非固定 `ceil(sqrt(count))`）：目标让每格尽量方正。
    ///   idealCols ≈ sqrt(count × 区域宽/高)。于是——
    ///     - 宽扁区域（整屏 / 上下半区）→ 列多行少（横向铺开）；
    ///     - 高窄区域（左右半区）→ 列少行多（**竖向堆叠**，每格保持接近半区全宽）。
    ///   这直接修复「把多个窗口塞进左右半区 → 每格过窄、低于 app 最小宽度 → 被 clamp 不生效」
    ///   （Finder 等最小宽度 ~450px；左右半区分列会击穿它，上下半区因保持全宽而正常）。
    /// 另加 `minCellWidth`（默认 320px）下限：列数会进一步收敛，直到每格宽度 ≥ 该值或列数=1，
    ///   避免小屏（如 Luna Display）上仍被 clamp。
    ///
    /// 行数 = `ceil(count/列数)`；末行不满时按其实际窗口数均分整行宽度（铺满、不留空列）。
    ///
    /// - `gutter`：窗口之间的间隙（px），四周不加外边距——外边距由调用方在传入 `region` 前 inset。
    /// - 坐标系：左下原点（与 `tiledFrame` 一致）；行 0 位于区域顶部（较大 y）。
    /// - 结果四舍五入到整像素（与 AX 写入一致，便于测试断言）。
    static func gridFrames(
        region: CGRect,
        count: Int,
        gutter: CGFloat = 8,
        minCellWidth: CGFloat = 380,
        minCellHeight: CGFloat = 260,
        columns: Int? = nil
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [region] }

        let g = max(0, gutter)
        // 显式列数（用户从「Tile Layout」菜单选定）优先；否则走自动推断。夹到 1...count。
        let cols: Int
        if let columns {
            cols = Swift.max(1, Swift.min(columns, count))
        } else {
            cols = chooseColumns(region: region, count: count, gutter: g, minCellWidth: minCellWidth, minCellHeight: minCellHeight)
        }
        let rows = Int(ceil(Double(count) / Double(cols)))

        // 用**边界插值**而非「格宽×序号」定位，保证网格**严格铺满区域**（右/下缘 flush，无残留缝隙）。
        // 每条内部边界取分数位置再四舍五入 → 相邻格共享同一整数边界，累积不产生「多出来的空隙」。
        let availH = max(1, region.height - CGFloat(rows - 1) * g)   // 扣掉行间 gutter 的净高。

        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        var placed = 0
        for r in 0..<rows {
            // 本行窗口数：满行 = cols；末行 = 剩余（按实际数均分整行宽度，铺满不留空列）。
            let itemsInRow = min(cols, count - placed)
            guard itemsInRow > 0 else { break }

            // 竖直：行 r（0=顶）的上下边（左下原点，顶部=较大 y）。插值 + 四舍五入 → 行间无缝、末行贴底。
            let topEdge = (region.maxY - availH * CGFloat(r) / CGFloat(rows) - CGFloat(r) * g).rounded()
            let bottomEdge = (region.maxY - availH * CGFloat(r + 1) / CGFloat(rows) - CGFloat(r) * g).rounded()
            let y = bottomEdge
            let h = max(1, topEdge - bottomEdge)

            // 水平：本行各列的左右边（同样插值），列间无缝、末列贴右缘。
            let availW = max(1, region.width - CGFloat(itemsInRow - 1) * g)
            for c in 0..<itemsInRow {
                let leftEdge = (region.minX + availW * CGFloat(c) / CGFloat(itemsInRow) + CGFloat(c) * g).rounded()
                let rightEdge = (region.minX + availW * CGFloat(c + 1) / CGFloat(itemsInRow) + CGFloat(c) * g).rounded()
                let w = max(1, rightEdge - leftEdge)
                frames.append(CGRect(x: leftEdge, y: y, width: w, height: h))
            }
            placed += itemsInRow
        }
        return frames
    }

    /// 给定窗口数，枚举「Tile Layout」菜单可供选择的列数选项。每个列数对应一种不同的网格形态
    /// （列数唯一 → 布局唯一）。`count <= 1` → 空（无可选布局）。返回按列数升序 [1...count]。
    static func candidateColumnCounts(for count: Int) -> [Int] {
        guard count > 1 else { return [] }
        return Array(1...count)
    }

    /// 给定窗口数与列数，返回行数 = ceil(count/columns)。
    static func gridRows(count: Int, columns: Int) -> Int {
        let c = Swift.max(1, Swift.min(columns, Swift.max(1, count)))
        return Int(ceil(Double(count) / Double(c)))
    }

    /// 「互补区」：给定一个被占用窗口（如用户用系统 tiling 钉在某半的 app）与可用屏区，
    /// 返回该窗口**没占用**的最大空条——供把其它窗口铺进「focused window 不在的那一侧」。
    ///
    /// 算法：算出占用窗口四边到可用区四边的空隙（左/右/上/下），取最大的一侧作为空条：
    ///   - 右侧最大 → 返回窗口右边到屏幕右缘的**全高**竖条；
    ///   - 左侧最大 → 窗口左边到屏幕左缘的全高竖条；
    ///   - 上/下最大 → 对应的**全宽**横条。
    /// 空条按构造**不与占用窗口重叠**（竖条在其左/右外侧，横条在其上/下外侧）。
    ///
    /// 半屏 split 场景下，占用窗口贴一边（该侧空隙≈0），对侧空隙≈半屏 → 干净返回另一半。
    /// 若最大空隙 < `minStrip`（占用窗口几乎铺满可用区，无有意义的互补区）→ 返回 nil。
    ///
    /// 坐标系：左下原点（与 `tiledFrame` / visibleFrame 一致）。`occupied` 会先与 `usable` 求交，
    /// 越界部分不参与（多屏时占用窗口可能部分在别屏）。
    static func freeRegionBeside(occupied: CGRect, usable: CGRect, minStrip: CGFloat = 120) -> CGRect? {
        let occ = occupied.intersection(usable)
        guard !occ.isNull, occ.width > 0, occ.height > 0 else { return nil }

        let leftGap = occ.minX - usable.minX
        let rightGap = usable.maxX - occ.maxX
        let bottomGap = occ.minY - usable.minY
        let topGap = usable.maxY - occ.maxY

        let maxGap = max(max(leftGap, rightGap), max(topGap, bottomGap))
        guard maxGap >= minStrip else { return nil }

        if maxGap == rightGap {
            return CGRect(x: occ.maxX, y: usable.minY, width: usable.maxX - occ.maxX, height: usable.height)
        }
        if maxGap == leftGap {
            return CGRect(x: usable.minX, y: usable.minY, width: occ.minX - usable.minX, height: usable.height)
        }
        if maxGap == topGap {
            return CGRect(x: usable.minX, y: occ.maxY, width: usable.width, height: usable.maxY - occ.maxY)
        }
        // bottom
        return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: occ.minY - usable.minY)
    }

    /// 为 `count` 个窗口在 `region` 里选列数，**同时尊重最小格宽与最小格高**。
    ///
    /// 背景：不同 app 的最小窗口尺寸差异很大——Terminal 极小（几乎任意格都能填满），Finder 较大
    /// （列表/分栏视图有可观的最小宽高）。若只按宽高比分格，Finder 会被塞进过矮的格子而无法收缩，
    /// 于是「铺不满、底部留一大块」。这里遍历所有列数，优先选**同时满足** cellW≥minW 且 cellH≥minH
    /// 的布局；这类布局里取最方正（|cellW−cellH| 最小）、空格最少者。若无任何布局同时满足（窗口太多、
    /// 区域太小——物理上放不下），退而取「对两个最小值满足得最好」（min(宽比,高比) 最大）的布局。
    private static func chooseColumns(
        region: CGRect,
        count: Int,
        gutter g: CGFloat,
        minCellWidth minW: CGFloat,
        minCellHeight minH: CGFloat
    ) -> Int {
        var bestCols = 1
        var bestFits = false
        var bestBalance = Int.max
        var bestSquare = CGFloat.greatestFiniteMagnitude
        var bestWaste = Int.max
        var bestMinRatio = -CGFloat.greatestFiniteMagnitude

        for c in 1...count {
            let r = Int(ceil(Double(count) / Double(c)))
            let cw = max(1, (region.width - CGFloat(c - 1) * g) / CGFloat(c))
            let ch = max(1, (region.height - CGFloat(r - 1) * g) / CGFloat(r))
            let fits = cw >= minW && ch >= minH
            let balance = abs(c - r)                            // |列-行|，0 = 最均衡（近正方形的网格）。
            let waste = r * c - count
            let square = abs(cw - ch)
            let minRatio = Swift.min(cw / minW, ch / minH)

            let better: Bool
            if fits != bestFits {
                better = fits                                   // 满足双最小 优先。
            } else if fits {
                // 先取**更均衡的网格**（列≈行）。这让 4 窗选 2×2（balance=0）而非宽屏上格子更方正的
                // 3+1（3 列 2 行、balance=1）——2×2 才是直觉布局。同时保持 3 窗为 2+1（c=2, balance=0，
                // 优于 1×3 竖排 balance=2），9 窗为 3×3，等等。
                if balance != bestBalance { better = balance < bestBalance }
                else if abs(square - bestSquare) > 0.5 { better = square < bestSquare }  // 再取更方正的格子。
                else { better = waste < bestWaste }                                      // 再取空格更少。
            } else {
                better = minRatio > bestMinRatio                // 都不满足时：对两最小值满足得最好。
            }
            if better {
                bestCols = c; bestFits = fits; bestBalance = balance; bestSquare = square; bestWaste = waste; bestMinRatio = minRatio
            }
        }
        return bestCols
    }

    private static func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }
}
