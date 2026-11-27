import CoreGraphics

/// How a live page fills its board view while laying out at the board's own CSS size, so it lines up
/// with the snapshot under it. `onScreen` is the board view's size, already snapped to device pixels
/// (at least 1×1, so a host whose board view isn't laid out yet keeps a finite bounds scale).
///
/// - Below 100% the page isn't zoomed (see `PageHost`): the host is exactly the board view, and its
///   bounds are the board, so AppKit draws the full-size page shrunk to cover the board view.
/// - At 100% and up the page zoom scales it up crisply. WebKit lays a page out from its view's width in
///   whole points, so the width is rounded down (a fraction would narrow the viewport and flip width
///   breakpoints; the page falls under a point short) and the height rounded up (the board view clips it).
public struct PageFit: Equatable, Sendable {
    /// The host's frame: the board on screen.
    public var frameSize: CGSize
    /// The host's bounds, and the web view's frame: the size the page lays out at before the zoom.
    public var boundsSize: CGSize
    /// The web view's page zoom: 1 below 100%, else the zoom that scales the board up to the frame.
    public var pageZoom: CGFloat

    public init(boardSize: CGSize, onScreen: CGSize) {
        let onScreen = CGSize(width: max(onScreen.width, 1), height: max(onScreen.height, 1))
        let wholeWidth = onScreen.width.rounded(.down)
        if wholeWidth < boardSize.width {
            frameSize = onScreen
            boundsSize = boardSize
            pageZoom = 1
        } else {
            frameSize = CGSize(width: wholeWidth, height: onScreen.height.rounded(.up))
            boundsSize = frameSize
            pageZoom = Self.zoom(showing: boardSize.width, in: wholeWidth)
        }
    }

    /// Presentation: the largest whole-point size of the board's shape inside `area`. The limiting side
    /// takes the stage's whole points exactly (scaling by a ratio and back can land a hair short); the
    /// other is rounded down. At least 1×1.
    public static func presentedSize(of boardSize: CGSize, in area: CGSize) -> CGSize {
        let stage = CGSize(width: area.width.rounded(.down), height: area.height.rounded(.down))
        let size = stage.width / boardSize.width <= stage.height / boardSize.height
            ? CGSize(width: stage.width, height: (boardSize.height * stage.width / boardSize.width).rounded(.down))
            : CGSize(width: (boardSize.width * stage.height / boardSize.height).rounded(.down), height: stage.height)
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// `frameWidth / boardWidth`, as the largest single-precision value that still divides back to the
    /// whole board width: WebKit keeps the zoom as a float and truncates the CSS width it gets, so a
    /// zoom rounded up would lay the board out a pixel narrower.
    private static func zoom(showing boardWidth: CGFloat, in frameWidth: CGFloat) -> CGFloat {
        var zoom = Float(frameWidth / boardWidth)
        while Float(frameWidth) / zoom < Float(boardWidth) { zoom = zoom.nextDown }
        return CGFloat(zoom)
    }
}
