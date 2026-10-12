import AppKit
import ImageIO
import SwiftUI

/// The app's colour, taken from the desktop picture when the setting asks for it: its dominant hue, at the
/// depth the indigo has, so white still reads on fills and the ink still reads on dark ground.
@MainActor
@Observable
final class Theme {
    static let shared = Theme()

    /// Goes up when the colour changes. Colours are resolved once per view, so the window is rebuilt on it.
    private(set) var revision = 0

    /// The hue in use, 0…1; nil for the app's own indigo. Read by the colour providers, which AppKit calls
    /// from wherever it draws.
    nonisolated(unsafe) private(set) static var hue: CGFloat?
    /// How much of that hue is used: 1 for a picture with colour, close to 0 for a black-and-white one, where
    /// the app goes graphite rather than keep a purple the desktop has nothing to do with.
    nonisolated(unsafe) private(set) static var strength: CGFloat = 1

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Reads the picture again. Cheap enough to do whenever the app comes forward: a 48-pixel thumbnail.
    func refresh() {
        let wanted = UserDefaults.standard.object(forKey: Preferences.wallpaperColors) as? Bool ?? true
        let read = wanted ? Self.wallpaperTone() : nil
        let next = read?.hue, strength = read?.strength ?? 1
        let old = Self.hue
        // The same picture gives the same hue; a hair's difference is not worth rebuilding the window for.
        if let next, let old, min(abs(next - old), 1 - abs(next - old)) < 0.02, strength == Self.strength { return }
        if next == nil, old == nil { return }
        Self.hue = next
        Self.strength = strength
        revision += 1
    }

    /// The hue most of the picture's colour sits at, and how much of it to use: every pixel votes with its saturation and brightness, so
    /// grey and near-black areas do not pull the answer. nil for a picture with no colour to speak of, or one
    /// that cannot be read (the sandbox lets the app into few folders).
    private static func wallpaperTone() -> (hue: CGFloat, strength: CGFloat)? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
              ] as CFDictionary) else { return nil }
        let width = small.width, height = small.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0.0, y = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b), spread = high - low
            guard spread > 0.08 else { continue }
            var hue: Double
            if high == r { hue = (g - b) / spread } else if high == g { hue = 2 + (b - r) / spread } else { hue = 4 + (r - g) / spread }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let vote = (spread / high) * high
            x += cos(hue * 2 * .pi) * vote
            y += sin(hue * 2 * .pi) * vote
            weight += vote
        }
        // Too little colour in the picture, or colours pulling evenly in every direction: graphite, with a
        // breath of cool blue so it does not read as plain grey.
        guard weight > Double(width * height) * 0.03, (x * x + y * y).squareRoot() > weight * 0.2 else { return (0.62, 0.12) }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (CGFloat(hue), 1)
    }
}
