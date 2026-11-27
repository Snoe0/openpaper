# Canvas

A native macOS infinite canvas of HTML artboards. Each artboard is real HTML/CSS/JS rendered in its own
WKWebView. Claude Code writes the designs through an MCP server (`canvas-mcp`) or by editing the
document's plain files; Canvas renders, arranges, syncs and presents them.

## Requirements

- macOS 15+, Xcode 26 (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); `xcbeautify` is optional

## Install

```sh
make install
```

This builds Release, copies `Canvas.app` to `/Applications` and links `~/.local/bin/canvas-mcp` to the
helper inside the installed app, so the CLI always matches the app. Override the locations with
`make install PREFIX_APPS=… PREFIX_BIN=…` (absolute paths). It refuses to replace a `Canvas.app`
that isn't this app. It then prints the command that connects Claude Code. It doesn't run it.

## Connect Claude Code

Either click **Connect agent…** in the app's Agent panel (it shows the command and runs it once you
confirm), or run it yourself:

```sh
claude mcp add --scope user canvas -- ~/.local/bin/canvas-mcp
```

Claude Code starts `canvas-mcp` itself. The CLI talks to the running app over a local, token-guarded
HTTP bridge (port and token in `~/Library/Application Support/Canvas/bridge.json`) and launches Canvas
when it isn't running. The Agent panel shows the bridge, the connected client and its last tool call.

## Usage

Ask Claude Code for a design, for example: *"Create a Canvas document at ~/Designs/Pricing, set up
light and dark tokens, and make a pricing page and a mobile checkout screen."* Claude creates or opens
the document, writes artboards, takes screenshots to check its work and reads the console for errors.
Select an artboard (or an element with the inspect tool) and ask Claude to change "this"; it reads
your selection.

### Documents

A document is a `Name.canvas` folder of plain files, so you can keep it in git and edit it by hand:

- `canvas.json`: pages, artboards (position, size, optional token mode) and the document mode
- `artboards/<id>.html`: one HTML body fragment per artboard, with its own `<style>` and `<script>`
- `components/<name>.html`: reusable components
- `tokens.json`: design tokens and their modes
- `assets/`: images, fonts and video, referenced relatively (`assets/hero.jpg`)
- `CLAUDE.md`: the format guide, written into every new document

Canvas reloads an artboard as soon as its file changes.

### Tokens and modes

Tokens become CSS variables (`color.bg` is `var(--color-bg)`). A token has one value, or one per mode,
such as `{"light": "#fff", "dark": "#111"}`. The document has a mode, and any artboard can override it,
which is how one design shows in light and dark side by side. Edit tokens in the sidebar's Tokens tab
or let Claude call `set_tokens` / `set_mode`.

### Components

`components/card.html` defines `<x-card>`: a template with `{{prop}}` or `{{prop|default}}`
placeholders and `<slot>`s. Use it as `<x-card title="Hello">children</x-card>`. Changing a component
updates every artboard that uses it.

### Presenting

**Present** (⌘↩) shows the selected artboard (or the page's first) fullscreen, live and interactive.
Esc or ⌘. exits.

### Shortcuts

| Keys | Action |
|---|---|
| ⌘N / ⌘O / ⌘W | New document / Open / Close tab |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⇧1 / ⇧2 | Zoom to fit / to selection |
| ⌘ + scroll, pinch | Zoom around the pointer |
| Scroll, Space + drag | Pan |
| ⌃⌘S | Hide or show the sidebar |
| ⌘↩ | Present |
| Esc | Leave inspect mode, or exit a presentation |

## Demo document

`Examples/Demo.canvas` is a travel-planning product called Tern: tokens with light and dark modes,
three components (`x-button`, `x-trip-card`, `x-stop`), and two pages. **Website** has an animated hero
and a saved-trips grid. **App** has a mobile itinerary in light and dark and an import-progress screen.
Open it from **File > Open…**, or ask Claude to open it.

## Development

```sh
make build   # generate Canvas.xcodeproj and build Debug into ./.build
make test    # run the CanvasCore unit tests
make run     # build and open Canvas.app
make e2e     # end-to-end test (below)
```

`Canvas.xcodeproj` is generated from `project.yml`; don't edit it by hand. Every target accepts
`DERIVED_DATA=…` to build somewhere other than `./.build`.

### End-to-end test

`make e2e` builds Debug if needed and runs `Tests/E2E/E2E.swift`, which launches the built app and
drives the real `canvas-mcp` over stdio JSON-RPC: it creates a document, sets tokens with two modes,
writes a component, creates three animated artboards, checks screenshots pixel by pixel (size, not
blank, the component's colour, the mode's background), edits an artboard and the component, switches
the mode, checks the console has no errors, and round-trips pages.

It doesn't touch your real Canvas state. The app runs as a temporary copy with its own bundle id
(`local.canvas.e2e`), so its user defaults, caches (artboard snapshots included) and saved state are
separate, and `bridge.json` goes to a temp folder (`CANVAS_BRIDGE_FILE`). Everything is removed on exit,
also on failure or Ctrl-C. It never reads or writes Claude Code's config: the app gets
`CLAUDE_CONFIG_DIR` pointing at the temp folder. State left over from an interrupted run (only the test
bundle id's) is cleared at the start. If another run's copy is still running, it stops instead.
