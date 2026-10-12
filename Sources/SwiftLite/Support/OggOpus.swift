import AVFoundation
import Foundation

/// Telegram voice messages are Opus in an Ogg container. Core Audio decodes Opus but does not read Ogg
/// on every supported macOS, so the container is unpacked here and the packets go to the system decoder.
enum OggOpus {
    struct Stream {
        var channels: Int
        /// Samples the encoder put in front that are not part of the recording.
        var preSkip: Int
        var packets: [Data]
    }

    /// Splits Ogg pages into packets; the first is OpusHead, the second OpusTags, the rest audio.
    static func demux(_ data: Data) -> Stream? {
        let bytes = [UInt8](data)
        var offset = 0
        var packets: [Data] = []
        var pending: [UInt8] = []

        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                return nil
            }
            let segmentCount = Int(bytes[offset + 26])
            var position = offset + 27 + segmentCount
            // A voice note that is still downloading has its last page cut mid-segment; the pages before it are
            // complete, so playing what arrived beats refusing the whole file.
            guard position <= bytes.count else { break }
            var truncated = false
            for index in 0..<segmentCount {
                let length = Int(bytes[offset + 27 + index])
                guard position + length <= bytes.count else { truncated = true; break }
                pending.append(contentsOf: bytes[position..<position + length])
                position += length
                // A segment shorter than 255 bytes ends the packet; 255 continues it, even onto the next page.
                if length < 255 {
                    packets.append(Data(pending))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            offset = position
            if truncated { break }
        }

        guard packets.count >= 2, packets[0].count >= 19, packets[0].starts(with: Array("OpusHead".utf8)) else { return nil }
        let head = [UInt8](packets[0])
        // Opus in Ogg: version 1, mapping family 0, and one or two channels. Anything else comes from a file we
        // did not write — the channel count is handed to AudioToolbox and sizes the sample buffers, so a lie of
        // 200 channels is a huge allocation before the first sample is even looked at.
        let channels = Int(head[9])
        guard head[8] == 1, head[18] == 0, channels == 1 || channels == 2 else { return nil }
        return Stream(
            channels: channels,
            preSkip: Int(head[10]) | Int(head[11]) << 8,
            packets: Array(packets.dropFirst(2))
        )
    }

    /// Decodes the whole stream to 48 kHz float PCM; a voice message is short enough to hold in memory.
    static func decode(_ stream: Stream) -> AVAudioPCMBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(stream.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: AVAudioChannelCount(stream.channels), interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }

