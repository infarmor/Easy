import Foundation

/// Animated stickers (.tgs) are gzip files; Foundation's zlib codec decodes the raw deflate stream inside.
enum Gzip {
    /// A .tgs sticker is a few tens of kilobytes of Lottie JSON; anything claiming to inflate past this is a
    /// decompression bomb, not a sticker. The decoded text goes straight into Lottie, so it needs a limit here.
    static let maxOutput = 4 * 1024 * 1024

    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA: a length-prefixed extra field
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        if flags & 0x08 != 0 { offset = skipZeroTerminated(bytes, from: offset) }  // FNAME
        if flags & 0x10 != 0 { offset = skipZeroTerminated(bytes, from: offset) }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        // The stream is followed by CRC32 and the uncompressed size, 8 bytes in all.
        guard offset < bytes.count - 8 else { return nil }
        // ISIZE is the low 32 bits of the uncompressed length, little-endian, in the last four bytes.
        let tail = bytes.count - 4
        let declared = Int(bytes[tail]) | Int(bytes[tail + 1]) << 8 | Int(bytes[tail + 2]) << 16 | Int(bytes[tail + 3]) << 24
        guard declared <= Self.maxOutput else { return nil }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else { return nil }
        // ISIZE is the low 32 bits of the original length: what came out has to match what the file promised.
        guard inflated.count <= Self.maxOutput, inflated.count == declared else { return nil }
        return inflated
    }

    private static func skipZeroTerminated(_ bytes: [UInt8], from offset: Int) -> Int {
        var index = offset
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        return index + 1
    }
}
