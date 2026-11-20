import Foundation

/// The format guide written as `CLAUDE.md` into every new document, also used as MCP server instructions.
public enum DocumentGuide {
    public static let markdown = """
    # Canvas document

    This folder is a Canvas design document. The Canvas app renders it live: every artboard is real HTML/CSS/JS in its own web view, and the app reloads it as soon as a file changes. Edit the files directly or use the Canvas MCP tools.

    ## Layout

    - `canvas.json`: pages, artboards (`id`, `page`, `name`, `file`, `x`, `y`, `width`, `height`, `mode`) and the document `mode`.
    - `tokens.json`: design tokens and their modes.
    - `artboards/<id>.html`: one artboard each.
    - `components/<name>.html`: one reusable component each.
    - `assets/`: images, fonts and video.

    ## Artboards

    - An artboard file is a body fragment: no `<html>`, `<head>` or `<body>`. It may contain its own `<style>` and `<script>`.
    - The page is exactly the artboard's `width` × `height` in CSS pixels, with no margin and no scrolling. Design to fill that box.
    - To add an artboard by hand, write `artboards/<id>.html`, then add its entry to `canvas.json`. A file with no entry is ignored.
    - Any CSS or JS animation is fine. The app pauses boards that are offscreen or zoomed out, so don't throttle anything yourself.

    ## Tokens

    - Use tokens through CSS variables: `color.bg` becomes `var(--color-bg)`, and `radius.md` becomes `var(--radius-md)`.
    - Any character other than letters, digits, `-` and `_` becomes `-`, so `color.bg` and `color-bg` would both be `--color-bg`. Don't define both.
    - Token values can't contain `{`, `}`, `;` or `<`.
    - A token value is either a string (the same in every mode) or an object keyed by mode, e.g. `{ "light": "#fff", "dark": "#000" }`. A missing mode falls back to the first mode.
    - The active mode is set on `<html data-mode="…">`: the document `mode`, unless the artboard sets its own `mode`. Style per mode with `[data-mode="dark"] …` if tokens aren't enough.
    - Prefer tokens over hard-coded colors, fonts, radii and spacing, so every artboard stays in sync.

    ## Components

    - `components/button.html` defines `<x-button>`. Names are lowercase: letters, digits and `-`, starting with a letter.
    - The file is a template: HTML with an optional `<style>`, `{{prop}}` or `{{prop|default}}` placeholders, and `<slot>` / `<slot name="icon">`.
    - Use it as `<x-button label="Buy" tone="primary">children</x-button>`. Attributes fill the placeholders, children fill the slots (`slot="icon"` for named slots).
    - Props work only in text content or inside quoted attribute values (`class="{{tone}}"`). Values are HTML-escaped, so a prop doesn't work inside `<style>` or `<script>`, or in an unquoted attribute. For per-instance styling, pass a CSS custom property, e.g. `<x-card style="--accent: red">`, and use `var(--accent)` in the template's `<style>`.
    - Editing a component updates every artboard that uses it.

    ## Assets

    - Put files in `assets/` and reference them relatively: `<img src="assets/hero.png">`, `url(assets/font.woff2)`.
    - Don't use absolute file paths; pages are served from the document folder.

    ## Editing `canvas.json`

    - Keep it valid JSON. If it fails to parse, the app keeps showing the last valid version.
    - Artboard ids are lowercase slugs and must be unique; `file` is `artboards/<id>.html`. Leave `version` alone.
    """
}
