import AppKit
import SnagbookCore
import SnagbookRender
import SwiftUI

/// Everything the windows bind to: the settings, the open session, the selected item and
/// the navigation history. Every change is written to disk as it happens; there is no Save.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let configStore: ConfigStore
    @Published private(set) var config: Config
    @Published private(set) var session: Session?
    @Published private(set) var items: [ItemRecord] = []
    @Published private(set) var selectedID: Int?
    @Published var titleDraft = ""
    @Published var focusTitle = false
    /// A short line shown at the bottom of the notebook ("Saved clip-001.mp4 to Item 3").
    @Published var status: String?
    /// The status line reports a success (drawn green), such as a finished Copy Hand-off.
    @Published var statusIsSuccess = false
    @Published var alert: AlertInfo?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showingSessions = false
    @Published var editingTemplate: Template?
    @Published var editingHeader = false

    let editor = EditorBridge()
    /// Where Copy Hand-off writes; the self-test swaps in a private one.
    var pasteboard = NSPasteboard.general
    lazy var capture = CaptureController(model: self)
    private var back: [Int] = []
    private var forward: [Int] = []
    private var editorItemIdentity: String?
    private var itemIdentities: [Int: String] = [:]
    private var statusTimer: Timer?

    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var action: (label: String, run: () -> Void)?
    }

    static var configURL: URL {
        if let p = ProcessInfo.processInfo.environment["SNAGBOOK_CONFIG"] { return URL(fileURLWithPath: Paths.expand(p)) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Snagbook/config.json")
    }

    private init() {
        configStore = ConfigStore(url: Self.configURL)
        config = configStore.config
        editor.model = self
        if let err = configStore.loadError {
            alert = AlertInfo(title: "Settings could not be read", message: "\(err)\n\nSnagbook is using its defaults and will not change that file until it can read it.")
        }
        if let last = config.lastSession, let s = try? Session.open(last, fallbackHeader: config.header) {
            use(s)
        }
    }

    // MARK: - settings

    func updateConfig(_ change: (inout Config) -> Void) {
        do {
            try configStore.update(change)
        } catch {
            show(error)
        }
        config = configStore.config
        if session?.fallbackHeader != config.header { session?.fallbackHeader = config.header }
    }

    // MARK: - sessions

    func newSession() {
        Task {
            guard await editor.flush() else { return }
            do {
                let s = try Session.create(root: config.sessionsFolder, config: config)
                use(s)
                try addItem(focusTitle: true)
                WindowPlacement.show()
                flash("New session: \(s.displayPath)")
            } catch {
                show(error)
            }
        }
    }

    func openSession(_ path: String) {
        Task {
            guard await editor.flush() else { return }
            do { use(try Session.open(path, fallbackHeader: config.header)) } catch { show(error) }
        }
    }

    func chooseSessionFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = Paths.url(config.sessionsFolder)
        p.prompt = "Open Session"
        if p.runModal() == .OK, let u = p.url { openSession(u.path) }
    }

    private func use(_ s: Session) {
        session = s
        itemIdentities.removeAll()
        for item in s.manifest.items {
            if let identity = try? s.itemIdentity(item.id) { itemIdentities[item.id] = identity }
        }
        editor.sessionChanged()
        items = s.manifest.items
        back.removeAll()
        forward.removeAll()
        updateNav()
        updateConfig { $0.lastSession = s.displayPath }
        selectedID = nil
        editorItemIdentity = nil
        if let first = items.last { show(first.id, record: false) } else { titleDraft = "" }
    }

    func refreshSessionFromDisk() {
        guard let s = session else { return }
        switch s.diskState {
        case .current: return
        case .unreadable:
            return flash("The session cannot be read right now; it was left open")
        case .gone:
            closeSession()
            alert = AlertInfo(title: "Session closed", message: "The session folder \(s.displayPath) was deleted outside Snagbook.")
        }
    }

    private func closeSession() {
        session = nil
        items = []
        selectedID = nil
        editorItemIdentity = nil
        itemIdentities.removeAll()
        titleDraft = ""
        back.removeAll()
        forward.removeAll()
        updateNav()
        editor.sessionClosed()
        updateConfig { $0.lastSession = nil }
    }

    func deleteSession(confirm: Bool = true) {
        guard let session else { return }
        if capture.phase != .idle {
            return flash("Finish or cancel the capture before deleting this session")
        }
        if Annotator.open.contains(where: { $0.session.isSameSession(as: session) }) {
            return flash("Finish or close the picture before deleting this session")
        }
        if confirm {
            let a = NSAlert()
            a.messageText = "Delete “\(session.title)”?"
            a.informativeText = "The whole session folder, with every item, note, picture and video, goes to the Trash."
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            guard await editor.flush() else { return flash("The note could not be saved, so the session was not deleted") }
            guard let live = self.session, live.isSameSession(as: session),
                  capture.phase == .idle,
                  !Annotator.open.contains(where: { $0.session.isSameSession(as: live) }) else {
                return flash("The session changed or a capture started, so it was not deleted")
            }
            do {
                try live.delete(discard: Session.trashOrDelete(
                    trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                    deletePermanently: { _ in
                        guard confirm else { return true }
                        let a = NSAlert()
                        a.messageText = "Delete “\(session.title)” permanently?"
                        a.informativeText = "This session is on a drive without a Trash, so its whole folder would be deleted for good."
                        a.addButton(withTitle: "Delete Permanently")
                        a.addButton(withTitle: "Cancel")
                        a.buttons.first?.hasDestructiveAction = true
                        return a.runModal() == .alertFirstButtonReturn
                            && self.session?.isSameSession(as: live) == true
                            && self.capture.phase == .idle
                            && !Annotator.open.contains(where: { $0.session.isSameSession(as: live) })
                            && live.matchesDiskIdentity
                    }))
                closeSession()
            } catch let e as CocoaError where e.code == .userCancelled {
            } catch {
                show(error)
            }
        }
    }

    /// Make sure there is somewhere to put a capture: a session and an item.
    func ensureItem() throws -> Int {
        if let session {
            switch session.diskState {
            case .current: break
            case .unreadable: throw SnagError.sessionUnreadable(session.displayPath)
            case .gone:
                let path = session.displayPath
                closeSession()
                throw SnagError.notASession(path)
            }
        }
        if session == nil {
            let s = try Session.create(root: config.sessionsFolder, config: config)
            use(s)
        }
        if let id = selectedID { return id }
        return try addItem(focusTitle: false)
    }

    // MARK: - items

    @discardableResult
    func addItem(title: String? = nil, focusTitle: Bool = true) throws -> Int {
        if session == nil {
            let s = try Session.create(root: config.sessionsFolder, config: config)
            use(s)
        }
        guard let session else { throw SnagError.noSuchItem(0) }
        let rec = try session.addItem(title: title)
        if let identity = try session.itemIdentity(rec.id) { itemIdentities[rec.id] = identity }
        items = session.manifest.items
        show(rec.id)
        if focusTitle { self.focusTitle = true }
        return rec.id
    }

    func newItemFromMenu() {
        Task {
            guard await editor.flush() else { return }
            do { try addItem() } catch { show(error) }
        }
    }

    func select(_ id: Int?) {
        guard let id, id != selectedID else { return }
        Task {
            guard await editor.flush() else { return }
            show(id)
        }
    }

    private func show(_ id: Int, record: Bool = true) {
        guard let session, let rec = items.first(where: { $0.id == id }) else { return }
        if record, let cur = selectedID, cur != id {
            back.append(cur)
            forward.removeAll()
        }
        selectedID = id
        editorItemIdentity = itemIdentities[id]
        titleDraft = rec.title
        let md = (try? session.readNote(id)) ?? ""
        editor.open(item: id, markdown: md, focus: !focusTitle)
        updateNav()
    }

    func goBack() {
        Task {
            guard await editor.flush() else { return }
            while let id = back.popLast() {
                guard items.contains(where: { $0.id == id }) else { continue }
                if let cur = selectedID { forward.append(cur) }
                show(id, record: false)
                break
            }
            updateNav()
        }
    }

    func goForward() {
        Task {
            guard await editor.flush() else { return }
            while let id = forward.popLast() {
                guard items.contains(where: { $0.id == id }) else { continue }
                if let cur = selectedID { back.append(cur) }
                show(id, record: false)
                break
            }
            updateNav()
        }
    }

    private func updateNav() {
        let ids = Set(items.map(\.id))
        canGoBack = back.contains(where: ids.contains)
        canGoForward = forward.contains(where: ids.contains)
    }

    func commitTitle() {
        guard let session, let id = selectedID, let itemIdentity = itemIdentities[id] else { return }
        guard !capture.isUsing(session, item: id) else {
            titleDraft = items.first(where: { $0.id == id })?.title ?? ""
            return flash("Finish the capture before renaming this item")
        }
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            titleDraft = items.first(where: { $0.id == id })?.title ?? ""
            return
        }
        do {
            let live = try session.reopenedMatchingItem(id, identity: itemIdentity, fallbackHeader: config.header)
            try live.renameItem(id, to: t, expectedIdentity: itemIdentity)
            self.session = live
            items = live.manifest.items
        } catch {
            show(error)
        }
    }

    func rename(_ id: Int, to title: String) {
        guard let session, let itemIdentity = itemIdentities[id] else { return }
        guard !capture.isUsing(session, item: id) else {
            return flash("Finish the capture before renaming this item")
        }
        do {
            let live = try session.reopenedMatchingItem(id, identity: itemIdentity, fallbackHeader: config.header)
            try live.renameItem(id, to: title, expectedIdentity: itemIdentity)
            self.session = live
            items = live.manifest.items
            if id == selectedID { titleDraft = title }
        } catch {
            show(error)
        }
    }

    func delete(_ id: Int, confirm: Bool = true) {
        guard let session, let rec = items.first(where: { $0.id == id }) else { return }
        guard let itemIdentity = itemIdentities[id] else { return flash("That item is no longer there") }
        guard !capture.isUsing(session, item: id),
              !Annotator.open.contains(where: { $0.item == id && $0.session.isSameSession(as: session) }) else {
            return flash("Finish the capture or picture before deleting this item")
        }
        if confirm {
            let a = NSAlert()
            a.messageText = "Delete “\(rec.title)”?"
            a.informativeText = "Its folder, with the note and all its pictures and videos, goes to the Trash."
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            guard await editor.flush() else { return flash("The note could not be saved, so the item was not deleted") }
            guard let live = self.session, live.isSameSession(as: session),
                  !capture.isUsing(live, item: id),
                  !Annotator.open.contains(where: { $0.item == id && $0.session.isSameSession(as: live) }) else {
                return flash("The item changed or a capture started, so it was not deleted")
            }
            do {
                let current = try live.reopenedMatchingItem(id, identity: itemIdentity, fallbackHeader: config.header)
                try current.deleteItem(id, expectedIdentity: itemIdentity, discard: Session.trashOrDelete(
                    trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                    deletePermanently: { _ in
                        guard confirm else { return true }
                        let a = NSAlert()
                        a.messageText = "Delete “\(rec.title)” permanently?"
                        a.informativeText = "This session is on a drive without a Trash, so the item’s folder, with the note and all its pictures and videos, would be deleted for good."
                        a.addButton(withTitle: "Delete Permanently")
                        a.addButton(withTitle: "Cancel")
                        a.buttons.first?.hasDestructiveAction = true
                        return a.runModal() == .alertFirstButtonReturn
                            && self.session?.isSameSession(as: live) == true
                            && (try? current.itemIdentity(id)) == itemIdentity
                            && !self.capture.isUsing(current, item: id)
                            && !Annotator.open.contains(where: { $0.item == id && $0.session.isSameSession(as: current) })
                    }))
                self.session = current
                editor.forget(item: id)
                itemIdentities[id] = nil
                items = current.manifest.items
                if selectedID == id {
                    selectedID = nil
                    if let prev = back.last(where: { b in items.contains { $0.id == b } }) ?? items.last?.id { show(prev, record: false) } else { titleDraft = "" }
                }
                updateNav()
            } catch let e as CocoaError where e.code == .userCancelled {
            } catch {
                show(error)
            }
        }
    }

    func move(from offsets: IndexSet, to dest: Int) {
        guard let session, let from = offsets.first else { return }
        let id = items[from].id
        guard let itemIdentity = itemIdentities[id] else { return flash("That item is no longer there") }
        do {
            let live = try session.reopenedMatchingItem(id, identity: itemIdentity, fallbackHeader: config.header)
            try live.moveItem(id, to: dest > from ? dest - 1 : dest)
            self.session = live
            items = live.manifest.items
        } catch {
            show(error)
        }
    }

    // MARK: - notes (called by the editor)

    @discardableResult
    func noteChanged(id: Int, markdown: String) -> Bool {
        guard let session, editor.shownItem == id, let editorItemIdentity else { return false }
        do {
            let live = try session.reopenedMatchingItem(id, identity: editorItemIdentity, fallbackHeader: config.header)
            try live.writeNote(id, body: markdown)
            self.session = live
            items = live.manifest.items
            return true
        } catch {
            if let live = try? session.reopenedMatchingItem(id, identity: editorItemIdentity, fallbackHeader: config.header),
               (try? live.readNote(id)) == markdown {
                self.session = live
                items = live.manifest.items
                return true
            }
            show(error)
            return false
        }
    }

    func editorReady() {
        if let id = selectedID, let session {
            editor.open(item: id, markdown: (try? session.readNote(id)) ?? "", focus: false)
        }
    }

    func reopenCurrentAfterCrash() {
        // editorReady() puts the current item back once the page has reloaded.
    }

    /// An item's file for the editor's media URLs; nil if it escapes the item folder.
    func fileURL(item id: Int, relative: String) -> URL? {
        guard let session, let dir = try? session.itemURL(id) else { return nil }
        let u = dir.appendingPathComponent(relative).standardizedFileURL
        guard u.path.hasPrefix(dir.standardizedFileURL.path + "/") else { return nil }
        return u
    }

    // MARK: - media

    private func liveEditorDestination() throws -> (session: Session, item: Int) {
        let id = try ensureItem()
        guard let session, editor.shownItem == id, let editorItemIdentity else { throw SnagError.noSuchItem(id) }
        let live = try session.reopenedMatchingItem(id, identity: editorItemIdentity, fallbackHeader: config.header)
        self.session = live
        items = live.manifest.items
        return (live, id)
    }

    /// Bytes pasted or dropped into the editor. Returns the note-relative path.
    func savePasted(data: Data, mime: String, name: String) -> String? {
        do {
            let (session, id) = try liveEditorDestination()
            if mime.hasPrefix("video/") {
                let ext = (name as NSString).pathExtension.isEmpty ? "mp4" : (name as NSString).pathExtension
                return try session.saveMedia(id, data: data, prefix: "clip", ext: ext)
            }
            // Store every pasted picture as PNG so notes do not collect exotic formats.
            let png = mime == "image/png" ? data : (ImageFile.load(data).flatMap(ImageFile.pngData) ?? data)
            return try session.saveMedia(id, data: png, prefix: "image", ext: "png")
        } catch {
            show(error)
            return nil
        }
    }

    func insertImageData(_ png: Data) {
        guard let rel = savePasted(data: png, mime: "image/png", name: "") else { return }
        editor.insertMedia(kind: "image", src: rel, label: "")
    }

    func importFile(_ url: URL) {
        do {
            switch MediaKind.of(url) {
            case .image:
                let data = try Data(contentsOf: url)
                insertImageData(url.pathExtension.lowercased() == "png" ? data : (ImageFile.load(data).flatMap(ImageFile.pngData) ?? data))
            case .video:
                let (session, id) = try liveEditorDestination()
                let target = try session.reserveMediaName(id, prefix: "clip", ext: url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
                try session.fill(target, from: url)
                editor.insertMedia(kind: "video", src: target.relative, label: url.lastPathComponent)
            case nil:
                break
            }
        } catch {
            show(error)
        }
    }

    /// A finished screenshot: into the selected item, marked up first if that is on.
    @discardableResult
    func screenshotTaken(_ image: CGImage, source: String, session sourceSession: Session? = nil, item sourceItem: Int? = nil) throws -> Bool {
        let id = try sourceItem ?? ensureItem()
        guard let session = sourceSession ?? session else { throw SnagError.noSuchItem(id) }
        guard let png = ImageFile.pngData(image) else { throw VideoErrorLike("encode") }
        let rel = try session.saveMedia(id, data: png, prefix: "shot", ext: "png")
        let isOpen = adoptIfOpen(session)
        if config.capture.annotateScreenshots, isOpen, selectedID == id {
            Annotator.open(item: id, relative: rel, isNew: true, model: self)
            return true
        } else if isOpen, selectedID == id {
            editor.insertMedia(kind: "image", src: rel, label: "")
            flash("Screenshot saved to \(itemTitle(id))")
        } else {
            try appendMedia("![](\(rel))", to: session, item: id)
        }
        return false
    }

    /// The mark-up window finished with a picture.
    func annotationFinished(session sourceSession: Session, item id: Int, itemIdentity: String, pictureBinding: Session.FileBinding, relative: String, isNew: Bool, kept: Bool) async throws {
        let isOpen = session?.isSameSession(as: sourceSession) == true
        if isNew {
            if kept {
                if isOpen, selectedID == id {
                    guard await editor.flush() else {
                        throw VideoErrorLike("the note link could not be saved")
                    }
                }
                let live = try sourceSession.reopenedMatchingItem(id, identity: itemIdentity, fallbackHeader: config.header)
                let rebound = try Session.rebind(pictureBinding, to: live.itemURL(id).appendingPathComponent(relative))
                _ = try Session.read(rebound)
                try appendMedia("![](\(relative))", to: live, item: id)
                if adoptIfOpen(live), selectedID == id {
                    editor.insertMedia(kind: "image", src: relative, label: "")
                    flash("Screenshot saved to \(itemTitle(id))")
                }
            }
        } else if isOpen {
            editor.refreshMedia(relative)
        }
    }

    func annotateExisting(src: String) {
        guard let id = editor.shownItem, !src.contains("://") else { return }
        Annotator.open(item: id, relative: src, isNew: false, model: self)
    }

    /// A finished recording, already in the item's media folder.
    func recordingSaved(session sourceSession: Session, item id: Int, relative: String, duration: Double) throws {
        let label = "Video \(CaptureMath.duration(duration))"
        if adoptIfOpen(sourceSession), selectedID == id {
            editor.insertMedia(kind: "video", src: relative, label: label)
            flash("Recording (\(CaptureMath.duration(duration))) saved to \(itemTitle(id))")
        } else {
            try appendMedia("[\(label)](\(relative))", to: sourceSession, item: id)
        }
    }

    private func appendMedia(_ markdown: String, to session: Session, item id: Int) throws {
        let old = try session.readNote(id).trimmingCharacters(in: .whitespacesAndNewlines)
        if old.split(separator: "\n").contains(Substring(markdown)) { return }
        do {
            try session.writeNote(id, body: old.isEmpty ? markdown + "\n" : old + "\n\n" + markdown + "\n")
        } catch {
            let written = try? session.readNote(id)
            if written?.split(separator: "\n").contains(Substring(markdown)) == true { return }
            throw error
        }
    }

    private func adoptIfOpen(_ refreshed: Session) -> Bool {
        guard session?.isSameSession(as: refreshed) == true else { return false }
        session = refreshed
        items = refreshed.manifest.items
        return true
    }

    func itemTitle(_ id: Int) -> String { items.first { $0.id == id }?.title ?? "Item \(id)" }

    func openedItemIdentity(_ id: Int) -> String? { itemIdentities[id] }

    func openLink(_ href: String) {
        if let u = URL(string: href), u.scheme != nil, u.scheme != MediaSchemeHandler.scheme {
            NSWorkspace.shared.open(u)
        } else if let id = editor.shownItem, let file = fileURL(item: id, relative: href.removingPercentEncoding ?? href) {
            NSWorkspace.shared.open(file)
        }
    }

    // MARK: - templates

    func insertTemplate(_ t: Template) {
        if selectedID == nil { _ = try? ensureItem() }
        editor.insertMarkdown(t.body)
        editor.focus()
    }

    func saveTemplate(_ t: Template) {
        updateConfig { c in
            if let i = c.templates.firstIndex(where: { $0.id == t.id }) { c.templates[i] = t } else { c.templates.append(t) }
        }
    }

    func deleteTemplate(_ t: Template) {
        updateConfig { $0.templates.removeAll { $0.id == t.id } }
    }

    func moveTemplate(_ t: Template, by delta: Int) {
        updateConfig { c in
            guard let i = c.templates.firstIndex(where: { $0.id == t.id }) else { return }
            let j = max(0, min(c.templates.count - 1, i + delta))
            c.templates.swapAt(i, j)
        }
    }

    // MARK: - hand-off

    func copyHandoff() {
        Task {
            guard await editor.flush() else { return }
            guard let session else { return flash("No session open") }
            try? session.writeReadme()
            let text = session.handoff(style: config.handoff)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            flash("Copied: \(session.displayPath)/README.md", success: true)
        }
    }

    func revealSession() {
        guard let session else { return }
        NSWorkspace.shared.activateFileViewerSelecting([session.url.appendingPathComponent(Session.readmeName)])
    }

    func renameSession(_ name: String) {
        guard let session else { return }
        do { try session.setTitle(name) } catch { show(error) }
        objectWillChange.send()
    }

    func setSessionHeader(_ text: String?) {
        guard let session else { return }
        do { try session.setHeader(text) } catch { show(error) }
        objectWillChange.send()
    }

    // MARK: - feedback

    func flash(_ text: String, success: Bool = false) {
        status = text
        statusIsSuccess = success
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.status = nil }
        }
    }

    func show(_ error: Error) {
        alert = AlertInfo(title: "Something went wrong", message: error.localizedDescription)
    }
}
