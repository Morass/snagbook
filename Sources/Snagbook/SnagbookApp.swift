import AppKit
import KeyboardShortcuts
import SnagbookCore
import SwiftUI

@main
struct SnagbookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = AppModel.shared

    init() {
        // Tooltips carry the shortcuts; the system's ~1.5 s wait hides them from anyone
        // who only glances. Registered, so a value the user set with `defaults` still wins.
        UserDefaults.standard.register(defaults: [Self.toolTipDelayKey: Self.toolTipDelay])
    }
    static let toolTipDelayKey = "NSInitialToolTipDelay"
    static let toolTipDelay = 400

    var body: some Scene {
        Window("Snagbook", id: "notebook") {
            NotebookView()
                .environmentObject(model)
                .environmentObject(model.capture)
        }
        .defaultSize(width: 980, height: 720)
        .commands { SnagbookCommands(model: model, capture: model.capture) }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model).environmentObject(model.capture)
        } label: {
            MenuBarLabel(capture: model.capture)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            KeyboardShortcuts.onKeyUp(for: .record) { model.capture.recordAction() }
            KeyboardShortcuts.onKeyUp(for: .screenshot) { model.capture.screenshotAction() }
            KeyboardShortcuts.onKeyUp(for: .newItem) {
                WindowPlacement.show()
                model.newItemFromMenu()
            }
            KeyboardShortcuts.onKeyUp(for: .showNotebook) { WindowPlacement.toggle(model) }
            SelfTest.runIfRequested(model)
            Shots.runIfRequested(model)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.refreshSessionFromDisk() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.capture.isRecording {
                let a = NSAlert()
                a.messageText = "A recording is running"
                a.informativeText = "Stop it and save it into the note before quitting?"
                a.addButton(withTitle: "Stop and Save")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
                model.capture.stopRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForSave(sender) }
                return .terminateLater
            }
            if model.capture.phase == .saving {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForSave(sender) }
                return .terminateLater
            }
            Task {
                await model.editor.flush()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    @MainActor private func waitForSave(_ app: NSApplication) {
        if AppModel.shared.capture.phase == .idle {
            Task {
                await AppModel.shared.editor.flush()
                app.reply(toApplicationShouldTerminate: true)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForSave(app) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowPlacement.show() } }
        return true
    }
}

struct SnagbookCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Item") { model.newItemFromMenu() }.keyboardShortcut("n")
            Button("New Session") { model.newSession() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Session…") { model.showingSessions = true }.keyboardShortcut("o")
            Divider()
            Button("Copy Hand-off") { model.copyHandoff() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.session == nil)
            Button("Edit Session Header…") { model.editingHeader = true }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.session == nil)
            Button("Show Session in Finder") { model.revealSession() }.disabled(model.session == nil)
        }
        CommandMenu("Capture") {
            Button(capture.recordButtonTitle) { capture.recordAction() }
            Button("Screenshot") { capture.screenshotAction() }
            if capture.phase != .idle {
                Button("Cancel Capture") { capture.cancel() }
            }
            Divider()
            Text("Anywhere: \(KeyboardShortcuts.Name.record.hint) record · \(KeyboardShortcuts.Name.screenshot.hint) screenshot")
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
        }
        CommandMenu("Templates") {
            ForEach(Array(model.config.templates.prefix(9).enumerated()), id: \.element.id) { i, t in
                Button((t.icon.isEmpty ? "" : t.icon + " ") + t.label) { model.insertTemplate(t) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            Divider()
            Button("New Template…") { model.editingTemplate = Template(label: "", body: "") }
        }
        CommandGroup(after: .windowArrangement) {
            Toggle("Always on Top", isOn: Binding(get: { model.config.alwaysOnTop }, set: { v in
                model.updateConfig { $0.alwaysOnTop = v }
                WindowPlacement.apply(onTop: v)
            }))
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var capture: CaptureController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: capture.isRecording ? "record.circle.fill" : "note.text")
            .onAppear { WindowPlacement.openNotebook = { openWindow(id: "notebook") } }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var capture: CaptureController

    var body: some View {
        Button(capture.recordButtonTitle) { capture.recordAction() }
        Button("Screenshot") { capture.screenshotAction() }
        Button("New Item") {
            WindowPlacement.show()
            model.newItemFromMenu()
        }
        Divider()
        Button("New Session") { model.newSession() }
        Menu("Continue a Session") {
            ForEach(Array(Session.list(root: model.config.sessionsFolder).prefix(10)), id: \.path) { r in
                Button(r.title + (r.path == model.session?.displayPath ? "  ✓" : "")) { model.openSession(r.path); WindowPlacement.show() }
            }
        }
        Divider()
        Button("Show Notebook") { WindowPlacement.show() }
        Button("Copy Hand-off") { model.copyHandoff() }.disabled(model.session == nil)
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Snagbook") { NSApp.terminate(nil) }
    }
}
