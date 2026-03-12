import AVFoundation
import Foundation

struct WaveformService {
    func loadWaveform(url: URL, targetSamples: Int = 1800) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SubtitleStudioError.unreadableAudio
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?.pointee else {
            throw SubtitleStudioError.unreadableAudio
        }

        let frames = Int(buffer.frameLength)
        let samplesPerBucket = max(1, frames / targetSamples)
        var reduced: [Float] = []
        reduced.reserveCapacity(targetSamples)

        for start in stride(from: 0, to: frames, by: samplesPerBucket) {
            let end = min(start + samplesPerBucket, frames)
            var peak: Float = 0
            if start < end {
                for index in start..<end {
                    peak = max(peak, abs(channelData[index]))
                }
            }
            reduced.append(peak)
        }

        return WaveformData(samples: reduced, duration: file.duration)
    }

    func decodedMonoSamples(url: URL) throws -> (samples: [Float], sampleRate: Double, duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SubtitleStudioError.unreadableAudio
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw SubtitleStudioError.unreadableAudio
        }
        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        var mono = Array(repeating: Float.zero, count: frames)

        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return (mono, format.sampleRate, file.duration)
    }
}

private extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / processingFormat.sampleRate
    }
}
