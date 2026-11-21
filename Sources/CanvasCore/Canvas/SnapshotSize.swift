import Foundation
import WebKit

/// How large a board's PNG snapshot is and how wide WebKit is asked to draw it. WebKit draws
/// `snapshotWidth` points across at the screen's scale; above roughly 400M device pixels it returns
/// a blank image or fails. So the PNG is capped at `maxPixels` (huge boards come out at reduced
/// resolution, never blank), and WebKit's drawing at `maxDevicePixels`. Boards under the cap keep
/// 1 pixel per CSS pixel, drawn at the screen's scale and scaled down.
public struct SnapshotSize: Sendable {
    public static let maxPixels: CGFloat = 32 * 1024 * 1024
    /// A third of where WebKit fails; a capped board on a 2× screen fits exactly.
    public static let maxDevicePixels: CGFloat = 4 * maxPixels

    /// The PNG's size in pixels: the board's native size, shrunk to fit `maxPixels`.
    public let pixelSize: CGSize
    /// The width, in points, WebKit draws the snapshot at (`WKSnapshotConfiguration.snapshotWidth`).
    public let snapshotWidth: CGFloat

    public init(nativeSize: CGSize, backingScale: CGFloat) {
        pixelSize = Self.capped(nativeSize, toArea: Self.maxPixels)
        snapshotWidth = pixelSize.width * Self.shrinkFactor(area: Self.area(pixelSize) * backingScale * backingScale, toFit: Self.maxDevicePixels)
    }

    /// `size` scaled down, rounding each side down (to at least 1), so its area is at most `limit`.
    private static func capped(_ size: CGSize, toArea limit: CGFloat) -> CGSize {
        let factor = shrinkFactor(area: area(size), toFit: limit)
        guard factor < 1 else { return size }
        return CGSize(width: max((size.width * factor).rounded(.down), 1), height: max((size.height * factor).rounded(.down), 1))
    }

    /// The linear scale (at most 1) that brings `area` down to `limit`.
    private static func shrinkFactor(area: CGFloat, toFit limit: CGFloat) -> CGFloat {
        area > limit ? (limit / area).squareRoot() : 1
    }

    private static func area(_ size: CGSize) -> CGFloat { size.width * size.height }
}

extension SnapshotSize {
    /// A snapshot of `rect` (the web view's bounds) drawn at `snapshotWidth`, after pending paints.
    @MainActor
    public func configuration(of rect: CGRect) -> WKSnapshotConfiguration {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(snapshotWidth))
        configuration.afterScreenUpdates = true
        return configuration
    }
}
