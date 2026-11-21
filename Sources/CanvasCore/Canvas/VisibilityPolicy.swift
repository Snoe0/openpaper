import CoreGraphics

/// An artboard's place on the canvas, in canvas points.
public struct BoardFrame: Equatable, Sendable {
    public var id: String
    public var rect: CGRect

    public init(id: String, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// Decides which boards deserve a live web view: those near the viewport (within `margin` screen
/// points) shown at `minLiveScale` or more, closest to the viewport centre first, at most `capacity`.
/// Below 100% WebKit rasterises a live page at its board size, so there the boards' total area (CSS
/// pixels) also stays within `liveAreaBudget`; boards that don't fit are skipped. The first board, the
/// kept (inspected) one if there is one, else the nearest, is always live however large.
public struct VisibilityPolicy: Sendable {
    public var minLiveScale: CGFloat
    public var margin: CGFloat
    public var capacity: Int
    public var liveAreaBudget: CGFloat

    public init(minLiveScale: CGFloat = 0.3, margin: CGFloat = 100, capacity: Int = 12, liveAreaBudget: CGFloat = 6_000_000) {
        self.minLiveScale = minLiveScale
        self.margin = margin
        self.capacity = capacity
        self.liveAreaBudget = liveAreaBudget
    }

    /// `kept` (the inspected board) is live whatever its scale or place, first, and counts toward
    /// `capacity` and the budget.
    public func liveBoards(_ boards: [BoardFrame], viewport: Viewport, screenSize: CGSize, keeping kept: String? = nil) -> [String] {
        let keptBoard = boards.first { $0.id == kept }
        let candidates = keptBoard.map { [$0] } ?? []
        guard viewport.scale >= minLiveScale else { return withinLimits(candidates, scale: viewport.scale) }
        let area = liveArea(viewport: viewport, screenSize: screenSize)
        let nearby = boards.filter { $0.rect.intersects(area) && $0.id != kept }
        return withinLimits(candidates + Self.sortedNearestFirst(nearby, to: CGPoint(x: area.midX, y: area.midY)), scale: viewport.scale)
    }

    /// Board ids by the distance of their centres to `point`, then by id.
    public static func nearestFirst(_ boards: [BoardFrame], to point: CGPoint) -> [String] {
        sortedNearestFirst(boards, to: point).map(\.id)
    }

    /// The first boards, in order, that fit `capacity` and, below 100%, the area budget. The first board
    /// (the kept one, else the nearest) is always taken, even over the budget; a board too large for
    /// what's left of the budget is skipped for smaller ones further on.
    private func withinLimits(_ ordered: [BoardFrame], scale: CGFloat) -> [String] {
        var live: [String] = []
        var area: CGFloat = 0
        for board in ordered where live.count < capacity {
            let boardArea = board.rect.width * board.rect.height
            if scale < 1, !live.isEmpty, area + boardArea > liveAreaBudget { continue }
            live.append(board.id)
            area += boardArea
        }
        return live
    }

    private static func sortedNearestFirst(_ boards: [BoardFrame], to point: CGPoint) -> [BoardFrame] {
        boards
            .map { (board: $0, distance: squaredDistance(from: point, to: CGPoint(x: $0.rect.midX, y: $0.rect.midY))) }
            .sorted { ($0.distance, $0.board.id) < ($1.distance, $1.board.id) }
            .map(\.board)
    }

    /// The visible canvas rect grown by the margin.
    private func liveArea(viewport: Viewport, screenSize: CGSize) -> CGRect {
        let inset = margin / viewport.scale
        return viewport.visibleCanvasRect(screenSize: screenSize).insetBy(dx: -inset, dy: -inset)
    }

    private static func squaredDistance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}
