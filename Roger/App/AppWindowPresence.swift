import AppKit

/// Keeps track of Roger's open app windows (library and settings). While at
/// least one is open, Roger is a regular app with a Dock icon and a place in
/// Cmd-Tab. After the last one closes, it is a menu bar app again.
@MainActor
final class AppWindowPresence {
    enum Window: Hashable, CaseIterable {
        case library
        case settings
    }

    static let shared = AppWindowPresence { policy in
        _ = NSApp.setActivationPolicy(policy)
    }

    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private(set) var openWindows: Set<Window> = []

    init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void) {
        self.setPolicy = setPolicy
    }

    /// True while at least one app window is open.
    var isRegular: Bool { !openWindows.isEmpty }

    /// Call before the window is shown, so the Dock icon does not flash.
    /// A second call for a window that is already open changes nothing.
    func enter(_ window: Window) {
        let wasEmpty = openWindows.isEmpty
        guard openWindows.insert(window).inserted else { return }
        if wasEmpty { setPolicy(.regular) }
    }

    /// Call from `windowWillClose` of that window.
    func leave(_ window: Window) {
        guard openWindows.remove(window) != nil else { return }
        if openWindows.isEmpty { setPolicy(.accessory) }
    }
}
