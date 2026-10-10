import AVFoundation
import Foundation
import Observation

/// Records a voice message: 48 kHz mono from the microphone, loudness sampled for the waveform, then encoded
/// to Ogg/Opus off the main thread when the recording is sent.
@MainActor
@Observable
final class VoiceRecorder {
    struct Recording {
        var file: URL
        var duration: Int
        var waveform: Data
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// 0...1, for the pulsing dot.
    private(set) var level: Float = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var levels: [Float] = []
    @ObservationIgnored private var startedAt: Date?
    /// Kept past the moment the recorder lets go, so a take stopped by the limit can still be sent.
    @ObservationIgnored private var recordingFile: URL?
    @ObservationIgnored private var capped = false

    /// Telegram's own length for a voice message. Past it the take stops on its own: reading a ten-minute
    /// float32 .caf back in one buffer to encode it costs hundreds of megabytes.
    static let limit: TimeInterval = 180

    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftLite/outgoing", isDirectory: true)

    /// Asks for the microphone the first time; false when it is not allowed.
    func start() async -> Bool {
        guard !isRecording else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        default:
            return false
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let file = Self.folder.appendingPathComponent(UUID().uuidString + ".caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { return false }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return false }
        self.recorder = recorder
        recordingFile = recorder.url
        capped = false
        levels = []
        elapsed = 0
        startedAt = Date()
        isRecording = true
        // .common, not the default mode: the save panel and the bot's modal boxes run their own loop, and a
        // timer scheduled in the default mode stops firing while the recorder keeps recording.
        let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        meter = ticker
        return true
    }

    private func sample() {
        guard !capped, let recorder, let startedAt else { return }
        recorder.updateMeters()
        // Decibels (-160...0) to a 0...1 loudness that looks right on a waveform.
        let power = recorder.averagePower(forChannel: 0)
        let linear = max(0, min(1, pow(10, power / 20) * 3))
        levels.append(linear)
        level = linear
        elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= Self.limit else { return }
        // The bar keeps showing the take as it is: the send button still finds the file.
        capped = true
        elapsed = Self.limit
        meter?.invalidate()
        meter = nil
        recorder.stop()
    }

    func cancel() {
        let file = stopRecorder()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Stops and encodes. Nil for a recording too short to send or one that could not be encoded.
    func finish() async -> Recording? {
        let duration = elapsed
        let waveform = OggOpus.waveform(from: levels)
        guard let file = stopRecorder() else { return nil }
        guard duration >= 0.7 else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let ogg = Self.folder.appendingPathComponent(UUID().uuidString + ".ogg")
        let encoded = await Task.detached(priority: .userInitiated) { () -> Bool in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let audio = try? AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil,
                  let channel = buffer.floatChannelData?[0] else { return false }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard let data = OggOpus.encode(samples) else { return false }
            return (try? data.write(to: ogg)) != nil
        }.value
        return encoded ? Recording(file: ogg, duration: max(1, Int(duration.rounded())), waveform: waveform) : nil
    }

    /// Recordings and decoded voice notes pile up in the temporary folder and nothing ever removed them: TDLib
    /// recycles file names between launches, so a copy appeared for every voice note ever listened to, and a
    /// float32 .caf costs some 380 KB per second. Anything older than three days goes; a take being recorded or
    /// played is written moments ago, and a deleted cache copy is simply decoded again on the next listen.
    nonisolated static func purgeOldFiles(
        in root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftLite", isDirectory: true),
        olderThan: TimeInterval = 3 * 24 * 3600
    ) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate.map({ $0 < cutoff }) == true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopRecorder() -> URL? {
        meter?.invalidate()
        meter = nil
        // The capped stop above has already let go of the recorder; the take is still there to be sent.
        let file = recorder?.url ?? recordingFile
        recordingFile = nil
        recorder?.stop()
        recorder = nil
        capped = false
        isRecording = false
        level = 0
        return file
    }
}
