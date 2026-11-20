import AppKit
import SwiftUI

/// The services' own logos, from Resources/icons (SVG, which NSImage draws natively), in their brand colours.
@MainActor
enum BrandIcon {
    private static var svgs: [String: NSImage] = [:]
    private static var images: [String: NSImage] = [:]

    private static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["GRABIT_ICONS"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL!.appendingPathComponent("icons")
    }

    static func image(_ p: Platform, size: CGFloat = 16) -> NSImage {
        let key = "\(p.rawValue)@\(size)"
        if let cached = images[key] { return cached }
        let img: NSImage
        if let slug = p.brandIcon, let svg = svgs[slug] ?? NSImage(contentsOf: folder.appendingPathComponent(slug + ".svg")) {
            svgs[slug] = svg
            let color = p.brandColor
            // Drawn on demand, so the black logos follow Light and Dark Mode.
            img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                svg.draw(in: rect)
                (color ?? NSColor.labelColor).set()
                rect.fill(using: .sourceAtop)
                return true
            }
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.85, weight: .regular)
            img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.name)?.withSymbolConfiguration(cfg) ?? NSImage()
            img.isTemplate = true
        }
        images[key] = img
        return img
    }
}

struct PlatformIcon: View {
    let platform: Platform
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: BrandIcon.image(platform, size: size))
            .frame(width: size, height: size)
    }
}
