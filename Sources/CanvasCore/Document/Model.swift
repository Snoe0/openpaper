import Foundation

public struct Page: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Artboard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var page: String
    public var name: String
    /// Path of the body fragment, relative to the document folder (`artboards/<id>.html`).
    public var file: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Token mode override; nil uses the document mode.
    public var mode: String?

    public init(id: String, page: String, name: String, file: String, x: Double, y: Double, width: Double, height: Double, mode: String? = nil) {
        self.id = id
        self.page = page
        self.name = name
        self.file = file
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mode = mode
    }

    /// Writes `"mode": null` explicitly so the manifest shape stays stable.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(page, forKey: .page)
        try container.encode(name, forKey: .name)
        try container.encode(file, forKey: .file)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(mode, forKey: .mode)
    }
}

/// The contents of `canvas.json`.
public struct Manifest: Codable, Equatable, Sendable {
    public var version: Int
    public var currentPage: String
    public var mode: String
    public var pages: [Page]
    public var artboards: [Artboard]

    public init(version: Int = 1, currentPage: String, mode: String, pages: [Page], artboards: [Artboard]) {
        self.version = version
        self.currentPage = currentPage
        self.mode = mode
        self.pages = pages
        self.artboards = artboards
    }
}

/// The contents of `tokens.json`.
public struct Tokens: Codable, Equatable, Sendable {
    public var modes: [String]
    public var tokens: [String: TokenValue]

    public init(modes: [String], tokens: [String: TokenValue]) {
        self.modes = modes
        self.tokens = tokens
    }
}

/// A token is either one value for every mode, or a value per mode.
public enum TokenValue: Codable, Equatable, Sendable {
    case single(String)
    case perMode([String: String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
        } else {
            self = .perMode(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .perMode(let values): try container.encode(values)
        }
    }
}

public struct ComponentProp: Equatable, Sendable {
    public var name: String
    public var defaultValue: String?

    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public enum DocumentChange: Equatable, Sendable {
    case manifest
    case tokens
    case artboard(id: String)
    case component(name: String)
    case asset(path: String)
}

public enum DocumentError: Error, Equatable {
    case notFound(String)
    case invalidName(String)
    case editMatchNotFound
    case editMatchNotUnique(count: Int)
    case lastPage
    case malformed(String)
    case alreadyExists(String)
    case invalidValue(String)
}

extension DocumentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let item):
            "Not found: \(item)."
        case .invalidName(let name):
            "Invalid name \"\(name)\". Component names use lowercase letters, digits and dashes and start with a letter, and file paths must stay inside the document."
        case .editMatchNotFound:
            "The text to replace wasn't found in the artboard. Read the artboard again and copy the exact text."
        case .editMatchNotUnique(let count):
            "The text to replace appears \(count) times. Include more surrounding text so it matches exactly once."
        case .lastPage:
            "A document needs at least one page, so its last page can't be deleted."
        case .malformed(let detail):
            "The document is malformed: \(detail)"
        case .alreadyExists(let path):
            "Something already exists at \(path)."
        case .invalidValue(let detail):
            "Invalid value: \(detail)"
        }
    }
}
