import Foundation

extension CanvasDocument {
    public func componentHTML(name: String) throws -> String {
        try validateComponentName(name)
        guard let html = componentSources[name] else { throw DocumentError.notFound(name) }
        return html
    }

    /// Writes `components/<name>.html`, which defines `<x-name>`.
    public func writeComponent(name: String, html: String) throws {
        try validateComponentName(name)
        try files.write(html, to: DocumentPath.component(name))
        componentSources[name] = html
        notify(.component(name: name))
    }

    public func deleteComponent(name: String) throws {
        try validateComponentName(name)
        guard componentSources[name] != nil else { throw DocumentError.notFound(name) }
        try files.remove(DocumentPath.component(name))
        componentSources[name] = nil
        notify(.component(name: name))
    }

    /// Every component template, keyed by name.
    public func allComponents() -> [String: String] {
        componentSources
    }

    public func props(ofComponent name: String) throws -> [ComponentProp] {
        ComponentTemplate.props(in: try componentHTML(name: name))
    }

    func loadComponents() {
        var sources: [String: String] = [:]
        for name in files.fileNames(in: DocumentPath.components).compactMap(ComponentTemplate.name(ofFile:)) {
            sources[name] = (try? files.load(DocumentPath.component(name))).map { String(decoding: $0, as: UTF8.self) }
        }
        componentSources = sources
    }

    private func validateComponentName(_ name: String) throws {
        guard ComponentTemplate.isValidName(name) else { throw DocumentError.invalidName(name) }
    }
}
