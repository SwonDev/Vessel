#if DEBUG
import SwiftUI
import AppKit

/// Escenario reproducible para validar la interfaz en una ventana macOS real sin autenticar tiendas,
/// iniciar instalaciones ni tocar la sesión de producción. Solo existe en compilaciones Debug y se
/// activa explícitamente con `VESSEL_UI_REVIEW=1`.
struct VesselUIReviewView: View {
    private var initiallySelectedGameID: String? {
        ProcessInfo.processInfo.environment["VESSEL_UI_REVIEW_DETAIL"] == "1" ? "1086940" : nil
    }

    private let games: [StoreGame] = [
        StoreGame(
            id: "1086940",
            title: "Baldur's Gate 3",
            steamAppId: "1086940",
            installed: true,
            updateAvailable: true,
            lastPlayed: Calendar.current.date(byAdding: .hour, value: -4, to: .now),
            playtimeMinutes: 7_842,
            installPath: "/Applications/Vessel UI Review/Baldurs Gate 3"
        ),
        StoreGame(
            id: "1145350",
            title: "Hades II",
            steamAppId: "1145350",
            installed: false,
            lastPlayed: Calendar.current.date(byAdding: .day, value: -2, to: .now),
            playtimeMinutes: 816
        ),
        StoreGame(
            id: "1091500",
            title: "Cyberpunk 2077",
            steamAppId: "1091500",
            installed: true,
            lastPlayed: Calendar.current.date(byAdding: .day, value: -8, to: .now),
            playtimeMinutes: 4_209,
            installPath: "/Applications/Vessel UI Review/Cyberpunk 2077"
        ),
        StoreGame(
            id: "275850",
            title: "No Man's Sky",
            steamAppId: "275850",
            installed: true,
            lastPlayed: Calendar.current.date(byAdding: .day, value: -16, to: .now),
            playtimeMinutes: 2_964,
            installPath: "/Applications/Vessel UI Review/No Mans Sky"
        ),
        StoreGame(id: "367520", title: "Hollow Knight", steamAppId: "367520", installed: true),
        StoreGame(id: "379720", title: "DOOM", steamAppId: "379720", installed: false),
        StoreGame(id: "870780", title: "Control Ultimate Edition", steamAppId: "870780", installed: true),
        StoreGame(id: "632470", title: "Disco Elysium", steamAppId: "632470", installed: false),
        StoreGame(id: "292030", title: "The Witcher 3", steamAppId: "292030", installed: true),
        StoreGame(id: "413150", title: "Stardew Valley", steamAppId: "413150", installed: true),
        StoreGame(id: "1245620", title: "ELDEN RING", steamAppId: "1245620", installed: false),
        StoreGame(id: "620", title: "Portal 2", steamAppId: "620", installed: true)
    ]

    private let activityEvents: [LibraryActivityStore.Event] = [
        .init(storeID: StoreKind.steam.rawValue, gameID: "1086940", title: "Baldur's Gate 3",
              kind: .update, outcome: .completed,
              occurredAt: Calendar.current.date(byAdding: .minute, value: -18, to: .now) ?? .now),
        .init(storeID: StoreKind.steam.rawValue, gameID: "1091500", title: "Cyberpunk 2077",
              kind: .verify, outcome: .completed,
              occurredAt: Calendar.current.date(byAdding: .hour, value: -3, to: .now) ?? .now),
        .init(storeID: StoreKind.steam.rawValue, gameID: "1145350", title: "Hades II",
              kind: .install, outcome: .failed,
              occurredAt: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now,
              detail: "La descarga perdió la conexión")
    ]

    var body: some View {
        StoreLibraryView(
            store: .steam,
            games: games,
            activityEventsOverride: activityEvents,
            initiallySelectedGameID: initiallySelectedGameID,
            installingIDs: ["1145350"],
            progressFor: { $0 == "1145350" ? "Descargando… 63%" : nil },
            percentFor: { $0 == "1145350" ? 0.63 : nil }
        )
        .onAppear {
            // La revisión puede convivir con la aplicación instalada; elevar solo esta ventana
            // evita cerrar o alterar la sesión real durante una captura visual.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.orderFrontRegardless()
        }
    }
}
#endif
