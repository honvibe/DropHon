# DropHon

A Dropover-style file shelf for macOS. Shake the cursor while dragging files and a floating shelf appears: park files there, then drag them out to wherever they're going. Share-instantly tiles (AirDrop / Messages / Mail / Copy) pop up next to the shelf.

> Personal project, free, not on the App Store. Inspired by Dropover. **All code is written from scratch**, with no code, images or icons from any other app.

---

## Install (for people we share it with)

1. Download `DropHon-x.y.zip` from **Releases** → unzip → drag `DropHon.app` into `Applications`
2. It isn't notarized by Apple, so the first launch gets blocked. Fix it once with either:
   - Right-click `DropHon.app` → **Open** → **Open** again, or
   - In Terminal: `xattr -dr com.apple.quarantine /Applications/DropHon.app`
3. Works on macOS 14+ · both Apple silicon and Intel (universal build)
4. No special permissions needed (no Accessibility, no Screen Recording)

## How to use

| Do this | You get |
|---|---|
| Drag files and shake the cursor left-right fast | Shelf appears under the cursor + 2×2 share panel above it |
| Drop files on the shelf | They're held there (drop more any time) |
| Drag the stack out | All files go at once, then the shelf closes itself |
| Click the `N Files ›` pill | Shelf expands into a grid of individual items |
| In the grid: drag one item / select + **Space** / **Delete** | Pull out one file / Quick Look / remove from shelf |
| Drop a file on a share tile | AirDrop · Messages · Mail · Copy (copy = paste into Finder/chat) |
| Click the Dock icon | Empty shelf at the cursor |
| Drop files on the Dock icon | Shelf with those files |
| Right-click the Dock icon → Shake to Open | Off / Low / Medium / High |

There's deliberately no menu bar icon (the owner's menu bar is full); settings live in the Dock menu.

---

## Build

```sh
./build.sh
```
- Builds arm64 + x86_64 → `lipo` → `DropHon.app`, runs `--selftest` (fails the build if the shake rule breaks), ad-hoc signs, installs to `~/Applications`, zips to `dist/DropHon-<version>.zip`
- Needs Xcode command line tools only (no Xcode project; one `swiftc` call per arch)
- Version = `CFBundleShortVersionString` in `Info.plist`
- `./DropHon.app/Contents/MacOS/DropHon --demo` pops a shelf, grid and share panel with files from `~/Desktop`, for screenshots

## Code map (`main.swift`, ~670 lines, AppKit, single file on purpose)

| Section | Types | What it does |
|---|---|---|
| Shake detection | `ShakeDetector`, `selfTest()` | Pure shake rule (no UI), fed x positions + timestamps. `selfTest` = 5 checks run by every build |
| Shared look | `makeCard`, `makePanel`, `readFileURLs`, `appIcon` | Frosted rounded card (uses `maskImage` so the shadow follows the curve), floating borderless panel |
| Shelf | `KeyPanel`, `ShelfView`, `ShelfItem`, `ShelfGrid`, `Shelf` | `Shelf` owns the file list and swaps between the collapsed `ShelfView` (thumbnail stack) and the expanded `ShelfGrid` (NSCollectionView). `KeyPanel` lets a borderless panel take keyboard focus for Space/Delete |
| Instant share tiles | `ActionTile`, `InstantActions`, `tileFill` | 2×2 share panel + floating title pill on hover |
| App | `Sensitivity`, `AppDelegate` | Global mouse monitor → shake → open shelf; Dock menu; Dock click / Dock drop |

**How opening a shelf works:** `NSEvent.addGlobalMonitorForEvents` (mouse down / drag / up) → on mouse down, save the drag pasteboard's `changeCount` → on drag, if `changeCount` changed (= a real drag is happening), feed x into `ShakeDetector` → shake → `Shelf(at: mouse)` + `InstantActions.show`. Global mouse monitors don't need Accessibility permission (only key events do).

---

## History

| Date | What changed |
|---|---|
| 2026-10-17 | v0.1 "Hon Shelf": shake opens a shelf, drop in, drag everything out, Dock click/drop. |
| 2026-10-17 | Frosted card redesign + 2×2 share tiles (AirDrop/Messages/Mail/Copy) |
| 2026-10-17 | Shake rule reworked (stroke distance + 0.2 s pause reset + 1 s session) and covered by `--selftest`; share panel geometry refined |
| 2026-10-17 | Owner's app icon (background cut, macOS squircle mask) |
| 2026-10-17 | Grid view of individual items, single-item drag-out, Space = Quick Look, Delete = remove, real thumbnails in grid + fanned thumbnail stack, Dock menu sensitivity (Off/Low/Medium/High) |
| 2026-10-18 | Renamed to **DropHon** (bundle id `com.hon.drophon`, v1.0), universal build, zip package, GitHub release |

## Gotchas we already hit (don't repeat them)

- **`assert` is stripped in `-O` builds.** The selftest silently passed with no checks. Use `precondition`
- **`didSet` doesn't fire for assignments inside the class's own `init`.** The shelf showed "Drop files here" with 5 files. Call the refresh function by hand at the end of `init` (`urlsChanged()`)
- **`layer.cornerRadius` on a borderless window leaves square shadow corners.** Use `NSVisualEffectView.maskImage` (see `makeCard`)
- **Borderless `NSPanel` can't become key**, so keyboard events never arrive. Override `canBecomeKey` (`KeyPanel`)
- **`NSImageView` registers itself as a drag destination** and swallows drops meant for the parent. Call `unregisterDraggedTypes()`
- **Hiding the share panel on mouse up** can cancel a drop that's landing on a tile. Hide after 0.4 s
- Launching the app twice from `open` + the binary directly gives 2 shake monitors → 2 shelves. `pkill DropHon` before relaunching

## Not tested by hand yet

Only the look (screenshots) and the shake rule (selftest) were verified automatically. Needs a human with a real mouse: shake → shelf, dropping on a share tile (AirDrop sheet etc.), single-item drag out of the grid, Space/Delete in the grid, Dock right-click menu, Intel Mac.

## Next ideas (rough priority)

1. Global shortcut to open a shelf + shelf from clipboard
2. Ignored apps list (stop shelves popping up while dragging inside e.g. Figma/Finder reorder)
3. Dock shelf to screen edge + auto-retract
4. More actions in the grid: rename, zip, reveal in Finder, open with
5. Text / image / link drags (today: files only)
6. Ideas welcome
