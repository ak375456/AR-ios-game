//
//  CoinSound.swift
//  vr
//
//  The pickup chime for road coins.
//

import AVFoundation

/// Plays `CoinPickup.caf` with no start-up delay.
///
/// A small pool of preloaded players lets quick pickups overlap instead of
/// cutting each other off. The ambient session mixes with the user's music
/// and follows the silent switch, like any casual game effect.
@MainActor
final class CoinSound {

    private var players: [AVAudioPlayer] = []
    private var next = 0

    init() {
        guard let url = Bundle.main.url(forResource: "CoinPickup", withExtension: "caf") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        players = (0..<3).compactMap { _ in
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            return player
        }
    }

    /// A rare coin chimes twice, a little brighter.
    func play(rare: Bool) {
        chime(volume: rare ? 1 : 0.75)
        guard rare else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            self?.chime(volume: 0.8)
        }
    }

    private func chime(volume: Float) {
        guard !players.isEmpty else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.volume = volume
        player.currentTime = 0
        player.play()
    }
}
