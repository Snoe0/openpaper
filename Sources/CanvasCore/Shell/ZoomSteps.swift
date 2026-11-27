import CoreGraphics
import Foundation

/// The zoom levels the Zoom In / Zoom Out commands step through, and how a zoom is labelled.
public enum ZoomSteps {
    public static let presets: [CGFloat] = [0.02, 0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8]
    /// A scale this close to a preset counts as being on it, so each command moves a full step.
    private static let tolerance: CGFloat = 1.001

    public static func zoomedIn(from scale: CGFloat) -> CGFloat {
        presets.first { $0 > scale * tolerance } ?? presets[presets.count - 1]
    }

    public static func zoomedOut(from scale: CGFloat) -> CGFloat {
        presets.last { $0 < scale / tolerance } ?? presets[0]
    }

    /// "100%", "33%"; below 1% one decimal, "0.4%".
    public static func percent(_ scale: CGFloat) -> String {
        let percent = Double(scale) * 100
        return percent < 1 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }
}
