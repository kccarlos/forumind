import AVFoundation
import XCTest
@testable import Forumind

/// The sample-rate path, with a synthetic signal instead of a microphone:
/// 48 kHz Float32 in, 16 kHz PCM16 out, the tone still where it was.
final class PCMConverterTests: XCTestCase {
    private func converter(inputRate: Double, channels: AVAudioChannelCount = 1) throws -> PCMConverter {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: channels, interleaved: false)!
        return try PCMConverter(inputFormat: format)
    }

    func testFortyEightToSixteenKeepsLengthRatioAndFrequency() throws {
        let converter = try converter(inputRate: 48_000)
        let sine = try XCTUnwrap(PCMConverter.sineBuffer(frequency: 440, sampleRate: 48_000, seconds: 1.0))
        let out = try converter.convert(sine)

        // 3:1 — one second in, one second out. The converter's own delay
        // costs a handful of samples on the first call.
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 200, "expected ≈16 000 samples, got \(out.count)")

        // The tone is still 440 Hz and nothing appeared at 1 320 Hz.
        let atTone = PCMConverter.toneMagnitude(out, frequency: 440, sampleRate: 16_000)
        let offTone = PCMConverter.toneMagnitude(out, frequency: 1_320, sampleRate: 16_000)
        XCTAssertGreaterThan(atTone, 0.1, "the 440 Hz tone should survive the rate change")
        XCTAssertLessThan(offTone, atTone / 10, "nothing should appear at 1 320 Hz")
    }

    func testContentAboveTheNewNyquistIsFilteredRatherThanAliased() throws {
        let converter = try converter(inputRate: 48_000)
        // 12 kHz is above 16 kHz's 8 kHz Nyquist; without an anti-alias
        // filter it would fold down to 4 kHz.
        let sine = try XCTUnwrap(PCMConverter.sineBuffer(frequency: 12_000, sampleRate: 48_000, seconds: 0.5))
        let out = try converter.convert(sine)
        let folded = PCMConverter.toneMagnitude(out, frequency: 4_000, sampleRate: 16_000)
        XCTAssertLessThan(folded, 0.02, "12 kHz must not alias down to 4 kHz")
    }

    func testStreamingInBlocksMatchesOneBigCall() throws {
        let whole = try converter(inputRate: 48_000)
        let blocks = try converter(inputRate: 48_000)
        let sine = try XCTUnwrap(PCMConverter.sineBuffer(frequency: 440, sampleRate: 48_000, seconds: 0.5))
        let reference = try whole.convert(sine)

        // The same signal handed over in 4 096-frame tap buffers.
        let format = sine.format
        var streamed: [Int16] = []
        var offset = 0
        let source = sine.floatChannelData![0]
        while offset < Int(sine.frameLength) {
            let take = min(4_096, Int(sine.frameLength) - offset)
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(take))!
            block.frameLength = AVAudioFrameCount(take)
            block.floatChannelData![0].update(from: source + offset, count: take)
            streamed += try blocks.convert(block)
            offset += take
        }
        XCTAssertEqual(Double(streamed.count), Double(reference.count), accuracy: 64)
        let streamedTone = PCMConverter.toneMagnitude(streamed, frequency: 440, sampleRate: 16_000)
        XCTAssertGreaterThan(streamedTone, 0.1, "phase must be kept across blocks")
    }

    func testFortyFourOneKilohertzHardwareAlsoWorks() throws {
        let converter = try converter(inputRate: 44_100)
        let sine = try XCTUnwrap(PCMConverter.sineBuffer(frequency: 440, sampleRate: 44_100, seconds: 0.5))
        let out = try converter.convert(sine)
        XCTAssertEqual(Double(out.count), 8_000, accuracy: 200)
        XCTAssertGreaterThan(PCMConverter.toneMagnitude(out, frequency: 440, sampleRate: 16_000), 0.1)
    }

    func testOneFortyMillisecondFrameIsSixHundredAndFortySamples() throws {
        let converter = try converter(inputRate: 48_000)
        let sine = try XCTUnwrap(PCMConverter.sineBuffer(frequency: 440, sampleRate: 48_000, seconds: 2.0))
        var chunker = FrameChunker()
        let frames = chunker.push(try converter.convert(sine))
        // 2 s at 40 ms per frame, minus the converter's own delay on the
        // first call (a few dozen samples).
        XCTAssertTrue((49 ... 50).contains(frames.count), "got \(frames.count) frames")
        XCTAssertLessThan(chunker.buffered, VoiceAudioFormat.frameSamples)
        XCTAssertTrue(frames.allSatisfy { $0.pcm16LEData.count == 1_280 })
    }

    func testAZeroChannelFormatIsRefusedWithAPlainMessage() throws {
        // The simulator sometimes hands out a 0 ch / 0 Hz input format before
        // a route settles. It must read as a sentence, not a trap.
        var description = AudioStreamBasicDescription()
        let empty = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        XCTAssertEqual(empty.channelCount, 0)
        XCTAssertThrowsError(try PCMConverter(inputFormat: empty)) { error in
            guard case let PCMConverter.Failure.unsupportedInputFormat(detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(detail.contains("0 ch"))
            XCTAssertTrue("\(PCMConverter.Failure.unsupportedInputFormat(detail))".hasPrefix("unsupported microphone format"))
        }
    }
}

final class FrameChunkerTests: XCTestCase {
    func testEmitsFixedFramesAndKeepsTheRemainder() {
        var chunker = FrameChunker(frameSamples: 640)
        // A 48 kHz tap buffer of 4 096 frames becomes ~1 365 samples at
        // 16 kHz: two whole frames and a remainder.
        let frames = chunker.push([Int16](repeating: 1, count: 1_365))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.count == 640 })
        XCTAssertEqual(chunker.buffered, 85)

        let more = chunker.push([Int16](repeating: 2, count: 1_365))
        XCTAssertEqual(more.count, 2)
        XCTAssertEqual(chunker.buffered, 170)
        // The remainder leads the next frame: sample order is preserved.
        XCTAssertEqual(more[0][0], 1)
        XCTAssertEqual(more[0][85], 2)
    }

    func testSampleOrderSurvivesArbitraryBlockSizes() {
        var chunker = FrameChunker(frameSamples: 4)
        var out: [Int16] = []
        for block in [[Int16(1)], [2, 3], [4, 5, 6, 7], [8]] {
            for frame in chunker.push(block) { out += frame }
        }
        XCTAssertEqual(out, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testPCM16LittleEndianRoundTrip() {
        let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 256]
        let data = samples.pcm16LEData
        XCTAssertEqual(data.count, samples.count * 2)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual([Int16](pcm16LE: data), samples)
    }

    func testATrailingOddByteIsDropped() {
        var data = [Int16(7), 8].pcm16LEData
        data.append(0x33)
        XCTAssertEqual([Int16](pcm16LE: data), [7, 8])
    }
}

// MARK: Signal generators

extension PCMConverter {
    /// A mono Float32 buffer holding `seconds` of a sine.
    static func sineBuffer(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let step = 2.0 * Double.pi * frequency / sampleRate
        for i in 0 ..< Int(frames) {
            data[0][i] = amplitude * Float(sin(step * Double(i)))
        }
        return buffer
    }

    /// The Goertzel magnitude of `frequency` in `samples`.
    static func toneMagnitude(_ samples: [Int16], frequency: Double, sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let k = 2.0 * cos(2.0 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let value = Double(sample) / 32_768.0
            let s0 = value + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return sqrt(max(0, power)) / Double(samples.count)
    }
}
