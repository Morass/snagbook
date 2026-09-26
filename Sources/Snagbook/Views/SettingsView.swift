import KeyboardShortcuts
import SnagbookCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettingsView().tabItem { Label("Capture", systemImage: "record.circle") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            TemplateSettings().tabItem { Label("Templates", systemImage: "text.badge.plus") }
        }
        .frame(width: 580, height: 440)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var header = ""

    var body: some View {
        Form {
            LabeledContent("New sessions go to") {
                HStack {
                    Text(model.config.sessionsFolder).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            TextField("Session folder name", text: Binding(get: { model.config.folderFormat }, set: { v in model.updateConfig { $0.folderFormat = v } }))
            Text("Tokens: {hash} {yyyy} {MM} {dd} {HH} {mm}").font(.caption).foregroundStyle(.secondary)
            Picker("Copy Hand-off copies", selection: Binding(get: { model.config.handoff }, set: { v in model.updateConfig { $0.handoff = v } })) {
                Text("the header text").tag(HandoffStyle.header)
                Text("the README path only").tag(HandoffStyle.path)
            }
            Toggle("Keep the notebook above other windows (also over full-screen apps)", isOn: Binding(
                get: { model.config.alwaysOnTop },
                set: { v in model.updateConfig { $0.alwaysOnTop = v }; WindowPlacement.apply(onTop: v) }))
            Section("Header for new sessions") {
                TextEditor(text: $header).font(.system(.callout, design: .monospaced)).frame(minHeight: 110)
                HStack {
                    Text("Placeholders: {session} {readme} {date} {items}").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { header = Config.defaultHeader }
                    Button("Save") { model.updateConfig { $0.header = header } }.disabled(header == model.config.header)
                }
            }
            LabeledContent("Settings file") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.configURL]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { header = model.config.header }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = Paths.url(model.config.sessionsFolder)
        if p.runModal() == .OK, let u = p.url { model.updateConfig { $0.sessionsFolder = Paths.abbreviate(u.path) } }
    }
}

struct CaptureSettingsView: View {
    @EnvironmentObject var model: AppModel

    func bind<T>(_ kp: WritableKeyPath<CaptureSettings, T>) -> Binding<T> {
        Binding(get: { model.config.capture[keyPath: kp] }, set: { v in model.updateConfig { $0.capture[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Picker("Frame rate", selection: bind(\.fps)) {
                Text("10 fps (smallest)").tag(10)
                Text("15 fps").tag(15)
                Text("30 fps (smoothest)").tag(30)
            }
            Picker("Largest size", selection: bind(\.maxLongEdge)) {
                Text("1280 px").tag(1280)
                Text("1920 px").tag(1920)
                Text("2560 px").tag(2560)
            }
            Toggle("Record the sound the Mac plays", isOn: bind(\.systemAudio))
            Toggle("Show the mouse pointer", isOn: bind(\.showCursor))
            Toggle("Open the mark-up window after a screenshot", isOn: bind(\.annotateScreenshots))
            Stepper("Stills beside each video: up to \(model.config.capture.maxStills)", value: bind(\.maxStills), in: 0...300, step: 10)
            Text("Stills are one frame per second as JPEG, plus a contact sheet, so a video can be understood without playing it.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Screen Recording permission") {
                if CGPreflightScreenCaptureAccess() {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open System Settings") { Permissions.openScreenRecordingSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section("Work in any app, including full-screen games") {
                KeyboardShortcuts.Recorder("Record (drag a rectangle) / stop:", name: .record)
                KeyboardShortcuts.Recorder("Screenshot:", name: .screenshot)
                KeyboardShortcuts.Recorder("New item:", name: .newItem)
                KeyboardShortcuts.Recorder("Show or hide the notebook:", name: .showNotebook)
            }
            Section("In the notebook") {
                shortcut("New item", "⌘N")
                shortcut("New session / open a session", "⇧⌘N  ⌘O")
                shortcut("Edit the session header", "⇧⌘H")
                shortcut("Back / Forward", "⌘[  ⌘]")
                shortcut("Templates 1–9", "⌘1 … ⌘9")
                shortcut("Copy hand-off", "⇧⌘C")
                shortcut("Always on top", "⌥⌘T")
                shortcut("Bold, italic, underline, strikethrough", "⌘B ⌘I ⌘U ⇧⌘X")
                shortcut("Heading 1–3 / body text", "⌥⌘1–3  ⌥⌘0")
                shortcut("Bullets / numbers / checklist", "⇧⌘8  ⇧⌘7  ⇧⌘9")
            }
            Section("While dragging the rectangle") {
                shortcut("Whole screen instead", "F")
                shortcut("Cancel", "Esc")
            }
            Section("In the mark-up window") {
                shortcut("Highlighter, circle, arrow, box, pen", "H  O  A  R  P")
                shortcut("Text, number, blur, crop, select", "T  N  B  C  V")
                shortcut("Colour 1–6", "1 … 6")
                shortcut("Thinner / thicker", "[  ]")
                shortcut("More see-through / more solid", ",  .")
                shortcut("Square, circle, 45° arrow", "hold ⇧ while dragging")
                shortcut("Undo / redo", "⌘Z  ⇧⌘Z")
                shortcut("Delete the selected mark", "⌫")
                shortcut("Done / keep as it was / throw away", "↩  Esc  ⌘⌫")
            }
        }
        .formStyle(.grouped)
    }

    func shortcut(_ what: String, _ keys: String) -> some View {
        LabeledContent(what) { Text(keys).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

struct TemplateSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(Array(model.config.templates.enumerated()), id: \.element.id) { i, t in
                    HStack {
                        Text(i < 9 ? "⌘\(i + 1)" : "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                        TemplateIcon(icon: t.icon)
                        Text(t.label).fontWeight(.medium)
                        Text(t.body.replacingOccurrences(of: "\n", with: " ⏎ ")).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Edit…") { model.editingTemplate = t; WindowPlacement.toggleFront() }
                        Button { model.deleteTemplate(t) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("Add Template…") { model.editingTemplate = Template(label: "", body: ""); WindowPlacement.toggleFront() }
                Spacer()
                Button("Restore Defaults") { model.updateConfig { $0.templates = Config.defaultTemplates } }
            }
            .padding(10)
        }
    }
}

extension WindowPlacement {
    /// Template editing happens in a sheet on the notebook; bring it forward.
    static func toggleFront() { show() }
}
