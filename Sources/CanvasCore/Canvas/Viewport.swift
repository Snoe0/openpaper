import CoreGraphics

/// Maps the infinite canvas onto the screen: `origin` is the canvas point at the screen's top-left
/// corner and `scale` is screen points per canvas point. Screen coordinates grow right and down.
public struct Viewport: Equatable, Sendable {
    public static let minScale: CGFloat = 0.02
    public static let maxScale: CGFloat = 8

    public var origin: CGPoint
    public var scale: CGFloat

    public init(origin: CGPoint = .zero, scale: CGFloat = 1) {
        self.origin = origin
        self.scale = scale
    }

    public static func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    // MARK: - Conversion

    public func screenPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale)
    }

    public func canvasPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale + origin.x, y: point.y / scale + origin.y)
    }

    public func screenRect(fromCanvas rect: CGRect) -> CGRect {
        CGRect(origin: screenPoint(fromCanvas: rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    public func canvasRect(fromScreen rect: CGRect) -> CGRect {
        CGRect(origin: canvasPoint(fromScreen: rect.origin), size: CGSize(width: rect.width / scale, height: rect.height / scale))
    }

    public func visibleCanvasRect(screenSize: CGSize) -> CGRect {
        canvasRect(fromScreen: CGRect(origin: .zero, size: screenSize))
    }

    // MARK: - Moves

    /// Zooms by `factor`, keeping the canvas point under `screenPoint` where it is.
    public func zoomed(by factor: CGFloat, around screenPoint: CGPoint) -> Viewport {
        zoomed(to: scale * factor, around: screenPoint)
    }

    /// Zooms to `newScale` (clamped), keeping the canvas point under `screenPoint` where it is.
    public func zoomed(to newScale: CGFloat, around screenPoint: CGPoint) -> Viewport {
        let anchor = canvasPoint(fromScreen: screenPoint)
        let scale = Self.clamped(newScale)
        return Viewport(origin: CGPoint(x: anchor.x - screenPoint.x / scale, y: anchor.y - screenPoint.y / scale), scale: scale)
    }

    /// Moves the content by `delta` screen points.
    public func panned(by delta: CGSize) -> Viewport {
        Viewport(origin: CGPoint(x: origin.x - delta.width / scale, y: origin.y - delta.height / scale), scale: scale)
    }

    /// Shows all of `rect`, centred, with at least `padding` screen points around it (scale clamped).
    public static func fitting(_ rect: CGRect, screenSize: CGSize, padding: CGFloat) -> Viewport {
        let room = CGSize(width: max(screenSize.width - 2 * padding, 0), height: max(screenSize.height - 2 * padding, 0))
        let scale = min(room.width / max(rect.width, 1e-9), room.height / max(rect.height, 1e-9))
        return centred(on: CGPoint(x: rect.midX, y: rect.midY), scale: scale, screenSize: screenSize)
    }

    /// Shows `point` at the centre of the screen at `scale` (clamped).
    public static func centred(on point: CGPoint, scale: CGFloat, screenSize: CGSize) -> Viewport {
        let scale = clamped(scale)
        return Viewport(origin: CGPoint(x: point.x - screenSize.width / 2 / scale, y: point.y - screenSize.height / 2 / scale), scale: scale)
    }

    /// The smallest rect enclosing all of `rects`; nil when there are none.
    public static func boundingRect(of rects: [CGRect]) -> CGRect? {
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? nil : union
    }

    // MARK: - Animation

    /// The bounds that make a layer of `frameSize`, whose content is laid out for `laidOut`, show it
    /// as this viewport would: a cheap stand-in for laying everything out again mid-gesture.
    public func layerBounds(laidOutFor laidOut: Viewport, frameSize: CGSize) -> CGRect {
        let zoom = scale / laidOut.scale
        let offset = CGPoint(x: (laidOut.origin.x - origin.x) * scale, y: (laidOut.origin.y - origin.y) * scale)
        return CGRect(x: -offset.x / zoom, y: -offset.y / zoom, width: frameSize.width / zoom, height: frameSize.height / zoom)
    }

    /// The viewport `progress` (0…1) of the way from `from` to `to`: the scale changes geometrically
    /// and the visible centre moves in a straight line.
    public static func interpolated(from: Viewport, to: Viewport, progress: CGFloat, screenSize: CGSize) -> Viewport {
        guard progress > 0 else { return from }
        guard progress < 1 else { return to }
        let middle = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        let a = from.canvasPoint(fromScreen: middle), b = to.canvasPoint(fromScreen: middle)
        let centre = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
        return centred(on: centre, scale: from.scale * pow(to.scale / from.scale, progress), screenSize: screenSize)
    }
}
