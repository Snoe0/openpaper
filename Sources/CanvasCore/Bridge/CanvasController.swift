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
    /// The first element `selector` matches on the artboard's page, or nil when none does; throws
    /// `PageElementError.invalidSelector` for a malformed selector.
    func element(onArtboard artboardID: String, matching selector: String) async throws -> PageElement?
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

/// An element on an artboard's page, as the page's runtime describes it (`Canvas.elementAt`, `Canvas.describe`).
public struct PageElement: Codable, Equatable, Sendable {
    /// A unique path to the element, as inspect mode builds it.
    public var selector: String
    public var outerHTML: String
    /// In CSS pixels, relative to the page's viewport (the board's top-left corner while the page isn't scrolled).
    public var box: ElementRect
    /// Key computed styles by CSS property, e.g. `"font-size": "16px"`.
    public var styles: [String: String]
    /// How many elements the selector matched (`Canvas.describe` only); this one is the first.
    public var matches: Int?
    /// True when `outerHTML` was cut short (`Canvas.describe` keeps at most 20000 characters).
    public var truncated: Bool?

    public init(selector: String, outerHTML: String, box: ElementRect, styles: [String: String], matches: Int? = nil, truncated: Bool? = nil) {
        self.selector = selector
        self.outerHTML = outerHTML
        self.box = box
        self.styles = styles
        self.matches = matches
        self.truncated = truncated
    }

    /// What the runtime returned (a dictionary from WebKit): the element, or nil (JS null) for none. Throws
    /// `.invalidSelector` for the runtime's malformed-selector answer, and `.unreadable` for anything else.
    public static func decode(runtimeValue: Any?) throws(PageElementError) -> PageElement? {
        guard let value = runtimeValue, !(value is NSNull) else { return nil }
        if (value as? [String: Any])?["invalidSelector"] as? Bool == true { throw .invalidSelector }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let element = try? JSONDecoder().decode(PageElement.self, from: data) else { throw .unreadable }
        return element
    }
}

public enum PageElementError: Error, Equatable {
    case invalidSelector
    case unreadable
}

extension PageElementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSelector: "The selector isn't a valid CSS selector."
        case .unreadable: "The page's answer couldn't be read."
        }
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
