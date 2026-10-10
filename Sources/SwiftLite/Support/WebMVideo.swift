import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// Telegram's video stickers: a WebM file holding VP9 video whose transparency travels as a second VP9 stream
/// beside each frame. macOS will not play such a file — AVFoundation does not read WebM at all, and a web view
/// plays the picture but paints the transparent parts black — so the file is taken apart here and both streams
/// are decoded with VideoToolbox.
enum WebMVideo {
    struct Frame: Sendable {
        /// Milliseconds from the start.
        var time: Int
        var isKey: Bool
        var picture: Data
        /// The same moment's transparency, as a VP9 frame of its own; nil in a file without any.
        var alpha: Data?
    }

    struct Clip: Sendable {
        var width: Int
        var height: Int
        var frames: [Frame]
        /// Milliseconds one loop lasts.
        var duration: Int
    }

    // MARK: - taking the file apart

    /// Matroska ids of the handful of elements a sticker needs; everything else is stepped over.
    private enum ID {
        static let segment: UInt32 = 0x1853_8067, cluster: UInt32 = 0x1F43_B675, tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE, codec: UInt32 = 0x86, video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
        static let info: UInt32 = 0x1549_A966, timecodeScale: UInt32 = 0x2A_D7B1
        static let clusterTime: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3, blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1
        static let additions: UInt32 = 0x75A1, more: UInt32 = 0xA6, additional: UInt32 = 0xA5, referenceBlock: UInt32 = 0xFB
    }

    /// A sticker is a few hundred kilobytes; a file that claims more frames than this is not one.
    private static let maxFrames = 600

