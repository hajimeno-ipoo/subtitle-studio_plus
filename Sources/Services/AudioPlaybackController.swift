import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackController {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var volume: Double = 1
    var isMuted = false

    func load(url: URL) throws {
        stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        applyVolume()
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        timer?.invalidate()
        timer = nil
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player?.currentTime = clamped
        currentTime = clamped
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(value, 1))
        if volume > 0 {
            isMuted = false
        }
        applyVolume()
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
    }

    private func applyVolume() {
        player?.volume = Float(isMuted ? 0 : volume)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: TimerProxy { [weak self] in
            self?.handleTimerTick()
        }, selector: #selector(TimerProxy.fire), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func handleTimerTick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
            timer = nil
        }
    }
}

private final class TimerProxy: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        action()
    }
}
