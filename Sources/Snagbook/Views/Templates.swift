import SnagbookCore
import SwiftUI

/// The row of template buttons above the note. A click types the template at the caret;
/// ⌘1…⌘9 do the same for the first nine.
struct TemplateBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.config.templates.enumerated()), id: \.element.id) { i, t in
                        TemplateButton(template: t, index: i)
                    }
                    if model.config.templates.isEmpty {
                        Text("Templates: add text you type often").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Button {
                model.editingTemplate = Template(label: "", icon: "", body: "")
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New template")
        }
        .padding(.horizontal, 12)
        .background(.bar)
    }
}

struct TemplateButton: View {
    @EnvironmentObject var model: AppModel
    let template: Template
    let index: Int

    var body: some View {
        Button { model.insertTemplate(template) } label: {
            HStack(spacing: 4) {
                TemplateIcon(icon: template.icon)
                if !template.label.isEmpty { Text(template.label) }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(helpText)
        .contextMenu {
            Button("Edit…") { model.editingTemplate = template }
            Button("Move Left") { model.moveTemplate(template, by: -1) }.disabled(index == 0)
            Button("Move Right") { model.moveTemplate(template, by: 1) }.disabled(index == model.config.templates.count - 1)
            Divider()
            Button("Delete", role: .destructive) { model.deleteTemplate(template) }
        }
    }

    var helpText: String {
        let preview = template.body.replacingOccurrences(of: "\n", with: "⏎").prefix(80)
        return (index < 9 ? "⌘\(index + 1) · " : "") + "Inserts: \(preview)\nRight-click to edit or delete."
    }
}

/// An emoji or short text is drawn as is; a name like "ant.fill" is an SF Symbol.
struct TemplateIcon: View {
    let icon: String
    var body: some View {
        if icon.isEmpty {
            EmptyView()
        } else if icon.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon)
        } else {
            Text(icon)
        }
    }
}

struct TemplateEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var template: Template

    var isNew: Bool { !model.config.templates.contains { $0.id == template.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New template" : "Edit template").font(.headline)
            Form {
                TextField("Button label", text: $template.label, prompt: Text("e.g. Bug"))
                TextField("Icon", text: $template.icon, prompt: Text("optional: an emoji, or an SF Symbol name like ant.fill"))
                LabeledContent("Preview") {
                    HStack(spacing: 4) {
                        TemplateIcon(icon: template.icon)
                        Text(template.label.isEmpty && template.icon.isEmpty ? "—" : template.label)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                }
            }
            Text("Text to insert (Markdown: **bold**, - list, 1. numbered)").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $template.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { model.deleteTemplate(template); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { model.saveTemplate(template); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((template.label.isEmpty && template.icon.isEmpty) || template.body.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}
