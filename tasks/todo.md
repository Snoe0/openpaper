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

- [ ] **T1 Scaffold** (wave 1)
  - Files: `project.yml`, `Makefile`, `.gitignore`, `README.md`, stub `Sources/{CanvasCore,Canvas,canvas-mcp}/`, `Tests/CanvasCoreTests/`
  - Done when: xcodegen generates the app, a CanvasCore framework, the canvas-mcp CLI and the tests; `make build` / `make test` / `make run` work; an empty window opens
  - Verify: `make build && make test`
- [ ] **T2 Document model + store** (wave 2, after T1)
  - Files: `Sources/CanvasCore/Document/*`, `Tests/CanvasCoreTests/Document*`
  - Done when: create/load/save the package; CRUD for pages, artboards, components and tokens; the token→CSS compiler handles modes; the HTML assembler builds a full page per artboard; the file watcher emits typed change events (artboard/component/tokens/manifest); `CLAUDE.md` template is written on create
  - Verify: `make test`
- [ ] **T3 Web runtime (`runtime.js`)** (wave 2, parallel with T2, disjoint files)
  - Files: `Sources/CanvasCore/Resources/runtime.js`, `Tests/CanvasCoreTests/Runtime*`
  - Done when: the `window.Canvas` API has `defineComponents(map)` (props + slots, hot re-render of instances), `setTokens(css)`, `setMode(m)`, `pause()`/`resume()`/`restart()` (Web Animations, media, rAF + timer gate), `inspect(on)` (hover highlight, click → selector + outerHTML posted to `webkit.messageHandlers.canvas`), and console/error capture posted to Swift
  - Verify: `make test` (WKWebView-backed XCTest)
- [ ] **T4 Canvas view** (wave 3, after T2, T3)
  - Files: `Sources/Canvas/Canvas/*`
  - Done when: pan (scroll/space-drag), pinch/⌘-scroll zoom, zoom-to-fit (⇧1) and zoom-to-selection (⇧2); artboards render crisp at any zoom; click selects, title-drag moves (persisted); double-click enters inspect mode, Esc exits; a hover bar has play/pause/restart and mode toggle; the visibility manager does snapshot + pause + detach + LRU pool
  - Verify: `make test`, plus a manual run with 30 animated boards: CPU near idle when zoomed out
- [ ] **T5 MCP bridge** (wave 3, parallel with T4, disjoint files)
  - Files: `Sources/CanvasCore/Bridge/*`, `Sources/canvas-mcp/*`, `Tests/CanvasCoreTests/Bridge*`
  - Done when: tools take an optional `page` (default: current page), and there are `list_pages`/`create_page`/`switch_page` tools; the bridge records the last tool call and connection status for the UI; localhost HTTP server in the app (random port + token in `~/Library/Application Support/Canvas/bridge.json`), using a `CanvasController` protocol the app implements; stdio JSON-RPC MCP in the CLI (no deps); tools: `get_document`, `open_document`, `create_document`, `create_artboard`, `read_artboard`, `write_artboard`, `edit_artboard` (str-replace), `update_artboard` (name/size/position/mode), `delete_artboard`, `duplicate_artboard`, `get_selection`, `screenshot` (returns a PNG image), `get_console`, `focus_artboard`, `list_components`, `read_component`, `write_component`, `delete_component`, `get_tokens`, `set_tokens`, `set_mode`; server `instructions` explain the format
  - Verify: `make test` (scripted JSON-RPC session against a mock controller)
- [ ] **T6 App shell** (wave 4, after T4, T5)
  - Files: `Sources/Canvas/App/*`, `Sources/Canvas/Sidebar/*`
  - Done when: document tabs and a Dashboard tab (recent documents, new/open); left sidebar with a Design/Tokens toggle (pages, artboards, components; token values, add token, global mode switch); tool rail; right panel (zoom, board info, MCP "Connect agent" button that runs `claude mcp add` after a confirm dialog, then shows live status and last call); app implements `CanvasController` and starts the bridge; menu commands and shortcuts; "Present" wired to T7's API
  - Verify: `make build`, plus manual run
- [ ] **T7 Presentation mode** (wave 4, parallel with T6, disjoint files)
  - Files: `Sources/Canvas/Presentation/*`
  - Done when: `PresentationController.present(artboard:in:)` fullscreens one artboard in a live, interactive WKWebView, fit to screen on a black backdrop; Esc exits; animations restart on enter
  - Verify: `make build`, plus manual run
- [ ] **T8 End-to-end + install** (wave 5)
  - Files: `Tests/E2E/*`, `Examples/Demo.canvas/`, `Makefile` (install target), `README.md`
  - Done when: the E2E script drives the real `canvas-mcp` against the running app (create doc → tokens → component → 3 animated artboards → screenshot → edit component → instances update); `make install` copies the app to /Applications and the CLI to `~/.local/bin`, and prints the `claude mcp add` command (it doesn't run it); a demo doc is shipped
  - Verify: `make e2e`

### Out of scope for v1
Manual property editing, pen/vector tools, code export, undo history (keep docs in git), cloud, teams.

### Git
Initial commit on `main`, then a `v1` branch. One commit per task after both reviews pass. No push.