    static func parse(_ data: Data) -> Clip? {
        let bytes = [UInt8](data)
        var clip = Clip(width: 0, height: 0, frames: [], duration: 0)
        var videoTrack = 0
        var scale = 1_000_000  // nanoseconds per timecode tick; the default is a millisecond
        var clusterTime = 0

        /// An element id keeps its length marker; `end` is where the enclosing element stops.
        func readID(_ at: inout Int, _ end: Int) -> UInt32? {
            guard at < end else { return nil }
            let first = bytes[at]
            let length = first & 0x80 != 0 ? 1 : first & 0x40 != 0 ? 2 : first & 0x20 != 0 ? 3 : first & 0x10 != 0 ? 4 : 0
            guard length > 0, at + length <= end else { return nil }
            var value: UInt32 = 0
            for index in 0..<length { value = value << 8 | UInt32(bytes[at + index]) }
            at += length
            return value
        }
        /// A size drops its marker; all ones means "until the parent ends", which live streams use.
        func readSize(_ at: inout Int, _ end: Int) -> Int? {
            guard at < end else { return nil }
            let first = bytes[at]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard at + length <= end else { return nil }
            var value = Int(first) & (0xFF >> length)
            var unknown = value == (0xFF >> length)
            for index in 1..<length {
                value = value << 8 | Int(bytes[at + index])
                if bytes[at + index] != 0xFF { unknown = false }
            }
            at += length
            return unknown ? end - at : value
        }
        func number(_ range: Range<Int>) -> Int {
            range.prefix(8).reduce(0) { $0 << 8 | Int(bytes[$1]) }
        }
        /// Walks the children of one element, handing each to `visit`.
        func walk(_ range: Range<Int>, _ visit: (UInt32, Range<Int>) -> Void) {
            var at = range.lowerBound
            while at < range.upperBound {
                guard let id = readID(&at, range.upperBound), let size = readSize(&at, range.upperBound),
                      size >= 0, at + size <= range.upperBound else { return }
                visit(id, at..<(at + size))
                at += size
            }
        }
        /// A block starts with its track (as a size-style number), a signed 16-bit time and a flags byte.
        func block(_ range: Range<Int>, isSimple: Bool, isKey: Bool, alpha: Data?) {
            var at = range.lowerBound
            guard let track = readSize(&at, range.upperBound), track == videoTrack, at + 3 <= range.upperBound else { return }
            let relative = Int(Int16(bitPattern: UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])))
            let flags = bytes[at + 2]
            at += 3
            // Lacing packs several frames into one block; video never uses it, and a file that does is not read.
            guard flags & 0x06 == 0, at < range.upperBound, clip.frames.count < maxFrames else { return }
            let time = (clusterTime + relative) * scale / 1_000_000
            clip.frames.append(Frame(time: max(0, time), isKey: isSimple ? flags & 0x80 != 0 : isKey,
                                     picture: Data(bytes[at..<range.upperBound]), alpha: alpha))
        }

        walk(0..<bytes.count) { id, segment in
            guard id == ID.segment else { return }
            walk(segment) { id, body in
                switch id {
                case ID.info:
                    walk(body) { id, value in if id == ID.timecodeScale { scale = max(1, number(value)) } }
                case ID.tracks:
                    walk(body) { id, entry in
                        guard id == ID.trackEntry else { return }
                        var number_ = 0, type = 0, codec = "", width = 0, height = 0
                        walk(entry) { id, value in
                            switch id {
                            case ID.trackNumber: number_ = number(value)
                            case ID.trackType: type = number(value)
                            case ID.codec: codec = String(decoding: bytes[value], as: UTF8.self)
                            case ID.video:
                                walk(value) { id, value in
                                    if id == ID.pixelWidth { width = number(value) }
                                    if id == ID.pixelHeight { height = number(value) }
                                }
                            default: break
                            }
                        }
                        if type == 1, codec == "V_VP9", videoTrack == 0 {
                            videoTrack = number_
                            clip.width = width
                            clip.height = height
                        }
                    }
                case ID.cluster:
                    walk(body) { id, value in
                        switch id {
                        case ID.clusterTime: clusterTime = number(value)
                        case ID.simpleBlock: block(value, isSimple: true, isKey: false, alpha: nil)
                        case ID.blockGroup:
                            var payload: Range<Int>?
                            var alpha: Data?
                            var references = false
                            walk(value) { id, value in
                                switch id {
                                case ID.block: payload = value
                                case ID.referenceBlock: references = true
                                case ID.additions:
                                    walk(value) { id, value in
                                        guard id == ID.more else { return }
                                        walk(value) { id, value in if id == ID.additional { alpha = Data(bytes[value]) } }
                                    }
                                default: break
                                }
                            }
                            if let payload { block(payload, isSimple: false, isKey: !references, alpha: alpha) }
                        default: break
                        }
                    }
                default: break
                }
            }
        }
        guard videoTrack != 0, clip.width > 0, clip.height > 0, clip.width <= 4096, clip.height <= 4096,
              !clip.frames.isEmpty else { return nil }
        // The last frame is shown for as long as the ones before it were, on average.
        let last = clip.frames[clip.frames.count - 1].time
        clip.duration = clip.frames.count > 1 ? last + max(1, last / (clip.frames.count - 1)) : 1000
        return clip
    }

    // MARK: - decoding

    /// One VP9 stream. Frames must come in file order: all but the first lean on the ones before them.
    final class Decoder {
        private var session: VTDecompressionSession?
        private var format: CMVideoFormatDescription?
        private var decoded: CVPixelBuffer?

        /// macOS keeps its VP9 decoder apart from the rest; it has to be asked for once per process.
        private static let registered: Void = VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)

        init?(width: Int, height: Int) {
            _ = Self.registered
            // The "vpcC" box a container would carry: profile 0, 8 bits, 4:2:0, the rest unspecified.
            let box = Data([1, 0, 0, 0, 0, 10, 0x82, 2, 2, 2, 0, 0])
            let extensions: [CFString: Any] = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": box],
            ]
            guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_VP9, width: Int32(width),
                                                 height: Int32(height), extensions: extensions as CFDictionary,
                                                 formatDescriptionOut: &format) == noErr, let format else { return nil }
            let output: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                               imageBufferAttributes: output as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &session) == noErr, session != nil else { return nil }
        }

        deinit {
            if let session { VTDecompressionSessionInvalidate(session) }
        }

        func decode(_ frame: Data) -> CVPixelBuffer? {
            guard let session, let format else { return nil }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: frame.count, flags: 0, blockBufferOut: &block) == noErr,
                  let block,
                  frame.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                        offsetIntoDestination: 0, dataLength: frame.count) }) == noErr
            else { return nil }
            var sample: CMSampleBuffer?
            var size = frame.count
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
            decoded = nil
            // No asynchronous flag: the handler has run by the time this returns.
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                [weak self] status, _, buffer, _, _ in
                if status == noErr { self?.decoded = buffer }
            }
            return status == noErr ? decoded : nil
        }
    }

    /// Plays a clip frame by frame: the picture and its transparency decoded side by side and put together.
    final class Renderer {
        let clip: Clip
        private var picture: Decoder?
        private var alpha: Decoder?
        private var next = 0
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let hasAlpha: Bool

        init?(clip: Clip) {
            self.clip = clip
            hasAlpha = clip.frames.first?.alpha != nil
            guard restart() else { return nil }
        }

        /// A loop starts over with fresh decoders: the first frame is the only one that stands alone.
        @discardableResult
        private func restart() -> Bool {
            next = 0
            picture = Decoder(width: clip.width, height: clip.height)
            alpha = hasAlpha ? Decoder(width: clip.width, height: clip.height) : nil
            return picture != nil && (!hasAlpha || alpha != nil)
        }

        /// The frame that follows the last one given, wrapping to the start, and how many milliseconds it stays
        /// on screen; nil when it cannot be decoded.
        func nextFrame() -> (image: CGImage, hold: Int)? {
            guard let shown = nextImage() else { return nil }
            let following = next < clip.frames.count ? clip.frames[next].time : clip.duration
            // A file with broken timing must neither spin the processor nor freeze on a frame.
            return (shown.image, min(max(following - shown.time, 10), 250))
        }

        func nextImage() -> (image: CGImage, time: Int)? {
            if next >= clip.frames.count, !restart() { return nil }
            let frame = clip.frames[next]
            next += 1
            guard let colour = picture?.decode(frame.picture) else { return nil }
            var image = CIImage(cvPixelBuffer: colour)
            if let alpha, let mask = frame.alpha.flatMap({ alpha.decode($0) }) {
                // The transparency stream is a grey picture: white where the sticker is, black where it is not.
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask),
                ])
            }
            let bounds = CGRect(x: 0, y: 0, width: clip.width, height: clip.height)
            guard let rendered = context.createCGImage(image, from: bounds) else { return nil }
            return (rendered, frame.time)
        }
    }
}
