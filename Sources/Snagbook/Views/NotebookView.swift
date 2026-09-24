import AppKit
import SnagbookCore
import SwiftUI

struct NotebookView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var capture: CaptureController

    var body: some View {
        Group {
            if model.session == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    ItemList()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
                } detail: {
                    ItemDetail()
                }
            }
        }
        .toolbar { NotebookToolbar() }
        .background(WindowAccessor { win in WindowPlacement.configure(win, model: model) })
        .sheet(isPresented: $model.showingSessions) { SessionPicker() }
        .sheet(item: $model.editingTemplate) { t in TemplateEditor(template: t) }
        .sheet(isPresented: $model.editingHeader) { HeaderEditor() }
        .alert(item: $model.alert) { a in
            if let action = a.action {
                return Alert(title: Text(a.title), message: Text(a.message), primaryButton: .default(Text(action.label), action: action.run), secondaryButton: .cancel())
            }
            return Alert(title: Text(a.title), message: Text(a.message))
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - toolbar

struct NotebookToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var capture: CaptureController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back (⌘[)").disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .help("Forward (⌘])").disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.newItemFromMenu() } label: { Label("New Item", systemImage: "plus.square") }
                .help("New item (⌘N, anywhere: ⌃⌘N)")
            Divider()
            Button { capture.recordAction() } label: {
                Label(capture.recordButtonTitle, systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(capture.isRecording ? .red : .primary)
            }
            .help("Drag a rectangle anywhere; recording starts when you let go. Again to stop (anywhere: ⌃⌘R)")
            Button { capture.screenshotAction() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                .help("Drag a rectangle to screenshot it (anywhere: ⌃⌘S)")
            Divider()
            Button { model.copyHandoff() } label: { Label("Copy Hand-off", systemImage: "arrowshape.turn.up.right") }
                .help("Copy the hand-off text for this session (⇧⌘C)")
                .disabled(model.session == nil)
        }
    }
}

// MARK: - sidebar