        var samples = [[Float]](repeating: [], count: stream.channels)
        var next = 0
        // An Opus packet holds at most 120 ms.
        guard let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 5760) else { return nil }

        while true {
            chunk.frameLength = 0
            var failure: NSError?
            let status = converter.convert(to: chunk, error: &failure) { _, state in
                guard next < stream.packets.count else {
                    state.pointee = .endOfStream
                    return nil
                }
                let packet = stream.packets[next]
                next += 1
                let buffer = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: max(packet.count, 1))
                packet.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { buffer.data.copyMemory(from: base, byteCount: packet.count) }
                }
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
                )
                buffer.packetCount = 1
                buffer.byteLength = UInt32(packet.count)
                state.pointee = .haveData
                return buffer
            }
            if let channels = chunk.floatChannelData, chunk.frameLength > 0 {
                for channel in 0..<stream.channels {
                    samples[channel].append(contentsOf: UnsafeBufferPointer(start: channels[channel], count: Int(chunk.frameLength)))
                }
            }
            if status == .endOfStream || status == .error || failure != nil { break }
            if status == .inputRanDry && next >= stream.packets.count { break }
        }

        let skip = min(stream.preSkip, samples[0].count)
        let frames = samples[0].count - skip
        guard frames > 0, let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)),
              let target = result.floatChannelData else { return nil }
        for channel in 0..<stream.channels {
            samples[channel].withUnsafeBufferPointer { source in
                target[channel].update(from: source.baseAddress! + skip, count: frames)
            }
        }
        result.frameLength = AVAudioFrameCount(frames)
        return result
    }

    // MARK: - encoding

    /// Encodes 48 kHz mono float samples as an Ogg/Opus voice message. Nil when the system has no Opus encoder.
    static func encode(_ samples: [Float], bitRate: Int = 32_000) -> Data? {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.bitRate = bitRate

        let chunkSize = 4800
        var offset = 0
        var packets: [Data] = []
        let buffer = AVAudioCompressedBuffer(format: output, packetCapacity: 32, maximumPacketSize: 1500)
        while true {
            buffer.packetCount = 0
            buffer.byteLength = 0
            var failure: NSError?
            let status = converter.convert(to: buffer, error: &failure) { _, state in
                guard offset < samples.count else {
                    state.pointee = .endOfStream
                    return nil
                }
                let count = min(chunkSize, samples.count - offset)
                guard let chunk = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count)) else {
                    state.pointee = .endOfStream
                    return nil
                }
                samples.withUnsafeBufferPointer { source in
                    chunk.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
                }
                chunk.frameLength = AVAudioFrameCount(count)
                offset += count
                state.pointee = .haveData
                return chunk
            }
            if let descriptions = buffer.packetDescriptions {
                for index in 0..<Int(buffer.packetCount) {
                    let packet = descriptions[index]
                    packets.append(Data(bytes: buffer.data + Int(packet.mStartOffset), count: Int(packet.mDataByteSize)))
                }
            }
            if status == .endOfStream || status == .error || failure != nil { break }
        }
        guard !packets.isEmpty else { return nil }
        let leading = Int(converter.primeInfo.leadingFrames)
        return mux(packets, preSkip: leading > 0 ? leading : 312)
    }

    /// Wraps 20 ms Opus packets in Ogg pages: OpusHead, OpusTags, then the audio with granule positions.
    static func mux(_ packets: [Data], preSkip: Int, serial: UInt32 = .random(in: 1...UInt32.max)) -> Data {
        var file = Data()
        var sequence: UInt32 = 0
        func page(_ payload: [Data], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            for packet in payload {
                var length = packet.count
                while length >= 255 { lacing.append(255); length -= 255 }
                lacing.append(UInt8(length))
            }
            var header = Data("OggS".utf8)
            header.append(0)
            header.append(flags)
            withUnsafeBytes(of: granule.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: serial.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: sequence.littleEndian) { header.append(contentsOf: $0) }
            header.append(contentsOf: [0, 0, 0, 0])
            header.append(UInt8(lacing.count))
            header.append(contentsOf: lacing)
            var pageData = header
            for packet in payload { pageData.append(packet) }
            let crc = oggCRC(pageData)
            withUnsafeBytes(of: crc.littleEndian) { pageData.replaceSubrange(22..<26, with: $0) }
            file.append(pageData)
            sequence += 1
        }

        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(1)
        withUnsafeBytes(of: UInt16(preSkip).littleEndian) { head.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(48_000).littleEndian) { head.append(contentsOf: $0) }
        head.append(contentsOf: [0, 0, 0])
        page([head], granule: 0, flags: 0x02)

        var tags = Data("OpusTags".utf8)
        let vendor = Data("Easy".utf8)
        withUnsafeBytes(of: UInt32(vendor.count).littleEndian) { tags.append(contentsOf: $0) }
        tags.append(vendor)
        tags.append(contentsOf: [0, 0, 0, 0])
        page([tags], granule: 0, flags: 0)

        // 50 packets (one second) per page keeps each page well under the 255 lacing values.
        var granule = Int64(preSkip)
        var index = 0
        while index < packets.count {
            let slice = Array(packets[index..<min(index + 50, packets.count)])
            index += slice.count
            granule += Int64(slice.count * 960)
            page(slice, granule: granule, flags: index >= packets.count ? 0x04 : 0)
        }
        return file
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value) << 24
        for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        return crc
    }

    /// The Ogg checksum: CRC-32 with polynomial 0x04C11DB7, not reflected, over the page with its CRC field zero.
    static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte))] }
        return crc
    }

    /// Telegram's waveform: 100 values of 5 bits, packed low bit first.
    static func waveform(from levels: [Float], count: Int = 100) -> Data {
        guard !levels.isEmpty else { return Data(count: (count * 5 + 7) / 8) }
        let peak = max(levels.max() ?? 1, 0.0001)
        var values: [UInt8] = []
        for index in 0..<count {
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            let slice = levels[start..<min(end, levels.count)]
            let level = (slice.max() ?? 0) / peak
            values.append(UInt8(min(31, max(0, Int((level * 31).rounded())))))
        }
        var bytes = [UInt8](repeating: 0, count: (count * 5 + 7) / 8)
        for (index, value) in values.enumerated() {
            for bit in 0..<5 where value & (1 << bit) != 0 {
                let position = index * 5 + bit
                bytes[position / 8] |= 1 << (position % 8)
            }
        }
        return Data(bytes)
    }

    /// Decodes an .oga file once and keeps a playable CAF copy with the other temporary files. TDLib file ids
    /// change between launches, so the copy is named after the source file and its size.
    static func playableFile(for source: URL) -> URL? {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftLite/voice", isDirectory: true)
        let target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(size).caf")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe), let stream = demux(data),
              let pcm = decode(stream) else { return nil }
        // Written under a temporary name and moved in place, so a half-written file is never taken for a
        // finished one by a second view asking at the same time. 16-bit samples are plenty for speech.
        let partial = folder.appendingPathComponent(UUID().uuidString + ".caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: pcm.format.sampleRate,
            AVNumberOfChannelsKey: pcm.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // The file is closed when this scope releases it, before the move.
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: partial, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: pcm)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return FileManager.default.fileExists(atPath: target.path) ? target : nil
        }
        return target
    }
}
