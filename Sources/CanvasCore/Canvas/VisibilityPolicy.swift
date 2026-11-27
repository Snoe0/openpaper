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
/// pixels) also stays within `liveAreaBudget`; boards that don't fit are skipped. Kept boards (the one whose
/// menu is open, the inspected one), or else the nearest board, are always live however large.
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

    /// `kept` boards (the one whose menu is open, the inspected one) are live whatever their scale, place or
    /// size, first and in order, and count toward `capacity` and the budget.
    public func liveBoards(_ boards: [BoardFrame], viewport: Viewport, screenSize: CGSize, keeping kept: [String] = []) -> [String] {
        let keptBoards = Self.unique(kept).compactMap { id in boards.first { $0.id == id } }
        guard viewport.scale >= minLiveScale else { return withinLimits(keptBoards, scale: viewport.scale) }
        let area = liveArea(viewport: viewport, screenSize: screenSize)
        let nearby = boards.filter { $0.rect.intersects(area) && !kept.contains($0.id) }
        return withinLimits(keptBoards, then: Self.sortedNearestFirst(nearby, to: CGPoint(x: area.midX, y: area.midY)), scale: viewport.scale)
    }

    /// Board ids by the distance of their centres to `point`, then by id.
    public static func nearestFirst(_ boards: [BoardFrame], to point: CGPoint) -> [String] {
        sortedNearestFirst(boards, to: point).map(\.id)
    }

    /// The first boards, in order, that fit `capacity` and, below 100%, the area budget. Kept boards are
    /// always taken, even over the budget, and so is the first one when none is kept; a board too large for
    /// what's left of the budget is skipped for smaller ones further on.
    private func withinLimits(_ kept: [BoardFrame], then ordered: [BoardFrame] = [], scale: CGFloat) -> [String] {
        var live: [String] = []
        var area: CGFloat = 0
        for (index, board) in (kept + ordered).enumerated() where live.count < capacity {
            let boardArea = board.rect.width * board.rect.height
            let exempt = index < max(kept.count, 1)
            if scale < 1, !exempt, area + boardArea > liveAreaBudget { continue }
            live.append(board.id)
            area += boardArea
        }
        return live
    }

    private static func unique(_ ids: [String]) -> [String] {
        ids.enumerated().filter { ids.firstIndex(of: $0.element) == $0.offset }.map(\.element)
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
