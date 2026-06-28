import SwiftUI

struct BottleSidebar: View {
    let bottles: [Bottle]
    @Binding var selectedBottleID: UUID?
    private let store = BottleStore.shared

    var body: some View {
        List(selection: $selectedBottleID) {
            Section("Bottles") {
                if bottles.isEmpty {
                    Text("Sin bottles")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(bottles) { bottle in
                        BottleRow(bottle: bottle).tag(bottle.id)
                    }
                    .onDelete(perform: deleteBottles)
                }
            }
        }
        .navigationTitle("Vessel")
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    private func deleteBottles(at offsets: IndexSet) {
        let toDelete = offsets.map { bottles[$0] }
        for bottle in toDelete {
            try? FileManager.default.removeItem(atPath: bottle.prefixPath)
            store.delete(bottle)
        }
    }
}

struct BottleRow: View {
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wineglass.fill")
                .foregroundStyle(.purple)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.headline)
                Text("\(bottle.games.count) juego\(bottle.games.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
