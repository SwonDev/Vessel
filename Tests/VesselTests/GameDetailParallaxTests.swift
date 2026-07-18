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
}
