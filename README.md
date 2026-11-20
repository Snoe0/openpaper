# Canvas

A native macOS infinite canvas of HTML artboards. Each artboard is real HTML/CSS/JS rendered in its own
WKWebView. Claude Code writes the designs through an MCP server (`canvas-mcp`) or by editing the
document's plain files; Canvas renders, arranges, syncs and presents them.

## Requirements

- macOS 15+, Xcode 26 (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); `xcbeautify` is optional

## Build

```sh
make build   # generate Canvas.xcodeproj and build into ./.build
make test    # run the CanvasCore unit tests
make run     # build and open Canvas.app
```

`Canvas.xcodeproj` is generated from `project.yml`; don't edit it by hand.
