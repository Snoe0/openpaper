import AppKit
import CanvasCore

/// Board titles, selection outlines and the outline of the element a menu is open for, drawn in screen
/// space so they keep their size at any zoom.
/// Never takes the pointer.
@MainActor
final class CanvasOverlayView: NSView {
    static let titleRowHeight: CGFloat = 24
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let titleColor = NSColor(white: 0.62, alpha: 1)
    private static let minimumTitleWidth: CGFloat = 24

    private var boards: [(board: CanvasBoard, rect: CGRect)] = []
    private var selectedIDs: Set<String> = []
    private var hoveredID: String?
    private var elementOutline: CGRect?

    /// The strip above a board (screen rect) that holds its title and takes title drags; nil when
    /// the board is too narrow on screen for a title, so nothing invisible can be grabbed.
    static func titleRow(above rect: CGRect) -> CGRect? {
        guard rect.width >= minimumTitleWidth else { return nil }
        return CGRect(x: rect.minX, y: rect.minY - titleRowHeight, width: rect.width, height: titleRowHeight)
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `boards` pairs each board with its on-screen rect; `elementOutline` is an element's on-screen rect.
    func update(boards: [(CanvasBoard, CGRect)], selectedIDs: Set<String>, hoveredID: String?, elementOutline: CGRect?) {
        self.boards = boards.map { (board: $0.0, rect: $0.1) }
        self.selectedIDs = selectedIDs
        self.hoveredID = hoveredID
        self.elementOutline = elementOutline
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (board, rect) in boards {
            guard rect.insetBy(dx: -2, dy: -Self.titleRowHeight).intersects(dirtyRect) else { continue }
            drawTitle(board.name, above: rect, selected: selectedIDs.contains(board.id))
            drawOutline(around: rect, for: board.id)
        }
        if let elementOutline { drawElementOutline(elementOutline) }
    }

    /// Like inspect mode's highlight: a thin blue line and a faint blue fill.
    private func drawElementOutline(_ rect: CGRect) {
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        rect.fill()
        stroke(rect, width: 1.5, color: .systemBlue)
    }

    private func drawTitle(_ name: String, above rect: CGRect, selected: Bool) {
        guard let row = Self.titleRow(above: rect) else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: selected ? NSColor.controlAccentColor : Self.titleColor,
            .paragraphStyle: style,
        ]
        let lineHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender)
        (name as NSString).draw(in: CGRect(x: row.minX, y: row.maxY - lineHeight - 6, width: row.width, height: lineHeight), withAttributes: attributes)
    }

    private func drawOutline(around rect: CGRect, for id: String) {
        if selectedIDs.contains(id) {
            stroke(rect, width: 2, color: .controlAccentColor)
        } else if id == hoveredID {
            stroke(rect, width: 1, color: NSColor.controlAccentColor.withAlphaComponent(0.6))
        } else {
            stroke(rect, width: 1, color: NSColor(white: 1, alpha: 0.08))
        }
    }

    private func stroke(_ rect: CGRect, width: CGFloat, color: NSColor) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -width / 2, dy: -width / 2))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
