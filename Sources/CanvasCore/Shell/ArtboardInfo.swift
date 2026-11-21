import Foundation

/// What the right panel shows about the selected artboard.
public struct ArtboardInfo: Equatable, Sendable {
    public var name: String
    /// "1440 × 900".
    public var size: String
    public var page: String
    /// The board's own mode, or the document's marked "(document)".
    public var mode: String

    public init(name: String, size: String, page: String, mode: String) {
        self.name = name
        self.size = size
        self.page = page
        self.mode = mode
    }
}

extension CanvasDocument {
    public func info(ofArtboard id: String) -> ArtboardInfo? {
        guard let board = try? artboard(id: id) else { return nil }
        let page = manifest.pages.first { $0.id == board.page }
        return ArtboardInfo(
            name: board.name,
            size: "\(Self.dimension(board.width)) × \(Self.dimension(board.height))",
            page: page?.name ?? board.page,
            mode: board.mode ?? "\(manifest.mode) (document)"
        )
    }

    /// Whole numbers without a decimal point.
    private static func dimension(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
