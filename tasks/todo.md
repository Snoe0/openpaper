## Canvas v1 — native HTML design canvas driven by Claude Code (2026-11-20)

Native macOS app (Swift 6.3, AppKit, macOS 15+). An infinite canvas of artboards, where every artboard is real HTML/CSS/JS rendered in its own WKWebView. You don't edit by hand in v1: Claude Code writes designs through MCP or plain files, and the app renders, arranges, syncs and presents them.

### Architecture

- **Document = folder package** `Name.canvas/` (Claude can edit it directly):
  - `canvas.json`: pages (`id, name`), artboards (`id, page, name, file, x, y, width, height, mode?`) and the global token mode
  - `artboards/<id>.html`: a body fragment, which can hold its own `<style>` and `<script>`
  - `components/<name>.html`: a template with `{{prop}}` placeholders and `<slot>`s, used as `<x-name prop="…">`
  - `tokens.json`: `{ modes: ["light","dark"], tokens: { "color.bg": { light, dark } } }`, compiled to `--color-bg` CSS vars
  - `assets/`: images and fonts, served through a `canvas://` WKURLSchemeHandler
  - `CLAUDE.md`: format guide written into each document
- **Rendering:** each artboard is assembled from the tokens CSS, `runtime.js`, the component registry and the body. It loads in a WKWebView at native size, then gets scaled onto the canvas.
- **Performance:** if a board is offscreen, or its on-screen scale is below the threshold (~0.3), the app snapshots it, pauses it (Web Animations, media, rAF/timers via runtime) and detaches its web view. An LRU pool caps the number of live web views (~12).
- **Live sync:** a file watcher reloads a board when its artboard file changes. Component and token edits hot-patch every live board without a reload.
- **UI:** a dark layout in the style of Paper, with our own styling: SF fonts and native vibrancy, no copied assets.
  - Top: document tabs, plus a Dashboard tab listing recent documents
  - Left sidebar: document name and a Design/Tokens toggle. Design shows Pages, then the current page's artboards. Tokens shows token values and modes.
  - Slim tool rail: select, hand, inspect, present
  - Canvas in the middle
  - Right panel: zoom %, selected board info, and an MCP section with a "Connect agent" button and live status
- **Claude IO:** the `canvas-mcp` CLI is a stdio MCP server, registered with `claude mcp add`. It forwards calls to the running app over localhost HTTP, using a token, and launches the app if it isn't running. Claude can also edit the document's files directly.

### Tasks

- [x] **T1 Scaffold** (wave 1)
  - Files: `project.yml`, `Makefile`, `.gitignore`, `README.md`, stub `Sources/{CanvasCore,Canvas,canvas-mcp}/`, `Tests/CanvasCoreTests/`
  - Done when: xcodegen generates the app, a CanvasCore framework, the canvas-mcp CLI and the tests; `make build` / `make test` / `make run` work; an empty window opens
  - Verify: `make build && make test`
- [x] **T2 Document model + store** (wave 2, after T1)
  - Files: `Sources/CanvasCore/Document/*`, `Tests/CanvasCoreTests/Document*`
  - Done when: create/load/save the package; CRUD for pages, artboards, components and tokens; the token→CSS compiler handles modes; the HTML assembler builds a full page per artboard; the file watcher emits typed change events (artboard/component/tokens/manifest); `CLAUDE.md` template is written on create
  - Verify: `make test`
- [x] **T3 Web runtime (`runtime.js`)** (wave 2, parallel with T2, disjoint files)
  - Files: `Sources/CanvasCore/Resources/runtime.js`, `Tests/CanvasCoreTests/Runtime*`
  - Done when: the `window.Canvas` API has `defineComponents(map)` (props + slots, hot re-render of instances), `setTokens(css)`, `setMode(m)`, `pause()`/`resume()`/`restart()` (Web Animations, media, rAF + timer gate), `inspect(on)` (hover highlight, click → selector + outerHTML posted to `webkit.messageHandlers.canvas`), and console/error capture posted to Swift
  - Verify: `make test` (WKWebView-backed XCTest)
- [x] **T4 Canvas view** (wave 3, after T2, T3)
  - Files: `Sources/Canvas/Canvas/*`
  - Done when: pan (scroll/space-drag), pinch/⌘-scroll zoom, zoom-to-fit (⇧1) and zoom-to-selection (⇧2); artboards render crisp at any zoom; click selects, title-drag moves (persisted); double-click enters inspect mode, Esc exits; a hover bar has play/pause/restart and mode toggle; the visibility manager does snapshot + pause + detach + LRU pool
  - Verify: `make test`, plus a manual run with 30 animated boards: CPU near idle when zoomed out
