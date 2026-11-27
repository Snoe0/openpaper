import Foundation

extension CanvasDocument {
    /// The board Present shows: the first selected board on the current page, else the page's first board.
    public func presentationTarget(selectedIDs: [String]) -> Artboard? {
        let boards = artboards()
        return selectedIDs.lazy.compactMap { id in boards.first { $0.id == id } }.first ?? boards.first
    }
}
