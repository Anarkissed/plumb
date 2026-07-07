import AppKit
import ApplicationServices

/// Grid-tiling self-test: drives `WindowCenteringService.placeWindowElement` + `WindowGeometry.gridFrames`
/// against a REAL app's windows (Finder by default) and logs before/after frames for each window.
///
/// This isolates the grid pipeline from the menu / frontmost-app ambiguity: it activates the target
/// app first (AX size writes are silently ignored unless the target app is frontmost — see
/// SelfTestTileApp), enumerates its windows, computes an N-cell grid over the main screen's usable
/// area, and places each window. It reports which windows actually moved/resized.
///
/// Trigger:
///   defaults write com.comet.plumb selftestGrid -bool true
///   open dist/Plumb.app          # (grant Accessibility to Plumb.app first)
/// Requires the target app (Finder) to have ≥2 windows open. Output: /tmp/cw_selftest_grid.log
/// Override target: `defaults write com.comet.plumb selftestGridBundleID -string "com.apple.TextEdit"`

@MainActor
final class SelfTestGridDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_grid.log"
    private var service: WindowCenteringService?

    private static func log(_ message: String) {
        print(message)
        if let data = (message + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let h = FileHandle(forWritingAtPath: logPath) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "".write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        NSApp.setActivationPolicy(.regular)

        let trusted = AXIsProcessTrusted()
        Self.log("SELFTEST-GRID: AXIsProcessTrusted=\(trusted)")
        if !trusted {
            Self.log("SELFTEST-GRID: FAIL — Accessibility NOT granted to this binary/app. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility, then re-run.")
            finish(); return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.run() }
    }

    private func run() {
        let bundleID = UserDefaults.standard.string(forKey: "selftestGridBundleID") ?? "com.apple.finder"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Self.log("SELFTEST-GRID: FAIL — \(bundleID) not running. Open it (with a couple of windows) first.")
            finish(); return
        }
        Self.log("SELFTEST-GRID: activating \(bundleID)...")
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.tile(app: app)
        }
    }

    private func tile(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        Self.log("SELFTEST-GRID: target pid=\(pid) frontmost=\(isFrontmost)")

        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        let allWindows = (winsRef as? [AXUIElement]) ?? []
        Self.log("SELFTEST-GRID: AXWindows count=\(allWindows.count)")

        // Eligibility: standard windows with a readable size (mirrors GridTilingController.isEligible).
        let windows = allWindows.filter { w in
            guard w.axSize(kAXSizeAttribute as CFString) != nil else { return false }
            if let sub = w.axString(kAXSubroleAttribute as CFString) { return sub == (kAXStandardWindowSubrole as String) }
            return true
        }
        Self.log("SELFTEST-GRID: eligible windows=\(windows.count)")
        guard windows.count >= 1 else {
            Self.log("SELFTEST-GRID: FAIL — no eligible windows. Open ≥2 \(app.bundleIdentifier ?? "") windows.")
            finish(); return
        }

        let service = WindowCenteringService()
        self.service = service
        guard let refScreen = service.screenForWindow(windows[0], pid: pid) ?? NSScreen.main else {
            Self.log("SELFTEST-GRID: FAIL — no reference screen")
            finish(); return
        }
        Self.log("SELFTEST-GRID: refScreen frame=\(refScreen.frame) usable=\(service.usableFrame(for: refScreen))")

        let usable = service.usableFrame(for: refScreen)
        let region = WindowGeometry.region(.full, of: usable)
        let frames = WindowGeometry.gridFrames(region: region, count: windows.count, gutter: 8)
        Self.log("SELFTEST-GRID: computed \(frames.count) grid frames for \(windows.count) windows")

        var movedCount = 0
        for (i, w) in windows.enumerated() where i < frames.count {
            let before = readFrame(w)
            do {
                try service.placeWindowElement(w, pid: pid, appElement: appEl, targetFrame: frames[i])
            } catch {
                Self.log("SELFTEST-GRID: window[\(i)] placeWindowElement THREW: \(error)")
            }
            let after = readFrame(w)
            let moved = abs(after.minX - before.minX) > 4 || abs(after.minY - before.minY) > 4
                || abs(after.width - before.width) > 4 || abs(after.height - before.height) > 4
            if moved { movedCount += 1 }
            Self.log("SELFTEST-GRID: window[\(i)] target=\(stringify(frames[i])) before=\(stringify(before)) after=\(stringify(after)) moved=\(moved)")
        }

        Self.log("SELFTEST-GRID: moved \(movedCount)/\(min(windows.count, frames.count)) windows")
        Self.log("SELFTEST-GRID: RESULT=\(movedCount > 0 ? "PASS (windows moved)" : "FAIL (no window moved — AX writes rejected)")")
        finish()
    }

    private func finish() {
        Self.log("SELFTEST-GRID: DONE (log at \(Self.logPath))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func readFrame(_ el: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }
}
