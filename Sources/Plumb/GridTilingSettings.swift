import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GridTilingSettings / GridTilingSettingsStore
//
// 模块角色：网格平铺的设置模型 + 持久化。**独立于** AppTilingSettings —— 刻意不并入，
// 避免在那份被大量测试覆盖的模型/持久化里制造涟漪；网格是一个新增、可选、正交的模式。
//
// 数据：
//   - managedBundleIDs：被「Tile <App>」标记为网格受管的 app（归一化小写 bundle id）。
//   - region：网格铺进 visibleFrame 的哪个子区域（full / 左右上下半区）。互补区场景用半区
//     （用户把某 app 用系统 tiling 钉在另一半，Plumb 把受管窗口铺进这半）。
//   - gutter：网格窗口之间的间隙（px）。
//
// 存储：签名无关的 `~/Library/Application Support/Plumb/grid.json`（与 AppTilingSettingsStore
// 同目录、同「文件路径只依赖 bundle id」理由 → OTA 更新后设置不丢）。测试可注入临时路径。
// ─────────────────────────────────────────────────────────────────────────────

/// 网格铺进 visibleFrame 的目标子区域。`.full` = 整块可用区（「Tile Finder → 2×2」的默认）；
/// 半区用于互补布局（另一半留给系统 tiling 钉住的 app）。
enum GridRegion: String, Codable, CaseIterable {
    case full, leftHalf, rightHalf, topHalf, bottomHalf

    /// 桥接到纯几何的 WindowGeometry.ScreenRegion。
    var geometryRegion: WindowGeometry.ScreenRegion {
        switch self {
        case .full: return .full
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .topHalf: return .topHalf
        case .bottomHalf: return .bottomHalf
        }
    }
}

struct GridTilingSettings: Equatable, Codable {
    static let defaultGutter: CGFloat = 8
    static let minimumGutter: CGFloat = 0
    static let maximumGutter: CGFloat = 200

    var managedBundleIDs: Set<String>
    var region: GridRegion
    var gutter: CGFloat
    /// 用户为某 app + 某窗口数**显式选定**的网格列数（「Tile Layout」菜单里点选/记住的布局）。
    /// key = `归一化bundleID#窗口数`（如 `com.apple.finder#4`）→ 列数。缺省（无 key）= 走自动列数推断。
    /// 按「app + 数量」分别记忆：Finder 4 窗选 2×2、5 窗选 3×2 互不影响。
    var layoutColumns: [String: Int]

    static let `default` = GridTilingSettings(
        managedBundleIDs: [],
        region: .full,
        gutter: defaultGutter,
        layoutColumns: [:]
    )

    // 后增字段全部 decodeIfPresent 回退，兼容旧/缺失文件。
    private enum CodingKeys: String, CodingKey {
        case managedBundleIDs, region, gutter, layoutColumns
    }

    init(managedBundleIDs: Set<String>, region: GridRegion, gutter: CGFloat, layoutColumns: [String: Int] = [:]) {
        self.managedBundleIDs = managedBundleIDs
        self.region = region
        self.gutter = gutter
        self.layoutColumns = layoutColumns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managedBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .managedBundleIDs) ?? []
        region = try c.decodeIfPresent(GridRegion.self, forKey: .region) ?? .full
        gutter = try c.decodeIfPresent(CGFloat.self, forKey: .gutter) ?? Self.defaultGutter
        layoutColumns = try c.decodeIfPresent([String: Int].self, forKey: .layoutColumns) ?? [:]
    }

    func normalized() -> GridTilingSettings {
        GridTilingSettings(
            managedBundleIDs: Set(managedBundleIDs.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            region: region,
            gutter: Swift.max(Self.minimumGutter, Swift.min(gutter, Self.maximumGutter)),
            layoutColumns: layoutColumns
        )
    }

    /// 某 app 是否被标记为网格受管（bundle id 归一化后匹配）。
    func isManaged(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return managedBundleIDs.contains(AppTilingSettings.normalizeBundleID(bundleIdentifier))
    }

    /// 组合 layoutColumns 的 key。
    static func layoutKey(bundleID: String, windowCount: Int) -> String {
        "\(AppTilingSettings.normalizeBundleID(bundleID))#\(windowCount)"
    }

    /// 该 app + 窗口数是否有用户选定的列数（无 → nil，调用方回退自动推断）。
    func chosenColumns(bundleID: String?, windowCount: Int) -> Int? {
        guard let bundleID else { return nil }
        return layoutColumns[Self.layoutKey(bundleID: bundleID, windowCount: windowCount)]
    }

    /// 返回记录了该 app+窗口数选定列数的副本。
    func settingChosenColumns(_ columns: Int, bundleID: String, windowCount: Int) -> GridTilingSettings {
        var copy = self
        copy.layoutColumns[Self.layoutKey(bundleID: bundleID, windowCount: windowCount)] = columns
        return copy
    }
}

final class GridTilingSettingsStore {
    private let settingsFileURL: URL
    private var cached: GridTilingSettings?
    private let cacheLock = NSLock()

    init(settingsFileURL: URL? = nil) {
        if let settingsFileURL {
            self.settingsFileURL = settingsFileURL
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Plumb", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.settingsFileURL = dir.appendingPathComponent("grid.json")
        }
    }

    func load() -> GridTilingSettings {
        cacheLock.lock()
        if let cached {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let settings = readFromFile() ?? .default

        cacheLock.lock()
        cached = settings
        cacheLock.unlock()
        return settings
    }

    func save(_ settings: GridTilingSettings) {
        let normalized = settings.normalized()
        writeToFile(normalized)
        cacheLock.lock()
        cached = normalized
        cacheLock.unlock()
    }

    private func readFromFile() -> GridTilingSettings? {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path),
              let data = try? Data(contentsOf: settingsFileURL),
              let decoded = try? JSONDecoder().decode(GridTilingSettings.self, from: data)
        else { return nil }
        return decoded
    }

    private func writeToFile(_ settings: GridTilingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let dir = settingsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: settingsFileURL, options: [.atomic])
    }
}
