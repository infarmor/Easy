import AppKit
import Foundation

/// Crops a rectangle out of a PNG so a region of a rendered snapshot can be looked at closely. Coordinates
/// are in points from the top left; the file's own scale is applied, so a Retina capture crops as expected.
///     swift tools/crop.swift <png> <x> <y> <w> <h> <out.png>
let arguments = CommandLine.arguments
// `swift tools/crop.swift …` puts the script itself in arguments[0], so the six values start at 1.
guard arguments.count == 7,
      let x = Double(arguments[2]), let y = Double(arguments[3]),
      let width = Double(arguments[4]), let height = Double(arguments[5]),
      let image = NSImage(contentsOfFile: arguments[1]),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: crop.swift <png> <x> <y> <w> <h> <out.png>")
    exit(2)
}
let scale = CGFloat(source.width) / image.size.width
guard let cropped = source.cropping(to: CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale,
                                               width: CGFloat(width) * scale, height: CGFloat(height) * scale))
else { print("nothing at that rectangle"); exit(1) }
let representation = NSBitmapImageRep(cgImage: cropped)
guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: arguments[6]))
print("wrote \(arguments[6]) \(cropped.width)x\(cropped.height)")