- [x] **T5 MCP bridge** (wave 3, parallel with T4, disjoint files)
  - Files: `Sources/CanvasCore/Bridge/*`, `Sources/canvas-mcp/*`, `Tests/CanvasCoreTests/Bridge*`
  - Done when: tools take an optional `page` (default: current page), and there are `list_pages`/`create_page`/`switch_page` tools; the bridge records the last tool call and connection status for the UI; localhost HTTP server in the app (random port + token in `~/Library/Application Support/Canvas/bridge.json`), using a `CanvasController` protocol the app implements; stdio JSON-RPC MCP in the CLI (no deps); tools: `get_document`, `open_document`, `create_document`, `create_artboard`, `read_artboard`, `write_artboard`, `edit_artboard` (str-replace), `update_artboard` (name/size/position/mode), `delete_artboard`, `duplicate_artboard`, `get_selection`, `screenshot` (returns a PNG image), `get_console`, `focus_artboard`, `list_components`, `read_component`, `write_component`, `delete_component`, `get_tokens`, `set_tokens`, `set_mode`; server `instructions` explain the format
  - Verify: `make test` (scripted JSON-RPC session against a mock controller)
- [x] **T6 App shell** (wave 4, after T4, T5)
  - Files: `Sources/Canvas/App/*`, `Sources/Canvas/Sidebar/*`
  - Done when: document tabs and a Dashboard tab (recent documents, new/open); left sidebar with a Design/Tokens toggle (pages, artboards, components; token values, add token, global mode switch); tool rail; right panel (zoom, board info, MCP "Connect agent" button that runs `claude mcp add` after a confirm dialog, then shows live status and last call); app implements `CanvasController` and starts the bridge; menu commands and shortcuts; "Present" wired to T7's API
  - Verify: `make build`, plus manual run
- [x] **T7 Presentation mode** (wave 4, parallel with T6, disjoint files)
  - Files: `Sources/Canvas/Presentation/*`
  - Done when: `PresentationController.present(artboard:in:)` fullscreens one artboard in a live, interactive WKWebView, fit to screen on a black backdrop; Esc exits; animations restart on enter
  - Verify: `make build`, plus manual run
