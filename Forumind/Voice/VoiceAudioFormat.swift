import AVFoundation
import Foundation

/// The audio formats of a Gemini Live session: microphone audio goes up as
/// 16 kHz PCM16 mono in 40 ms frames, the model's speech comes down as
/// 24 kHz PCM16 mono.
enum VoiceAudioFormat {
    static let captureRate: Double = 16_000
    static let playbackRate: Double = 24_000
    static let frameMilliseconds = 40
    /// One capture frame: 40 ms at 16 kHz = 640 samples = 1,280 bytes.
    static let frameSamples = 640
}

/// Converts the microphone's hardware format (usually 48 kHz Float32) to
/// the capture format: PCM16 little-endian, mono, 16 kHz.
///
/// `AVAudioConverter` does the anti-alias filtering and the rate change. A
/// rate change is not one-in-one-out, so it needs the pull API
/// (`convert(to:error:withInputFrom:)`).
final class PCMConverter {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedInputFormat(String)
        case converterUnavailable
        case conversion(String)

        var description: String {
            switch self {
            case .unsupportedInputFormat(let detail): "unsupported microphone format: \(detail)"
            case .converterUnavailable: "the system could not build an audio converter"
            case .conversion(let message): "audio conversion failed: \(message)"
            }
        }
    }

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    static func captureFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioFormat.captureRate, channels: 1, interleaved: true)!
    }

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat = PCMConverter.captureFormat()) throws {
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            // The simulator sometimes reports a 0-channel format before a
            // route settles.
            throw Failure.unsupportedInputFormat("\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // Several input channels (some routes): mix them rather than keep
        // only the first, which can be the silent one.
        if inputFormat.channelCount > 1 { converter.downmix = true }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts one tap buffer. The converter keeps its phase between
    /// calls, so a stream cut into any blocks gives the same samples.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Room for the resampler's delay.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure.conversion("could not allocate an output buffer")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw Failure.conversion(error?.localizedDescription ?? "unknown")
        @unknown default:
            throw Failure.conversion("unexpected converter status")
        }
        if let error { throw Failure.conversion(error.localizedDescription) }
        return Self.samples(of: out)
    }

    /// Drops the converter's state (after a route change: the tail is
    /// meaningless across the gap).
    func reset() { converter.reset() }

    /// The Int16 samples of an interleaved mono buffer.
    static func samples(of buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channels = buffer.int16ChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }
}

/// Cuts a stream of samples into fixed frames. The input tap hands over
/// whatever the hardware likes (about 4,096 frames at 48 kHz); this makes
/// exact 40 ms frames.
struct FrameChunker {
    let size: Int
    private var pending: [Int16] = []

    init(frameSamples: Int = VoiceAudioFormat.frameSamples) {
        size = max(1, frameSamples)
        pending.reserveCapacity(size)
    }

    /// Appends `samples` and returns every complete frame; the rest waits
    /// for the next call.
    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        var frames: [[Int16]] = []
        var offset = 0
        while offset < samples.count {
            let take = min(size - pending.count, samples.count - offset)
            pending.append(contentsOf: samples[offset..<offset + take])
            offset += take
            if pending.count == size {
                frames.append(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }

    /// Samples waiting for the next frame.
    var buffered: Int { pending.count }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

extension Array where Element == Int16 {
    /// PCM16 little-endian bytes.
    var pcm16LEData: Data {
        var out = Data(capacity: count * 2)
        for sample in self {
            let bits = UInt16(bitPattern: sample)
            out.append(UInt8(bits & 0xff))
            out.append(UInt8(bits >> 8))
        }
        return out
    }

    /// Decodes PCM16 little-endian bytes; a trailing odd byte is dropped.
    init(pcm16LE data: Data) {
        var out = [Int16]()
        out.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1])
            out.append(Int16(bitPattern: low | (high << 8)))
            index += 2
        }
        self = out
    }
}

enum PCMLevel {
    /// The largest absolute sample of a frame, in LSB.
    static func peak(of frame: [Int16]) -> Int {
        var peak = 0
        for sample in frame {
            let value = sample == Int16.min ? 32_768 : abs(Int(sample))
            if value > peak { peak = value }
        }
        return peak
    }
}
