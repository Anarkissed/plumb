import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GridSection (SettingsUI)
//
// 模块角色：设置里「Grid」标签页——多窗口网格平铺配置。
//
// 顶部卡片：目标区域选择（Full / 左右上下半区）+ 窗口间隙滑块。半区用于「互补布局」：
//   用户把某 app 用系统 tiling 钉在另一半，Plumb 把受管窗口铺进这半。
// 下方列表：勾选哪些 app 启用「新窗口自动网格平铺」（绑定 GridTilingSettings.managedBundleIDs，
//   与菜单栏的「Auto-tile <App>'s new windows」是同一份设置）。
//
// 字符串暂用英文硬编码（与菜单项一致），避免改动本地化表触发「每语言每键」测试；本地化为后续项。
// ─────────────────────────────────────────────────────────────────────────────

struct GridSection: View {
    @Binding var settings: GridTilingSettings
    let apps: [InstalledAppInfo]

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ScrollView {
                AppListSection(
                    footnote: "Turn on the apps you want auto-tiled. New windows tile into a grid as you open them; already-open ones join on Tile Now (⌥⌘T). Tile Now adapts: if you're focused on one of these apps, its windows fill the region above. If you're focused on a DIFFERENT app (e.g. one you've pinned to half the screen), these apps tile into the free space beside it — on that monitor.",
                    selected: $settings.managedBundleIDs,
                    apps: apps
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 顶部卡片

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 目标区域。
            VStack(alignment: .leading, spacing: 6) {
                Text("Tile into")
                    .foregroundStyle(.primary)
                Text("The screen area the grid fills. Use a half to leave the other half for an app you've pinned with macOS window tiling.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    ForEach(GridRegion.allCases, id: \.self) { region in
                        RegionPill(
                            title: Self.label(for: region),
                            isSelected: settings.region == region
                        ) {
                            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                                settings.region = region
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider().opacity(0.2)

            // 窗口间隙。
            HStack(spacing: 12) {
                Text("Gap")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                Slider(value: $settings.gutter,
                       in: GridTilingSettings.minimumGutter...GridTilingSettings.maximumGutter)
                Text("\(Int(settings.gutter.rounded()))")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Text("px")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private static func label(for region: GridRegion) -> String {
        switch region {
        case .full: return "Full"
        case .leftHalf: return "Left ½"
        case .rightHalf: return "Right ½"
        case .topHalf: return "Top ½"
        case .bottomHalf: return "Bottom ½"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RegionPill
//
// 区域选择胶囊：与主/子标签栏未选中态一致（极淡半透明），选中态用强调色填充。
// ─────────────────────────────────────────────────────────────────────────────

private struct RegionPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(Color.primary.opacity(0.06)))
        }
        .animation(.spring(duration: 0.3, bounce: 0.18), value: isSelected)
    }
}
