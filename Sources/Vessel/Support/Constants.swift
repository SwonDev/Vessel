import Foundation

enum VesselPaths {
    static let appSupport: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/Vessel"
    }()

    static let bottlesDirectory: String = "\(appSupport)/Bottles"
    static let enginesDirectory: String = "\(appSupport)/Engines"
    static let cacheDirectory: String = "\(appSupport)/Cache"

    static func ensureDirectories() {
        let paths = [appSupport, bottlesDirectory, enginesDirectory, cacheDirectory]
        for path in paths {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}

enum SteamConstants {
    static let setupURL = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Vessel/0.1"
}
