import SwiftUI

struct LogsView: View {
    @Environment(\.dismiss) private var dismiss
    private var logStore = LogStore.shared
    @State private var filter: LogStore.Level?
    /// Lista filtrada MEMOIZADA: se recalcula solo al cambiar entradas o filtro (antes se computaba
    /// 2-3× por render — ForEach + contador — filtrando hasta 1000 entradas cada vez).
    @State private var filteredEntries: [LogStore.Entry] = []

    /// Nivel de registro en español para la UI (los rawValue internos siguen en inglés).
    static func displayName(for level: LogStore.Level) -> String {
        switch level {
        case .info: return "Info"
        case .warn: return "Avisos"
        case .error: return "Errores"
        case .debug: return "Depuración"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Barra de herramientas
            HStack(spacing: 12) {
                Text("Registros de Vessel")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Picker("Nivel", selection: $filter) {
                    Text("Todos").tag(LogStore.Level?.none)
                    ForEach([LogStore.Level.info, .warn, .error, .debug], id: \.self) { level in
                        Text(Self.displayName(for: level)).tag(LogStore.Level?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .vesselHelp("Filtrar los registros por nivel")
                Button {
                    logStore.clear()
                } label: {
                    Label("Limpiar", systemImage: "trash")
                }
                .vesselButton(false)
                .vesselHelp("Borrar todos los registros de esta sesión")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        logStore.entries
                            .map { "[\($0.timestamp.formatted(.iso8601))] [\($0.level.rawValue)] \($0.message)" }
                            .joined(separator: "\n"),
                        forType: .string
                    )
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .vesselButton(false)
                .vesselHelp("Copiar todos los registros al portapapeles")
            }
            .padding(20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .background(Theme.navyDeep)
                .onChange(of: logStore.entries.count) { _, _ in
                    filteredEntries = computeFilteredLogs()
                    // Sin `withAnimation`: con Wine emitiendo cientos de líneas/seg, animar cada
                    // scroll encolaba animaciones que nunca asentaban → tirones. Y se sigue al ÚLTIMO
                    // de la lista FILTRADA (no `entries.last`, que con un filtro activo podía no estar
                    // en pantalla → el auto-follow dejaba de funcionar sin avisar).
                    if let last = filteredEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: filter) { _, _ in
                    filteredEntries = computeFilteredLogs()
                    if let last = filteredEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    filteredEntries = computeFilteredLogs()
                    if let last = filteredEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                Text("\(filteredEntries.count) entradas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .vesselButton(false)
                    .keyboardShortcut(.cancelAction)
                    .vesselHelp("Cerrar registros", shortcut: "Esc")
            }
            .padding(16)
        }
        .frame(width: 820, height: 540)
        .vesselBackground()
    }

    private func computeFilteredLogs() -> [LogStore.Entry] {
        guard let filter = filter else { return logStore.entries }
        return logStore.entries.filter { $0.level == filter }
    }

    private func logRow(_ entry: LogStore.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(entry.level.rawValue)
                .font(.caption.monospaced())
                .fontWeight(.semibold)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 60, alignment: .leading)
            Text(entry.message)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func color(for level: LogStore.Level) -> Color {
        switch level {
        case .info:  return Theme.accent
        case .warn:  return .yellow
        case .error: return Theme.destructive
        case .debug: return Theme.secondaryText
        }
    }
}
