import Foundation

public enum CanvasCore {
    public static let version = "0.1.0"

    /// The CanvasCore framework bundle, which holds files from `Sources/CanvasCore/Resources` (e.g. `runtime.js`).
    public static var bundle: Bundle { Bundle(for: BundleToken.self) }
}

private final class BundleToken {}
