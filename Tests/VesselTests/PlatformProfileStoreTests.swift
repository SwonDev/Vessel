import Foundation
import Testing
@testable import Vessel

@Suite("Perfiles de plataforma")
struct PlatformProfileStoreTests {
    @Test("Steam extrae nombre Unicode y avatar del perfil público")
    func steamProfileXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <profile>
            <steamID><![CDATA[Álex Ñ]]></steamID>
            <avatarFull><![CDATA[https://avatars.example.test/user_full.jpg]]></avatarFull>
        </profile>
        """

        let profile = try #require(
            PlatformProfileStore.parseSteamCommunityProfile(Data(xml.utf8))
        )

        #expect(profile.displayName == "Álex Ñ")
        #expect(profile.avatarURL?.absoluteString == "https://avatars.example.test/user_full.jpg")
    }

    @Test("Steam rechaza respuestas sin una identidad")
    func steamProfileRequiresIdentity() {
        let xml = "<profile><avatarFull>https://example.test/avatar.jpg</avatarFull></profile>"
        #expect(PlatformProfileStore.parseSteamCommunityProfile(Data(xml.utf8)) == nil)
    }

    @Test("El perfil público no vuelve a pedir red en cada foco")
    func profileRefreshIsRateLimited() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(PlatformProfileRefreshPolicy.shouldRefresh(
            lastRefresh: nil,
            now: now,
            force: false
        ))
        #expect(!PlatformProfileRefreshPolicy.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-60),
            now: now,
            force: false
        ))
        #expect(PlatformProfileRefreshPolicy.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-PlatformProfileRefreshPolicy.minimumInterval),
            now: now,
            force: false
        ))
        #expect(PlatformProfileRefreshPolicy.shouldRefresh(
            lastRefresh: now,
            now: now,
            force: true
        ))
    }
}
