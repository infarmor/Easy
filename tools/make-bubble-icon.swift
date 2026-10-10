// Draws iGram's icon: a white speech bubble on a green gradient, in the macOS icon shape, and packs it as .icns.
//
//   swift tools/make-bubble-icon.swift [Resources/AppIcon.icns]
//
// Everything is drawn here with plain shapes (a gradient, a rounded square, an oval bubble); no artwork is copied.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")

func render(_ side: Int) -> Data {
    let size = CGFloat(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the body is 824 of 1024 points, centred, with a soft shadow under it.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = body.width * 0.2237
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor(calibratedRed: 0.1, green: 0.75, blue: 0.2, alpha: 1).setFill()
    shape.fill()
    context.restoreGState()

    // Light green at the top to deeper green at the bottom.
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.40, green: 0.95, blue: 0.47, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.74, blue: 0.19, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -90)

    // The white bubble: a wide oval with a small tail curling out at the lower left.
    let bubble = CGRect(x: body.midX - body.width * 0.31, y: body.midY - body.height * 0.23,
                        width: body.width * 0.62, height: body.height * 0.50)
    let path = NSBezierPath(ovalIn: bubble)
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: bubble.minX + bubble.width * 0.20, y: bubble.minY + bubble.height * 0.16))
    tail.curve(to: CGPoint(x: bubble.minX + bubble.width * 0.06, y: bubble.minY - bubble.height * 0.10),
               controlPoint1: CGPoint(x: bubble.minX + bubble.width * 0.19, y: bubble.minY + bubble.height * 0.02),
               controlPoint2: CGPoint(x: bubble.minX + bubble.width * 0.14, y: bubble.minY - bubble.height * 0.05))
    tail.curve(to: CGPoint(x: bubble.minX + bubble.width * 0.40, y: bubble.minY + bubble.height * 0.03),
               controlPoint1: CGPoint(x: bubble.minX + bubble.width * 0.20, y: bubble.minY - bubble.height * 0.06),
               controlPoint2: CGPoint(x: bubble.minX + bubble.width * 0.31, y: bubble.minY - bubble.height * 0.02))
    tail.close()
    // Both parts in one transparency layer: one shared shadow, no seam where the tail meets the oval.
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.004), blur: size * 0.012,
                      color: NSColor.black.withAlphaComponent(0.12).cgColor)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setFill()
    path.fill()
    tail.fill()
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("iGramIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(1) }
print("icon: \(output.path)")
