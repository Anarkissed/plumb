# Fork changes

A fork of [Lv-0/plumb](https://github.com/Lv-0/plumb). Everything below is on top of upstream `v2.0.51`.

## Core change — real multi-window grid tiling

Upstream "tiling" maximizes **one** window at a time to fill the screen minus a margin. This fork
reworks tiling into a true **grid tiler**: **Tile Now** (`⌥⌘T` / menu) and auto-tile arrange **all of
an app's windows** into a grid that fills the screen (or the chosen region) — e.g. 4 Finder windows
become a 2×2, 6 become 3×2, and so on. Windows are placed side-by-side into cells rather than each
being blown up to full screen.

- **Tile Now** grids every window of the focused app across its screen.
- **Auto-tile** (per-app toggle) keeps an app's windows gridded as you open/close them.
- Layout adapts to the live window count on the focused display's current Space.

## New feature — visual "Tile Layout" picker
- New **Tile Layout** submenu in the menu-bar menu. For the focused app's current window
  count it lists every grid arrangement (e.g. 4 windows → `2×2`, `1×4`, `4×1`, …), each drawn
  as a live mini-grid pictogram rendered from the real layout engine.
- **Hover to preview** — the real windows snap into that layout instantly; move away or close
  the menu to revert. **Click to keep** — the choice is remembered **per app + per window count**
  (a ✓ marks the saved layout), and future Tile Now / auto-tile reuse it.

## Tiling correctness fixes
- **Global hotkey dispatch** — `⌥⌘T` (Tile Now) never fired: each Carbon hotkey handler returned
  `noErr` on a non-match, swallowing the event before the sibling handler saw it. Whichever hotkey
  registered last won; the other was silently dead. Now returns `eventNotHandledErr` so all hotkeys work.
- **Stable, correct window count** — eligibility now excludes fullscreen, **minimized**, other-Space,
  and other-display windows. The count comes from CoreGraphics' on-screen list scoped to the
  **focused display's** current Space, instead of the flaky AX window list (which made the count
  jump between 6–8).
- **Wrong-window CG matching** — for apps without `AXWindowNumber` (Finder), CG bounds were matched
  by closest size and routinely returned a *different* window, corrupting placement. Now only matches
  when unambiguous, else falls back to pure-AX.
- **Coordinate-space detection** — `detectCG` now rejects unreconcilable guesses (large error) instead
  of trusting a bad coordinate space.

## Anti-twitch / stability
- **Debounced auto-reflow** — rapid open/close events coalesce into one re-tile after the count settles.
- **Idempotent placement** — windows already in place are skipped, so a settled layout does zero writes.
- **No overlapping animations** — every layout pass aborts in-flight animations; hover-preview places
  instantly. Together these eliminate the "windows twitch between positions" loop.
- **Split-screen memory** — auto-reflow (open/close) keeps windows in the region they were last tiled
  into (e.g. a half-screen split beside an anchor); only an explicit **Tile Now** resets to full screen.
- **Oversize self-heal** — if a window ends up far larger than its cell after tiling, it's re-snapped once.

## Layout defaults
- Balanced grids preferred: 4 windows → **2×2** (not 3+1) on wide screens; 3 → 2+1; 9 → 3×3, etc.

## Build / signing
- `build_app.sh` and `make_signing_cert.sh` now check the code-signing identity with
  `security find-identity -v -p codesigning` (a self-signed cert is valid for code signing on
  macOS 15/26 even though the default X.509 policy reports it untrusted). Fixed missing exec bits
  on `make_signing_cert.sh` / `release.sh`.
