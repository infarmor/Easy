import AppKit
import ImageIO
import Lottie

/// Decoded pictures and animations, kept so rows scrolling back into view show them at once.
/// Decoding runs off the main thread at utility priority, which keeps it on the efficiency cores.
@MainActor
enum MediaCache {
    /// Bounded so a long session with many photos and stickers does not keep all of them in memory;
    /// the cost is the decoded bitmap size, the limit roughly 256 MB.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 1500
        return cache
    }()
    private static let animations: NSCache<NSString, LottieAnimation> = {
        let cache = NSCache<NSString, LottieAnimation>()
        cache.countLimit = 80
        return cache
    }()

    static func cachedImage(atPath path: String, pixels: Int) -> NSImage? {
        images.object(forKey: key(path, pixels))
    }

    /// Decodes straight at the size it is drawn: a 26-point avatar never holds a 640-pixel bitmap.
    static func image(atPath path: String, pixels: Int) async -> NSImage? {
        let key = key(path, pixels)
        if let cached = images.object(forKey: key) { return cached }
        // A row recycled by scrolling asks for the same picture again while its previous decode is still
        // running, and each of those cost milliseconds on the utility cores: 4.7 ms for an avatar, 18 ms for
        // a full-size photo. Like `AppModel.localFile`, everyone shares the one task in flight.
        if let running = pending[key] {
            guard let decoded = await running.value else { return nil }
            return publish(decoded, forKey: key)
        }
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        pending[key] = task
        let decoded = await task.value
        // Only the task that registered this entry ever takes it away; waiters just read the result.
        pending[key] = nil
        guard let decoded else { return nil }
        return publish(decoded, forKey: key)
    }

    private static func publish(_ decoded: CGImage, forKey key: NSString) -> NSImage {
        let image = NSImage(cgImage: decoded, size: .zero)
        images.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    /// Decodes in flight, keyed the same way as the cache. Only the task that registered itself takes the
    /// entry away, so a late return cannot drop a newer decode of the same picture.
    private static var pending: [NSString: Task<CGImage?, Never>] = [:]

    /// TDLib's inline 40-pixel JPEG shown, softly scaled, until the real photo arrives.
    static func minithumbnail(_ data: Data, id: Int) -> NSImage? {
        let key = "mini:\(id)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// .tgs stickers: gzip-compressed Lottie JSON.
    static func animation(atPath path: String) async -> LottieAnimation? {
        if let cached = animations.object(forKey: path as NSString) { return cached }
        let animation = await Task.detached(priority: .utility) { () -> LottieAnimation? in
            guard let packed = FileManager.default.contents(atPath: path), let json = Gzip.inflate(packed) else { return nil }
            return try? LottieAnimation.from(data: json)
        }.value
        if let animation { animations.setObject(animation, forKey: path as NSString) }
        return animation
    }

    private static func key(_ path: String, _ pixels: Int) -> NSString {
        "\(pixels):\(path)" as NSString
    }
}
