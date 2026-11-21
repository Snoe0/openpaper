import Foundation

/// What the MCP bridge needs from the app. The app implements it; every tool call runs on the main actor.
///
/// `BridgeServer` holds its controller strongly, so the controller should be an app-lifetime object.
/// Tool calls can interleave while `screenshot` awaits: other calls may change or delete the artboard,
/// or switch the active document, before it returns, and implementations must tolerate that
/// (e.g. by throwing when the artboard is gone).
@MainActor
public protocol CanvasController {
    /// The document the agent works on, or nil when none is open.
    var activeDocument: CanvasDocument? { get }
    /// Opens the document at `url` and makes it active.
    func openDocument(at url: URL) throws -> CanvasDocument
    /// Creates a new document at `url` (a `Name.canvas` folder) and makes it active.
    func createDocument(at url: URL) throws -> CanvasDocument
    /// Recently opened documents, offered to the agent when none is open.
    var recentDocuments: [URL] { get }
    var selection: CanvasSelection { get }
    /// A PNG of the artboard as currently rendered.
    func screenshot(artboardID: String) async throws -> Data
    /// Console messages captured from one artboard, or from all of them, oldest first.
    func consoleLogs(artboardID: String?) -> [ConsoleEntry]
    /// Scrolls and zooms the canvas to the artboard.
    func focus(artboardID: String)
}

public struct CanvasSelection: Codable, Equatable, Sendable {
    public var artboardIDs: [String]
    /// The element picked in inspect mode, if any.
    public var element: SelectedElement?

    public init(artboardIDs: [String] = [], element: SelectedElement? = nil) {
        self.artboardIDs = artboardIDs
        self.element = element
    }
}

public struct SelectedElement: Codable, Equatable, Sendable {
    public var artboardID: String
    public var selector: String
    public var outerHTML: String
    /// In the artboard's CSS pixels.
    public var rect: ElementRect

    public init(artboardID: String, selector: String, outerHTML: String, rect: ElementRect) {
        self.artboardID = artboardID
        self.selector = selector
        self.outerHTML = outerHTML
        self.rect = rect
    }
}

public struct ElementRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ConsoleEntry: Codable, Equatable, Sendable {
    public var artboardID: String
    /// "log", "info", "warn", "error" or "debug".
    public var level: String
    public var message: String
    public var timestamp: Date

    public init(artboardID: String, level: String, message: String, timestamp: Date) {
        self.artboardID = artboardID
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}
