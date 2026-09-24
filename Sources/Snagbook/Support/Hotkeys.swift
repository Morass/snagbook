import KeyboardShortcuts

// Global shortcuts: they work while another app (a game) has focus. All of them can be
// changed in Settings; these are the defaults.
extension KeyboardShortcuts.Name {
    /// Drag a rectangle and recording starts; press again to stop.
    static let record = Self("record", default: .init(.r, modifiers: [.control, .command]))
    /// Drag a rectangle and it is photographed (while recording: the recorded area).
    static let screenshot = Self("screenshot", default: .init(.s, modifiers: [.control, .command]))
    /// Start a new item and put the cursor in its title.
    static let newItem = Self("newItem", default: .init(.n, modifiers: [.control, .command]))
    /// Bring the notebook to the front (or hide it when it is in front).
    static let showNotebook = Self("showNotebook", default: .init(.b, modifiers: [.control, .command]))
}
