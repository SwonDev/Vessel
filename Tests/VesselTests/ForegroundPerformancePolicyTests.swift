import Foundation
import Testing
@testable import Vessel

@Suite("Rendimiento al recuperar el foco")
struct ForegroundPerformancePolicyTests {
    @Test("El watcher evita recorrer de nuevo toda la biblioteca")
    func activeWatcherSkipsLibraryScan() {
        #expect(!SteamForegroundRefreshPolicy.shouldScanLibrary(watcherIsActive: true))
        #expect(SteamForegroundRefreshPolicy.shouldScanLibrary(watcherIsActive: false))
    }

    @Test("SteamCMD solo comprueba builds cuando toca o el usuario lo fuerza")
    func updateChecksAreRateLimited() {
        let now = Date(timeIntervalSince1970: 20_000)

        #expect(SteamForegroundRefreshPolicy.shouldCheckUpdates(
            lastCheck: nil,
            now: now,
            force: false
        ))
        #expect(!SteamForegroundRefreshPolicy.shouldCheckUpdates(
            lastCheck: now.addingTimeInterval(-30),
            now: now,
            force: false
        ))
        #expect(SteamForegroundRefreshPolicy.shouldCheckUpdates(
            lastCheck: now.addingTimeInterval(-SteamForegroundRefreshPolicy.updateCheckInterval),
            now: now,
            force: false
        ))
        #expect(SteamForegroundRefreshPolicy.shouldCheckUpdates(
            lastCheck: now,
            now: now,
            force: true
        ))
        #expect(!SteamForegroundRefreshPolicy.shouldCheckUpdates(
            lastCheck: nil,
            now: now,
            force: true,
            hasActiveLibraryOperations: true
        ))
    }

    @Test("La caché contabiliza memoria decodificada, no solo bytes comprimidos")
    func coverCacheUsesPixelCost() {
        #expect(CoverCache.estimatedMemoryCost(
            pixelWidth: 600,
            pixelHeight: 900,
            fallbackBytes: 100_000
        ) == 2_160_000)
        #expect(CoverCache.estimatedMemoryCost(
            pixelWidth: 0,
            pixelHeight: 0,
            fallbackBytes: 100_000
        ) == 400_000)
    }
}
