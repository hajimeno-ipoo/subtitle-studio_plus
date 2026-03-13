@preconcurrency import AVFoundation
import Foundation

struct WaveformService {
    func loadWaveform(url: URL, targetSamples: Int = 1800) throws -> WaveformData {
        let (file, buffer) = try loadPCMBuffer(url: url)
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
        let (file, buffer) = try loadPCMBuffer(url: url)
        let format = file.processingFormat
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

    func convertedMonoSamples(url: URL, targetSampleRate: Double) throws -> (samples: [Float], sampleRate: Double, duration: TimeInterval) {
        let (file, sourceBuffer) = try loadPCMBuffer(url: url)
        let sourceFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SubtitleStudioError.unreadableAudio
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw SubtitleStudioError.unreadableAudio
        }

        let estimatedFrameCount = Int(ceil(Double(sourceBuffer.frameLength) * targetSampleRate / sourceFormat.sampleRate))
        let frameCapacity = AVAudioFrameCount(max(estimatedFrameCount + 1, 1))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw SubtitleStudioError.unreadableAudio
        }

        let inputSource = ConverterInputSource(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputSource.isConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputSource.isConsumed = true
            outStatus.pointee = .haveData
            return inputSource.buffer
        }

        if status == .error {
            throw conversionError ?? SubtitleStudioError.unreadableAudio
        }
        guard let convertedChannel = outputBuffer.floatChannelData?.pointee else {
            throw conversionError ?? SubtitleStudioError.unreadableAudio
        }

        let frames = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: convertedChannel, count: frames))
        return (samples, outputFormat.sampleRate, file.duration)
    }

    private func loadPCMBuffer(url: URL) throws -> (file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SubtitleStudioError.unreadableAudio
        }
        try file.read(into: buffer)
        return (file, buffer)
    }
}

private final class ConverterInputSource: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var isConsumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension AVAudioFile {
    var duration: TimeInterval {
        Double(length) / processingFormat.sampleRate
    }
}
