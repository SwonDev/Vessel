import SwiftUI

struct ShortcutReferenceView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [(String, String)])] = [
        ("Biblioteca", [
            ("⌘K", "Abrir un juego rápidamente"),
            ("⌘F", "Buscar juegos"),
            ("⌘L", "Mostrar u ocultar la lista"),
            ("⌘R", "Actualizar la biblioteca"),
            ("⌘0", "Mostrar todos los juegos")
        ]),
        ("Juego seleccionado", [
            ("⌘↩", "Jugar, detener o instalar"),
            ("⇧⌘F", "Añadir o quitar de favoritos"),
            ("⌥⌘N", "Abrir las notas del juego"),
            ("⌘[", "Navegar atrás"),
            ("⌘]", "Navegar adelante"),
            ("Esc", "Cerrar la ficha o limpiar la búsqueda")
        ]),
        ("Plataformas", [
            ("⌘1", "Steam"),
            ("⌘2", "Epic Games"),
            ("⌘3", "GOG"),
            ("⌘4", "DRM-free")
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atajos de teclado")
                        .font(.title2.weight(.semibold))
                    Text("Acciones rápidas sin añadir controles a la biblioteca.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(section.0.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(section.1.enumerated()), id: \.offset) { index, shortcut in
                                    ShortcutReferenceRow(keys: shortcut.0, action: shortcut.1)
                                    if index < section.1.count - 1 {
                                        Divider().opacity(0.24)
                                    }
                                }
                            }
                            .vesselCard(padding: 8, cornerRadius: Theme.Radius.card)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Los menús Biblioteca y Juego muestran los atajos disponibles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .vesselButton(false)
                    .keyboardShortcut(.cancelAction)
                    .vesselHelp("Cerrar la guía de atajos", shortcut: "Esc")
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .vesselBackground()
    }
}

private struct ShortcutReferenceRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 16) {
            Text(keys)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(minWidth: 54)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
            Text(action)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.82))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(action), \(keys)")
    }
}
