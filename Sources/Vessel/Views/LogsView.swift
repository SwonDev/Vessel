import SwiftUI

struct LogsView: View {
    @Environment(\.dismiss) private var dismiss
    private var logStore = LogStore.shared
    @State private var filter: LogStore.Level?

    var body: some View {
        VStack(spacing: 0) {
            // Barra de herramientas
            HStack(spacing: 12) {
                Text("Logs de Vessel")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Picker("Nivel", selection: $filter) {
                    Text("Todos").tag(LogStore.Level?.none)
                    ForEach([LogStore.Level.info, .warn, .error, .debug], id: \.self) { level in
                        Text(level.rawValue).tag(LogStore.Level?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Button {
                    logStore.clear()
                } label: {
                    Label("Limpiar", systemImage: "trash")
                }
                .buttonStyle(.premium(prominent: false))
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
                .buttonStyle(.premium(prominent: false))
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
                .background(Color.black.opacity(0.35))
                .onChange(of: logStore.entries.count) { _, _ in
                    if let last = logStore.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack {
                Text("\(filteredEntries.count) entradas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.premium(prominent: false))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 820, height: 540)
        .vesselBackground()
    }

    private var filteredEntries: [LogStore.Entry] {
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
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        case .debug: return Color.secondary
        }
    }
}
