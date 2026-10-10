import AVFoundation
import Foundation
import Observation

/// Plays one voice message at a time, like the official clients: starting another stops the current one.
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    private(set) var currentFileId: Int?
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    /// 0...1 of the message that is loaded; read by the waveform while it redraws.
    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    var elapsed: TimeInterval { player?.currentTime ?? 0 }

    func play(_ url: URL, fileId: Int) {
        player?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        currentFileId = fileId
        isPlaying = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
    }

    func stop() {
        player?.stop()
        player = nil
        currentFileId = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // AVAudioPlayer does not promise the main thread for this callback. By the time it runs another
        // message may have started; only the player that finished is reset.
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            isPlaying = false
            current.currentTime = 0
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == failed else { return }
            stop()
        }
    }
}
