import CoreGraphics
import Foundation
import Testing
@testable import Plumb

// GridTilingSettings 模型 + GridTilingSettingsStore 文件持久化的测试。

@Test
func gridSettingsDefaultsAreSane() async throws {
    let d = GridTilingSettings.default
    #expect(d.managedBundleIDs.isEmpty)
    #expect(d.region == .full)
    #expect(d.gutter == GridTilingSettings.defaultGutter)
}

@Test
func gridSettingsNormalizeLowercasesAndClampsGutter() async throws {
    let s = GridTilingSettings(
        managedBundleIDs: ["com.apple.Finder", "  ", "Com.Example.APP"],
        region: .leftHalf,
        gutter: 9999
    ).normalized()

    #expect(s.managedBundleIDs == ["com.apple.finder", "com.example.app"])   // 归一化小写 + 剔空
    #expect(s.gutter == GridTilingSettings.maximumGutter)                     // 钳制到上限
    #expect(s.region == .leftHalf)
}

@Test
func gridSettingsIsManagedMatchesNormalizedBundleID() async throws {
    let s = GridTilingSettings(managedBundleIDs: ["com.apple.finder"], region: .full, gutter: 8)
    #expect(s.isManaged(bundleIdentifier: "com.apple.Finder"))   // 运行时 bundle id 混合大小写也命中
    #expect(s.isManaged(bundleIdentifier: "com.apple.Safari") == false)
    #expect(s.isManaged(bundleIdentifier: nil) == false)
}

@Test
func gridSettingsStoreFileRoundTrip() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("plumb-grid-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = GridTilingSettingsStore(settingsFileURL: tmp)
    // 未写入前返回默认。
    #expect(store.load() == GridTilingSettings.default)

    store.save(GridTilingSettings(managedBundleIDs: ["com.apple.finder"], region: .rightHalf, gutter: 24))

    // 新实例（跳过缓存）从文件读取。
    let fresh = GridTilingSettingsStore(settingsFileURL: tmp)
    let loaded = fresh.load()
    #expect(loaded.managedBundleIDs == ["com.apple.finder"])
    #expect(loaded.region == .rightHalf)
    #expect(loaded.gutter == 24)
}

@Test
func gridSettingsDecodesMissingKeysToDefaults() async throws {
    // 旧/精简 JSON（只含 managedBundleIDs）应回退 region=.full、gutter=default。
    let json = #"{"managedBundleIDs":["com.apple.finder"]}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(GridTilingSettings.self, from: json)
    #expect(decoded.managedBundleIDs == ["com.apple.finder"])
    #expect(decoded.region == .full)
    #expect(decoded.gutter == GridTilingSettings.defaultGutter)
}
