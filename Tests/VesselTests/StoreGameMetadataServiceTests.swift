import Foundation
import Testing
import SwiftUI
import AppKit
@testable import Vessel

struct StoreGameMetadataServiceTests {
    @Test("Steam parsea capturas, vídeos y metadatos públicos")
    func parsesSteamPreviewMetadata() throws {
        let payload = """
        {
          "42": {
            "success": true,
            "data": {
              "short_description": "Un <b>juego</b> &amp; aventura.",
              "developers": ["Estudio"],
              "genres": [{"description": "Acción"}],
              "release_date": {"date": "16 jul 2026"},
              "metacritic": {"score": 88},
              "screenshots": [
                {
                  "path_thumbnail": "https://cdn.example.com/thumb.jpg",
                  "path_full": "https://cdn.example.com/full.jpg"
                }
              ],
              "movies": [
                {
                  "id": 7,
                  "name": "Tráiler",
                  "thumbnail": "https://cdn.example.com/poster.jpg",
                  "mp4": {"480": "https://cdn.example.com/trailer.mp4"}
                },
                {
                  "id": 8,
                  "name": "URL insegura",
                  "mp4": {"480": "http://cdn.example.com/insecure.mp4"}
                }
              ]
            }
          }
        }
        """

        let details = try #require(StoreGameMetadataService.parseSteamPayload(Data(payload.utf8), appId: "42"))
        #expect(details.description == "Un juego & aventura.")
        #expect(details.developers == ["Estudio"])
        #expect(details.genres == ["Acción"])
        #expect(details.metacritic == 88)
        #expect(details.screenshotsFull.map(\.absoluteString) == ["https://cdn.example.com/full.jpg"])
        #expect(details.movies.count == 1)
        #expect(details.movies.first?.name == "Tráiler")
        #expect(details.movies.first?.videoURL.absoluteString == "https://cdn.example.com/trailer.mp4")
    }

    @Test("Steam parsea y traduce el veredicto público de reseñas")
    func parsesSteamReviewSummary() throws {
        let payload = """
        {
          "success": 1,
          "query_summary": {
            "review_score_desc": "Overwhelmingly Positive",
            "total_reviews": 232158
          }
        }
        """

        #expect(StoreGameMetadataService.parseSteamReviewSummaryPayload(Data(payload.utf8))
                == "Extremadamente positivas")
        #expect(StoreGameMetadataService.parseSteamReviewSummaryPayload(Data("{}".utf8)) == nil)
    }

    @Test("GOG normaliza URLs de imagen relativas al protocolo")
    func parsesGogScreenshots() throws {
        let payload = """
        {
          "description": {"lead": "<p>Una aventura.</p>"},
          "screenshots": [
            {"formatter_template_url": "//images.gog-statics.com/abc_{formatter}.jpg"}
          ]
        }
        """

        let details = try #require(StoreGameMetadataService.parseGogPayload(Data(payload.utf8)))
        #expect(details.description == "Una aventura.")
        #expect(details.screenshots.first?.absoluteString == "https://images.gog-statics.com/abc_ggvgm_2x.jpg")
        #expect(details.screenshotsFull.first?.absoluteString == "https://images.gog-statics.com/abc_ggvgl_2x.jpg")
    }

    @Test("La coincidencia por título es estricta pero tolera marcas y ediciones")
    func normalizesStoreTitles() {
        #expect(StoreGameMetadataService.normalizedTitle("The Vampire Crawlers™: Deluxe Edition")
                == StoreGameMetadataService.normalizedTitle("Vampire Crawlers"))
        #expect(StoreGameMetadataService.normalizedTitle("Vampire Crawlers II") != "vampirecrawlers")
    }

    @Test("Los enlaces externos solo se crean con un identificador de Steam válido")
    func validatesExternalStoreLinks() {
        let valid = StoreGame(id: "steam-570", title: "Dota 2", steamAppId: "570")
        #expect(valid.steamStoreURL?.absoluteString == "https://store.steampowered.com/app/570")
        #expect(valid.protonDBURL?.absoluteString == "https://www.protondb.com/app/570")

        let invalid = StoreGame(id: "epic-offer", title: "Juego", steamAppId: "offer/../../bad")
        #expect(invalid.steamStoreURL == nil)
        #expect(invalid.protonDBURL == nil)
    }

    @MainActor
    @Test("El panel Liquid Glass se renderiza con su tamaño contractual")
    func rendersHoverPreviewPanel() throws {
        let game = StoreGame(
            id: "preview-test",
            title: "Vampire Crawlers",
            installed: true,
            lastPlayed: Date(timeIntervalSince1970: 1_789_000_000),
            playtimeMinutes: 92
        )
        var details = StoreGameMetadata()
        details.description = "Una aventura de acción creada para comprobar la composición del panel."
        details.genres = ["Acción", "Roguelike", "Cartas"]
        details.metacritic = 88

        let view = GameHoverPreviewView(
            game: game,
            store: .steam,
            tint: StoreKind.steam.tint,
            initialDetails: details,
            loadsRemoteDetails: false
        )

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(GameHoverPreviewView.panelSize)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == GameHoverPreviewView.panelSize)

        if let output = ProcessInfo.processInfo.environment["VESSEL_HOVER_SNAPSHOT"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: output), options: Data.WritingOptions.atomic)
        }
    }
}
