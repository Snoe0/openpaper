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
public struct VisibilityPolicy: Sendable {
    public var minLiveScale: CGFloat
    public var margin: CGFloat
    public var capacity: Int

    public init(minLiveScale: CGFloat = 0.3, margin: CGFloat = 100, capacity: Int = 12) {
        self.minLiveScale = minLiveScale
        self.margin = margin
        self.capacity = capacity
    }

    public func liveBoards(_ boards: [BoardFrame], viewport: Viewport, screenSize: CGSize) -> [String] {
        guard viewport.scale >= minLiveScale else { return [] }
        let area = liveArea(viewport: viewport, screenSize: screenSize)
        let nearby = boards.filter { $0.rect.intersects(area) }
        return Array(Self.nearestFirst(nearby, to: CGPoint(x: area.midX, y: area.midY)).prefix(capacity))
    }

    /// Board ids by the distance of their centres to `point`, then by id.
    public static func nearestFirst(_ boards: [BoardFrame], to point: CGPoint) -> [String] {
        boards
            .map { (id: $0.id, distance: squaredDistance(from: point, to: CGPoint(x: $0.rect.midX, y: $0.rect.midY))) }
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
            .map(\.id)
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
