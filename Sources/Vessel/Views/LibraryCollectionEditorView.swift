import SwiftUI

/// Editor compacto para crear o renombrar una colección. Se presenta solo a petición del usuario;
/// las colecciones no añaden formularios ni controles permanentes a la biblioteca.
struct LibraryCollectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    let title: String
    let subtitle: String
    let actionTitle: String
    let tint: Color
    let onSave: (String) -> Bool

    init(title: String, subtitle: String, actionTitle: String, initialName: String = "",
         tint: Color, onSave: @escaping (String) -> Bool) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.tint = tint
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var cleanedName: String { LibraryCollectionsStore.sanitizedName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("NOMBRE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Por ejemplo, Cooperativos", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityLabel("Nombre de la colección")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .vesselButton(false, tint: tint)
                    .keyboardShortcut(.cancelAction)
                    .vesselHelp("Cancelar", shortcut: "Esc")
                Button(actionTitle, action: save)
                    .vesselButton(tint: tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanedName.isEmpty)
                    .vesselHelp(actionTitle, shortcut: "↩")
            }
        }
        .padding(24)
        .frame(width: 460)
        .vesselBackground(tint: tint)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !cleanedName.isEmpty else { return }
        if onSave(cleanedName) {
            dismiss()
        } else {
            errorMessage = "Ya existe una colección con ese nombre."
        }
    }
}
