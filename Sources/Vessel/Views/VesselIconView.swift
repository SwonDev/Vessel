import AppKit
import SwiftUI

struct VesselIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.iconImage)
            .resizable()
            .frame(width: size, height: size)
    }

    private static var iconImage: NSImage {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSApp.applicationIconImage
    }
}