struct ItemList: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Int?
    @State private var renameText = ""

    var body: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            Section {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    ItemRow(index: index + 1, item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Rename…") { renameText = item.title; renaming = item.id }
                            Button("Show in Finder") {
                                if let u = try? model.session?.itemURL(item.id) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { model.delete(item.id) }
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SessionMenu()
                Divider()
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.newItemFromMenu() } label: {
                Label("New Item", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onDeleteCommand { if let id = model.selectedID { model.delete(id) } }
        .alert("Rename item", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let id = renaming { model.rename(id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

/// The top of the sidebar: which session this is, and every way to change that.
struct SessionMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        if let s = model.session {
            Menu {
                let recent = Session.list(root: model.config.sessionsFolder).prefix(12)
                Section("Recent sessions") {
                    ForEach(Array(recent), id: \.path) { r in
                        Button {
                            model.openSession(r.path)
                        } label: {
                            if r.path == s.displayPath { Label(r.title, systemImage: "checkmark") } else { Text(r.title) }
                            Text("\(r.items) item\(r.items == 1 ? "" : "s") · \(r.created.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
                Divider()
                Button("New Session") { model.newSession() }
                Button("Rename This Session…") { name = s.manifest.title ?? ""; renaming = true }
                Button("Edit Header…") { model.editingHeader = true }
                Button("All Sessions…") { model.showingSessions = true }
                Button("Open Another Folder…") { model.chooseSessionFolder() }
                Button("Show in Finder") { model.revealSession() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text("\(model.items.count) item\(model.items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Switch session, start a new one, or rename this one")
            .padding(.horizontal, 10).padding(.vertical, 8)
            .alert("Name this session", isPresented: $renaming) {
                TextField(Session.defaultTitle(s.manifest.created), text: $name)
                Button("Rename") { model.renameSession(name) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("For you only; the folder keeps its name.")
            }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let item: ItemRecord

    var body: some View {
        let counts = model.session?.mediaCount(item.id) ?? Session.MediaCount()
        HStack(spacing: 8) {
            Text("\(index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(2)
                if counts.images + counts.videos > 0 {
                    HStack(spacing: 6) {
                        if counts.images > 0 { Label("\(counts.images)", systemImage: "photo").labelStyle(.titleAndIcon) }
                        if counts.videos > 0 { Label("\(counts.videos)", systemImage: "video").labelStyle(.titleAndIcon) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - detail

struct ItemDetail: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TemplateBar()
            Divider()
            if model.selectedID != nil {
                TextField("Title", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6)
                    .focused($titleFocused)
                    .onSubmit {
                        model.commitTitle()
                        model.editor.focus()
                    }
                    .onChange(of: titleFocused) { _, focused in if !focused { model.commitTitle() } }
                    .onChange(of: model.focusTitle) { _, want in
                        if want {
                            titleFocused = true
                            model.focusTitle = false
                            DispatchQueue.main.async { NSApp.keyWindow?.fieldEditor(false, for: nil)?.selectAll(nil) }
                        }
                    }
            }
            EditorContainer(bridge: model.editor)
                .opacity(model.selectedID == nil ? 0 : 1)
                .overlay {
                    if model.selectedID == nil {
                        VStack(spacing: 10) {
                            Text("No item selected").font(.title3).foregroundStyle(.secondary)
                            Button("New Item") { model.newItemFromMenu() }
                        }
                    }
                }
            StatusBar()
        }
    }
}

struct EditorContainer: NSViewRepresentable {
    let bridge: EditorBridge
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let wv = bridge.webView!
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: v.leadingAnchor), wv.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            wv.topAnchor.constraint(equalTo: v.topAnchor), wv.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var capture: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            if capture.isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording").foregroundStyle(.red)
            }
            if let s = model.status {
                Text(s).lineLimit(1).truncationMode(.middle)
            } else if let session = model.session {
                Text(session.displayPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.session != nil {
                Button("Show in Finder") { model.revealSession() }.buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - welcome and session picker

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let recent = Array(Session.list(root: model.config.sessionsFolder).prefix(6))
        VStack(spacing: 16) {
            Image(systemName: "note.text.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Start a session").font(.title2.weight(.semibold))
            Text("A session is one sitting of testing: numbered items, each with a note, screenshots and recordings.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("New Session") { model.newSession() }.keyboardShortcut(.defaultAction).controlSize(.large)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or continue one").font(.caption).foregroundStyle(.secondary)
                    ForEach(recent, id: \.path) { r in
                        Button { model.openSession(r.path) } label: {
                            HStack {
                                Text(r.title)
                                Spacer()
                                Text("\(r.items) items · \(r.created.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                            }
                            .frame(width: 380)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let sessions = Session.list(root: model.config.sessionsFolder)
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions in \(model.config.sessionsFolder)").font(.headline)
            if sessions.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            List(sessions, id: \.path) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.title)
                        Text((s.path as NSString).lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("\(s.created.formatted(date: .abbreviated, time: .shortened)) · \(s.items) item\(s.items == 1 ? "" : "s")"
                             + (s.firstTitles.isEmpty ? "" : " · " + s.firstTitles.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if s.path == model.session?.displayPath { Text("open").font(.caption).foregroundStyle(.secondary) }
                    Button("Open") { model.openSession(s.path); dismiss() }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Other Folder…") { dismiss(); model.chooseSessionFolder() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("New Session") { model.newSession(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

struct HeaderEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var own = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session header").font(.headline)
            Text("Written at the top of README.md and used by Copy Hand-off. Placeholders: {session} {readme} {date} {items}.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $own) {
                Text("Use the global header (Settings › General)").tag(false)
                Text("This session has its own header").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .disabled(!own)
                .opacity(own ? 1 : 0.6)
            HStack {
                Button("Save as the Global Header") { model.updateConfig { $0.header = text } }
                    .disabled(!own || text == model.config.header)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setSessionHeader(own ? text : nil); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
        .onAppear {
            own = model.session?.manifest.header != nil
            text = model.session?.manifest.header ?? model.config.header
        }
        .onChange(of: own) { _, isOwn in if !isOwn { text = model.config.header } }
    }
}

// MARK: - window

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

@MainActor
enum WindowPlacement {
    /// Kept strongly: the notebook is hidden, not destroyed, when its window is closed.
    static var notebook: NSWindow?
    /// SwiftUI's openWindow, captured from the always-present menu bar icon.
    static var openNotebook: (() -> Void)?

    static func configure(_ w: NSWindow, model: AppModel) {
        guard notebook !== w else { return }
        notebook = w
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("SnagbookNotebook")
        apply(onTop: model.config.alwaysOnTop)
    }

    /// Always on top also means: visible over a full-screen game in its own Space.
    static func apply(onTop: Bool) {
        guard let w = notebook else { return }
        w.level = onTop ? .floating : .normal
        w.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = notebook, w.contentView != nil {
            w.makeKeyAndOrderFront(nil)
        } else {
            openNotebook?()
        }
    }

    static func toggle(_ model: AppModel) {
        if let w = notebook, w.isVisible, NSApp.isActive, w.isKeyWindow {
            NSApp.hide(nil)
        } else {
            show()
        }
    }
}
