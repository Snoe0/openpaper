import CoreGraphics

/// How a live page fills its board on screen: a frame in whole points, and the page zoom that makes
/// the page's CSS viewport exactly the board's width. WebKit lays a page out from its view's width
/// in whole points, so any fraction would narrow the viewport and flip width breakpoints. The height
/// uses the same zoom and is rounded up to whole points, so the page covers the whole board; the
/// board view clips the overhang (under a point).
public struct PageFit: Equatable, Sendable {
    public var frameSize: CGSize
    public var zoom: CGFloat

    public init(boardSize: CGSize, scale: CGFloat) {
        let wholePoints = { (points: CGFloat, rule: FloatingPointRoundingRule) in max(points.rounded(rule), 1) }
        let width = wholePoints(boardSize.width * scale, .down)
        zoom = width / boardSize.width
        frameSize = CGSize(width: width, height: wholePoints(boardSize.height * zoom, .up))
    }
}
