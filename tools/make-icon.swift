// Turns a logo on a white background into the app icon.
//
//   swift tools/make-icon.swift <logo.png|jpg> [Resources/AppIcon.icns]
//
// The white around the logo is removed by a flood fill from the picture's edges, so white inside the logo
// (highlights, letters) survives as long as an outline separates it from the background. Near-white pixels at
// the border of the fill fade out instead of being cut, which keeps the edge smooth.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <logo> [output.icns]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/AppIcon.icns")

guard let source = NSImage(contentsOf: input),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(input.path)\n".data(using: .utf8)!)
    exit(1)
}

let width = cgSource.width, height = cgSource.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
pixels.withUnsafeMutableBytes { raw in
    let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo)!
    context.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))
}

/// 0 for black ... 1 for pure white; the smallest channel decides, so light blue is not "white".
func whiteness(_ i: Int) -> Double {
    Double(min(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])) / 255
}

// Background: connected to the edge through pixels that are nearly white (JPEG noise included).
let solid = 0.86
var background = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
while let i = stack.popLast() {
    guard !background[i], whiteness(i) >= solid else { continue }
    background[i] = true
    let x = i % width, y = i / width
    if x > 0 { stack.append(i - 1) }
    if x < width - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - width) }
    if y < height - 1 { stack.append(i + width) }
}

// Background goes fully transparent; the ring of light pixels next to it keeps an alpha that falls with
// its whiteness, so the anti-aliased rim blends into whatever is behind the icon.
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = y * width + x
        var alpha = 1.0
        if background[i] {
            alpha = 0
        } else {
            let touches = (x > 0 && background[i - 1]) || (x < width - 1 && background[i + 1])
                || (y > 0 && background[i - width]) || (y < height - 1 && background[i + width])
            if touches { alpha = max(0, min(1, (1 - whiteness(i)) / (1 - 0.55))) }
        }
        for c in 0..<3 { pixels[i * 4 + c] = UInt8(Double(pixels[i * 4 + c]) * alpha) }
        pixels[i * 4 + 3] = UInt8(alpha * 255)
        if alpha > 0.05 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write("nothing left after removing the background\n".data(using: .utf8)!)
    exit(1)
}

let cutout: CGImage = pixels.withUnsafeMutableBytes { raw in
    let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo)!
    // Row 0 of the buffer is the top of the image, as it is for `cropping(to:)`.
    return context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
}

/// The logo centered on a transparent square, inside the margin macOS icons keep around their artwork.
func render(_ side: Int) -> Data {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: bitmapInfo)!
    context.interpolationQuality = .high
    let box = Double(side) * 0.84
    let scale = min(box / Double(cutout.width), box / Double(cutout.height))
    let drawn = CGSize(width: Double(cutout.width) * scale, height: Double(cutout.height) * scale)
    let origin = CGPoint(x: (Double(side) - drawn.width) / 2, y: (Double(side) - drawn.height) / 2)
    // A soft shadow under the artwork, as on the system icons.
    context.setShadow(offset: CGSize(width: 0, height: -Double(side) * 0.012), blur: Double(side) * 0.025,
                      color: CGColor(gray: 0, alpha: 0.35))
    context.draw(cutout, in: CGRect(origin: origin, size: drawn))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// The transparent master next to the icon, handy for the login screen or a README.
try render(1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(1) }
print("icon: \(output.path)")