- [x] **T8 End-to-end + install** (wave 5)
  - Files: `Tests/E2E/*`, `Examples/Demo.canvas/`, `Makefile` (install target), `README.md`
  - Done when: the E2E script drives the real `canvas-mcp` against the running app (create doc → tokens → component → 3 animated artboards → screenshot → edit component → instances update); `make install` copies the app to /Applications and the CLI to `~/.local/bin`, and prints the `claude mcp add` command (it doesn't run it); a demo doc is shipped
  - Verify: `make e2e`
- [x] **T9 Copy pointer** (added 2026-11-21, after the final-review fixes)
  - Right-click any element on any board, at any zoom, without entering inspect mode. A board showing a snapshot loads live for that moment. The element under the cursor stays outlined while the menu is open.
  - Menu items:
    - **Copy pointer:** copies `canvas:<board id> > <selector>` (e.g. `canvas:hero > section.pricing > a.cta`). It uses the same selector builder as inspect mode.
    - **Copy board pointer:** copies `canvas:<board id>`.
    - **Copy HTML:** copies the element's outerHTML.
  - Right-clicking a board's title or empty space offers Copy board pointer only. Inside an inspected board this menu replaces WebKit's own.
  - New MCP tool `get_element(pointer)`. It returns the board, the selector, the outerHTML, the box in board CSS pixels and the key computed styles. For a board pointer it returns the board's info. If nothing matches anymore, it says the pointer is stale and why (board gone, or no element matches). The server instructions explain pointers.
  - Pointer parsing is shared, so the notes feature can add `canvas:image/<id>` and `canvas:comment/<id>` later.
  - Files: `Sources/CanvasCore/Canvas/Pointer.swift` (new), `Sources/CanvasCore/Bridge/*`, `Sources/CanvasCore/Resources/runtime.js`, `Sources/Canvas/Canvas/*`, tests, plus an E2E step.
  - Done when: right-click → Copy pointer on a canvas board at 30% puts the pointer on the clipboard; `get_element` with that pointer returns the element's HTML through `canvas-mcp`; a pointer to a removed element is reported as stale.
  - Verify: `make test`, `make e2e`, plus a manual right-click check
- [x] **T10 Huge-board snapshots** (added 2026-11-21; you picked "Smaller snapshots")
  - Above roughly 400M device pixels WebKit returned a transparent image (e.g. 4096×32768, or 8192×16384) or an error (16384×16384), because the snapshot always asked for native width.
  - Shipped (no tiles needed): a large board is snapshotted once with a smaller `snapshotWidth`, so the output stays under about 32M pixels (`SnapshotSize`). The biggest boards come out at reduced resolution, never blank. Small boards keep 1 px per CSS px.
  - This applies to canvas snapshots and to the MCP `screenshot`.
  - Files: `Sources/Canvas/Canvas/LiveBoard.swift` (`pngSnapshot`), plus `SnapshotSize` in CanvasCore with unit tests for the scale math.
  - Done when: 16384×32768, 8192×16384 and 4096×32768 boards render with visible content top to bottom; a 1440×900 board is unchanged.
  - Verify: `make test`, plus a WK test or manual check on a 16384×32768 board
- [x] **T11 Snapshots wait for entrance animations** (added 2026-11-21; you picked "Wait for animations (Recommended)")
  - Today a snapshot is taken 250 ms after load, so fade-ins and slide-ups are caught halfway.
  - Fix: `runtime.js` gets `Canvas.settled()`, which resolves once every finite Web Animation (CSS animations and transitions included) has finished, ignoring infinite ones, capped at 3 s. The snapshot path awaits it instead of the fixed 250 ms.
  - Files: `Sources/CanvasCore/Resources/runtime.js`, `Sources/Canvas/Canvas/SnapshotRenderer.swift` (and wherever else the settle lives), tests.
  - Done when: a board with a 1 s fade-in snapshots fully visible; a board with only a looping animation snapshots within about 250 ms; a 10 s animation snapshots at about 3 s.
  - Verify: `make test` (runtime WK test), `make e2e`

### Out of scope for v1
Manual property editing, pen/vector tools, code export, undo history (keep docs in git), cloud, teams.

### Git
Initial commit on `main`, then a `v1` branch. One commit per task after both reviews pass. No push.

## Review

### Built vs plan
All of T1–T8 shipped as planned, one commit per task after spec and quality reviews, plus one fix commit for T4 (clipping and text layout below 100%) and one for the final review (geometry caps, boards stay on their own page, DEBUG-only dev hooks, mode-name validation, race-free deletes, select only in inspect mode). Branch is `feat/v1` (plan said `v1`). Verified: `make test` (370 tests), Release build, `make e2e` twice, `make install` into a scratch folder. Then T9, T10 and T11, plus a second final-review fix round. Verified again: `make test` (419 tests), Release build, `make e2e` twice.

### Deviations from the plan
- `make install` symlinks the `canvas-mcp` CLI into the bin folder instead of copying it, so it always matches the installed app.
- The snapshot cache lives under `~/Library/Caches/<bundle id>/Snapshots`, so dev and installed builds don't share it.
- `PageHost` (new): below 100% a page lays out at board size with pageZoom 1 and is scaled by the canvas, because WebKit's 9 px minimum font inflated text. Presentation uses it too.
- Live web views are capped by a pixel budget (6 MP below 100%) on top of the LRU count; the inspected/kept board, else the nearest, is always live. Picked by you: "Pixel budget (Recommended)".
- Artboards are capped at 16384 px wide and 32768 px high (picked by you: "Raise height only", "32768 (Recommended)"), with positions within ±1,000,000. Docs that break these, or use mode names outside `[A-Za-z0-9_-]`, are refused as malformed.

### Open items
- DevRemote click doesn't select a board (dev tooling only; same before the fix commits).
- Presentation after the PageHost change wasn't screenshotted: check by hand (present Website → Hero).
- Snapshot cache is unbounded, and PNG writes happen on the main thread.
- 3 MP budget lever if memory matters: 6 website boards at 30% use 407 MB vs 223 MB before the budget.
- Small cleanups: `HTTPRequest.parse` is used only by tests; `placeholder.txt` left over; the version string lives in 3 places.
- The old `~/Library/Caches/Canvas` folder is orphaned; you can delete it.
- `insert` picks the new id and writes its HTML from the in-memory manifest, so an outside edit that just added a board with the same id could have its file overwritten (same race class as the delete fix; follow-up).
- In a presentation, a link opened from the keyboard (Tab, then Enter) no longer opens the browser: macOS gives no public way to tell it apart from a script's `a.click()`, so only real mouse clicks open links. The E2E step for scripted clicks is a smoke test only; the click check is covered by unit tests and a manual measurement.
- T10 (acb1bb4) shipped without tiles: WebKit does honor `snapshotWidth` (the earlier "ignored" finding came from always passing the native width), so one reduced snapshot is enough. Boards between 32M and ~100M px used to snapshot at full resolution and now come out smaller (e.g. 8192×8192 → 5792×5792). Snapshot timeout is now 10 s. Follow-ups: blank PNGs cached by older builds stay until the board changes or the cache is cleared; PNG encode still runs on the main thread.
- T9 (10b6754): Copy pointer, Copy board pointer, Copy HTML, and `get_element`. Live check at 30%: the pointer landed on a private pasteboard (`CANVAS_PASTEBOARD`, DEBUG only). Right-clicking empty canvas between boards opens no menu, since there's no board to point to; a board's title and page background offer Copy board pointer. Pointers use positional selectors (`div:nth-of-type(1)`), so they're for short-term use; the MCP instructions say so. DevRemote lost `eval` and its in-app screen capture. Follow-ups: a left-click or Esc during the lookup (up to 1.5 s) doesn't cancel the menu; each right-click serializes the element's full outerHTML; a slow live page can take up to ~15 s to answer `get_element`; `get_element` on a board that isn't live loads it without a window and gives up after 5 s, while `screenshot` waits 20 s; a page that hangs after loading keeps its web view after a timeout.
- T11 (1b550f5): `Canvas.settled()` waits for finite animations and transitions, including inside components and chained on `animationend`, capped at 3 s. Measured in the real hidden snapshot window: static 0.03 s, looping 0.09 s, 1 s fade-in 1.02 s. Not waited for: animations a page starts later from its own timers.
- Final-review fixes: live `screenshot` also waits for animations (one shared `LiveBoard.waitUntilSettled`); a right-click no longer overwrites a good cached snapshot; a new board you pan away from is cached after its animations settle; a board deleted mid-query reports a stale pointer; the 20000-char HTML cap is defined once per language; the pointer menu stays inside the visible canvas. Follow-ups: a board that is still settling can be rendered twice (harmless, wasted work); the pixel budget can run over for up to ~3 s while a board settles; the cached PNG is read on the main thread on each suspend.
- `Workspace.adopt(_:)` is now only called from DEBUG code; no unit test for an empty `CANVAS_APP_BUNDLE_ID` (the CLI has no test target).

### Accepted limitations and notes per task
- T3 minors accepted: held media rejects page's `play()` with AbortError; detached `new Audio()` not held; declarative/closed pre-existing shadow roots not tracked; restart fires animationcancel/start; interval drift; branching component cycles bounded only by depth cap; one-shots with different keyframes bounded by 200 cap; untracked animation's finish handler can still prune (one-line guard).
- T5 minors: small rejected request may surface as reset; 60 s idle timeout also closes authenticated keep-alive (race → networkConnectionLost); `testReportsARejectedTokenAsSuch` should set an invalid `CANVAS_APP_BUNDLE_ID`; launch timeout cached 30 s; deprecated `String(cString:)` in BridgeSocketSupport.swift:122.
- T6 must (done in 5a38785): offer a bridge restart when `BridgeServer` stops after listener failure.
- T7 accepted limitations: an app-modal alert opened during a presentation sits behind the presentation window; with several displays, a document window on another screen can't take typing while presenting; height-limited boards can show ≤2 pt black bands (PageFit whole-point width); edits reload the page (animations restart). Esc-repeat swallowing and key take-back not exercised at runtime by the agent; check by hand.
- T5 flake: `BridgeServerTests.testReleasingAStartedServerStopsIt` failed once under load during T6's run (passed 3/3 alone).
- T6 notes: Connect status reads `~/.claude.json` (or `$CLAUDE_CONFIG_DIR`) — Claude Code's internal format; unreadable → "Unknown". Token value inline edit + delete kept (beyond "add token"). Background tabs keep their live web views (memory; revisit). Not exercised live by agents: Present click, Connect/Reconnect (would write the Claude config), Restart bridge, Tab between token fields.
- T8 (92b764e): snapshot cache moved to `~/Library/Caches/<bundle id>/Snapshots`, so the old `~/Library/Caches/Canvas` is orphaned (user may delete it). `make app-path` still uses `abspath` (breaks with spaces; print-only). Two e2e runs started at the same instant can both pass the pgrep check. The demo's `itinerary-dark.html` duplicates `itinerary.html` (only the mode differs).
