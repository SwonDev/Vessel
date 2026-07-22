import Testing
@testable import Vessel

struct GameDetailParallaxTests {
    @Test("El hero empieza centrado dentro de su sobremuestreo")
    func initialPosition() {
        let metrics = GameDetailParallax.metrics(scrollY: 0, reduceMotion: false)

        #expect(metrics.overscan == 60)
        #expect(metrics.offset == -30)
    }

    @Test("El parallax avanza de forma contenida y no descubre el borde")
    func boundedScroll() {
        let halfway = GameDetailParallax.metrics(scrollY: -160, reduceMotion: false)
        let beyondHero = GameDetailParallax.metrics(scrollY: -640, reduceMotion: false)

        #expect(halfway.offset == -15)
        #expect(beyondHero.offset == 0)
    }

    @Test("Reducir movimiento elimina desplazamiento y sobremuestreo")
    func reducedMotion() {
        let metrics = GameDetailParallax.metrics(scrollY: -200, reduceMotion: true)

        #expect(metrics == .init(overscan: 0, offset: 0))
    }

    @Test("La barra contextual solo aparece después de abandonar hero y acciones")
    func stickyActionBarThreshold() {
        #expect(!GameDetailScrollBehavior.showsStickyActionBar(
            contentOffsetY: GameDetailScrollBehavior.stickyActionThreshold - 1,
            topInset: 0
        ))
        #expect(GameDetailScrollBehavior.showsStickyActionBar(
            contentOffsetY: GameDetailScrollBehavior.stickyActionThreshold,
            topInset: 1
        ))
    }

    @Test("Título y acciones flotan con el mismo desplazamiento sobre el borde del hero")
    func heroContentKeepsSafeBottomSpacing() {
        #expect(Theme.Space.heroActionOverlap == Theme.Space.page)
        #expect(Theme.Space.heroTitleInset - Theme.Space.heroActionOverlap == 52)
    }

    @Test("El carrusel limita la navegación al primer y último elemento")
    func screenshotNavigationIsBounded() {
        #expect(GameDetailScrollBehavior.screenshotIndex(current: nil, movingBy: -1, count: 4) == 0)
        #expect(GameDetailScrollBehavior.screenshotIndex(current: 1, movingBy: 1, count: 4) == 2)
        #expect(GameDetailScrollBehavior.screenshotIndex(current: 3, movingBy: 1, count: 4) == 3)
        #expect(GameDetailScrollBehavior.screenshotIndex(current: 0, movingBy: 1, count: 0) == nil)
    }

    @Test("El tamaño local se invalida al instalar, desinstalar o cambiar de ruta")
    func diskSizeMeasurementTracksLiveInstallationState() {
        let installed = GameDetailDiskSize.taskID(
            gameID: "1091500",
            installed: true,
            installPath: "/Games/Cyberpunk 2077"
        )
        let uninstalled = GameDetailDiskSize.taskID(
            gameID: "1091500",
            installed: false,
            installPath: nil
        )
        let moved = GameDetailDiskSize.taskID(
            gameID: "1091500",
            installed: true,
            installPath: "/External/Cyberpunk 2077"
        )

        #expect(installed != uninstalled)
        #expect(installed != moved)
        #expect(uninstalled == GameDetailDiskSize.taskID(
            gameID: "1091500",
            installed: false,
            installPath: nil
        ))
    }
}
