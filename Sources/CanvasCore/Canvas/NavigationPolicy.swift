import Foundation

/// Where an artboard's web view may go. The main frame stays on the board's own page (loads, reloads
/// and `#fragment` jumps); a clicked web link opens in the browser instead, and anything else (a script
/// setting `location`, another page or scheme) is cancelled. Subframes and subresources load as usual.
public enum NavigationPolicy: Equatable, Sendable {
    case allow
    case cancel
    case openExternally

    public static func decide(url: URL?, targetIsMainFrame: Bool?, boardURL: URL, isUserClick: Bool) -> NavigationPolicy {
        // No target frame means a new window (target=_blank, window.open): top-level, so the policy applies.
        guard targetIsMainFrame ?? true else { return .allow }
        guard let url else { return .cancel }
        if withoutFragment(url) == withoutFragment(boardURL) { return .allow }
        return isUserClick && isWebLink(url) ? .openExternally : .cancel
    }

    /// Whether a link activation is really the user's click: the web view takes the pointer (boards on
    /// the canvas outside inspect mode and snapshot renders never do) and a mouse button did it, since
    /// WebKit reports button 0 for a script's `a.click()`, which is a link activation too. Keyboard
    /// activation (Tab then Enter in a presentation) also reports button 0 and is cancelled on purpose:
    /// no public macOS API tells it apart from a script's `a.click()`.
    public static func isUserClick(isLinkActivation: Bool, mouseButton: Int, viewAcceptsMouse: Bool) -> Bool {
        isLinkActivation && viewAcceptsMouse && mouseButton != 0
    }

    private static func withoutFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url
    }

    private static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }
}
