// Draws Easy's icon: a white ghost that is also a speech bubble, on indigo, in the macOS icon shape,
// and packs it as .icns.
//
//   swift tools/make-ghost-icon.swift [Resources/AppIcon.icns]
//
// Everything is drawn here with plain shapes (a gradient, a rounded square, arcs and ovals); no artwork is copied.
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

    // Indigo, lighter at the top: a colour of its own in the Dock, apart from the blue and green messengers.
    let top = NSColor(srgbRed: 0x7B / 255, green: 0x6C / 255, blue: 1, alpha: 1)
    let bottom = NSColor(srgbRed: 0x3B / 255, green: 0x27 / 255, blue: 0xC9 / 255, alpha: 1)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    bottom.setFill()
    shape.fill()
    context.restoreGState()

    shape.addClip()
    NSGradient(colors: [top, bottom])!.draw(in: body, angle: -90)

    // The ghost is laid out on a 256-point grid with y running down, then placed over the body.
    let grid = CGAffineTransform(translationX: body.minX, y: body.maxY + body.height * 4 / 256)
        .scaledBy(x: body.width / 256, y: -body.height / 256)
    let ghost = CGMutablePath()
    ghost.move(to: CGPoint(x: 56, y: 114), transform: grid)
    ghost.addArc(tangent1End: CGPoint(x: 56, y: 42), tangent2End: CGPoint(x: 128, y: 42), radius: 72, transform: grid)
    ghost.addArc(tangent1End: CGPoint(x: 200, y: 42), tangent2End: CGPoint(x: 200, y: 114), radius: 72, transform: grid)
    ghost.addLine(to: CGPoint(x: 200, y: 190), transform: grid)
    // Two round feet, then the hem runs out into a bubble's tail at the lower left.
    for right in [CGFloat(200), 152] {
        ghost.addArc(tangent1End: CGPoint(x: right, y: 214), tangent2End: CGPoint(x: right - 24, y: 214), radius: 24, transform: grid)
        ghost.addArc(tangent1End: CGPoint(x: right - 48, y: 214), tangent2End: CGPoint(x: right - 48, y: 190), radius: 24, transform: grid)
    }
    ghost.addLine(to: CGPoint(x: 56, y: 222), transform: grid)
    ghost.closeSubpath()
    // The eyes are holes, so the indigo shows through them.
    ghost.addEllipse(in: CGRect(x: 92, y: 98, width: 24, height: 32), transform: grid)
    ghost.addEllipse(in: CGRect(x: 140, y: 98, width: 24, height: 32), transform: grid)

    context.setShadow(offset: CGSize(width: 0, height: -size * 0.004), blur: size * 0.012,
                      color: NSColor.black.withAlphaComponent(0.12).cgColor)
    context.addPath(ghost)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath(using: .evenOdd)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("EasyIcon-\(UUID().uuidString).iconset")
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
