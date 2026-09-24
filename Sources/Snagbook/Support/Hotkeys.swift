import KeyboardShortcuts

// Global shortcuts: they work while another app (a game) has focus. All of them can be
// changed in Settings; these are the defaults.
extension KeyboardShortcuts.Name {
    /// Select a region; press again to start recording it; again to stop.
    static let record = Self("record", default: .init(.r, modifiers: [.control, .command]))
    /// Screenshot the selected region (or select one and shoot at once).
    static let screenshot = Self("screenshot", default: .init(.s, modifiers: [.control, .command]))
    /// Start a new item and put the cursor in its title.
    static let newItem = Self("newItem", default: .init(.n, modifiers: [.control, .command]))
    /// Bring the notebook to the front (or hide it when it is in front).
    static let showNotebook = Self("showNotebook", default: .init(.b, modifiers: [.control, .command]))
}
