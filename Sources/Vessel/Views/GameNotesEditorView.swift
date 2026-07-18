import SwiftUI

/// Editor de una nota privada por juego. El guardado es automático y con retardo para evitar una
/// escritura a disco por pulsación; al cerrar se fuerza la persistencia de cualquier cambio final.
struct GameNotesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var savedText: String
    @State private var saved = true
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmingDeletion = false
    /// El texto alcanzó el máximo y se truncó: muestra un aviso persistente en el editor
    /// (antes el truncado era silencioso).
    @State private var truncationNoticeShown = false
    @State private var deletionCommitted = false
    @State private var lastSavedAt: Date?
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let game: StoreGame
    let store: StoreKind
    let tint: Color
    let updatedAt: Date?
    let onSave: (String) -> Void
    let onDelete: () -> Void

    init(game: StoreGame, store: StoreKind, tint: Color, initialText: String,
         updatedAt: Date?, onSave: @escaping (String) -> Void,
         onDelete: @escaping () -> Void) {
        self.game = game
        self.store = store
        self.tint = tint
        self.updatedAt = updatedAt
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
        _lastSavedAt = State(initialValue: updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            editor
            footer
        }
        .padding(24)
        .frame(width: 640, height: 500)
        .vesselBackground(tint: tint)
        .onAppear { editorFocused = true }
        .onChange(of: text) { _, newValue in
            if newValue.count > GameNotesStore.maximumLength {
                // Aviso VISIBLE del truncado: antes el texto se cortaba en silencio y el usuario
                // perdía el final sin enterarse (solo el contador lo delataba).
                text = GameNotesStore.normalizedText(newValue)
                truncationNoticeShown = true
            }
            scheduleSave()
        }
        .onDisappear(perform: flushPendingSave)
        .confirmationDialog("¿Borrar la nota de «\(game.title)»?", isPresented: $confirmingDeletion) {
            Button("Borrar nota", role: .destructive) {
                saveTask?.cancel()
                deletionCommitted = true
                onDelete()
                dismiss()
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Esta acción elimina únicamente la nota local; no afecta al juego ni a sus partidas.")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "note.text")
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notas del juego")
                    .font(.title2.weight(.semibold))
                Text(game.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Label("Solo en este Mac · \(store.displayName)", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("La nota se guarda solo en este Mac")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .focused($editorFocused)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .accessibilityLabel("Nota de \(game.title)")
                .accessibilityHint("Se guarda automáticamente en Vessel")
            if truncationNoticeShown {
                Label("Has llegado al máximo de \(GameNotesStore.maximumLength.formatted()) caracteres: el texto sobrante se ha cortado.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: truncationNoticeShown)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) { confirmingDeletion = true } label: {
                    Label("Borrar nota…", systemImage: "trash")
                }
                .vesselButton(false, tint: Theme.destructive)
                .vesselHelp("Borrar la nota local")
            }

            VStack(alignment: .leading, spacing: 2) {
                Label(saved ? "Guardada" : "Guardando…",
                      systemImage: saved ? "checkmark.circle.fill" : "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(saved ? .secondary : tint)
                if let lastSavedAt, text == savedText {
                    Text("Último cambio \(lastSavedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
            Text("\(text.count.formatted()) / \(GameNotesStore.maximumLength.formatted())")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("\(text.count) de \(GameNotesStore.maximumLength) caracteres")
            Button("Cerrar") { dismiss() }
                .vesselButton(false, tint: tint)
                .keyboardShortcut(.cancelAction)
                .vesselHelp("Cerrar las notas", shortcut: "Esc")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard text != savedText else {
            saved = true
            return
        }
        saved = false
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            onSave(text)
            savedText = text
            lastSavedAt = Date()
            saved = true
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard !deletionCommitted else { return }
        guard text != savedText else { return }
        onSave(text)
        savedText = text
        lastSavedAt = Date()
        saved = true
    }
}
