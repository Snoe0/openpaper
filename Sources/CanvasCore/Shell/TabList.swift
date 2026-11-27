/// The open document tabs in order, and which one is showing; nil shows the Dashboard.
public struct TabList<ID: Hashable>: Equatable {
    public private(set) var ids: [ID] = []
    public private(set) var selected: ID?

    public init() {}

    /// Adds a tab at the end unless it's already open, and shows it.
    public mutating func open(_ id: ID) {
        if !ids.contains(id) { ids.append(id) }
        selected = id
    }

    /// Shows a tab, or the Dashboard for nil; ids that aren't open are ignored.
    public mutating func select(_ id: ID?) {
        guard id.map(ids.contains) ?? true else { return }
        selected = id
    }

    /// Closing the showing tab shows its right neighbour, else its left one, else the Dashboard.
    public mutating func close(_ id: ID) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        guard selected == id else { return }
        selected = ids.indices.contains(index) ? ids[index] : ids.last
    }
}
