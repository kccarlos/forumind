import XCTest
@testable import Forumind

/// A microphone that is on but delivers digital zero is noticed after 3 s
/// and cleared by the first real sample.
final class MicSignalWatchdogTests: XCTestCase {
    func testThreeSecondsOfDigitalZeroIsNoSignal() {
        var dog = MicSignalWatchdog()
        dog.arm(at: 0)
        var t = 0.0
        while t < 2.9 {
            XCTAssertNil(dog.observe(peak: 0, at: t))
            t += 0.04
        }
        XCTAssertFalse(dog.noSignal)
        XCTAssertEqual(dog.observe(peak: 0, at: 3.0), true)
        XCTAssertTrue(dog.noSignal)
        XCTAssertEqual(dog.firings, 1)
        XCTAssertNil(dog.observe(peak: 0, at: 3.5), "reported once, not every buffer")
    }

    func testAnyRealSampleClearsIt() {
        var dog = MicSignalWatchdog()
        dog.arm(at: 0)
        dog.tick(at: 4)
        XCTAssertTrue(dog.noSignal)
        XCTAssertEqual(dog.observe(peak: 1, at: 4.1), false)
        XCTAssertFalse(dog.noSignal)
    }

    func testAQuietRoomIsNotNoSignal() {
        var dog = MicSignalWatchdog()
        dog.arm(at: 0)
        var t = 0.0
        while t < 20 {
            dog.observe(peak: 3, at: t) // a real room is never exactly zero
            t += 0.04
        }
        XCTAssertNil(dog.tick(at: 20))
        XCTAssertFalse(dog.noSignal)
    }

    func testNoBuffersAtAllIsNoSignalToo() {
        var dog = MicSignalWatchdog()
        dog.arm(at: 10)
        XCTAssertNil(dog.tick(at: 12))
        XCTAssertEqual(dog.tick(at: 13.1), true)
    }

    func testPausedOrStoppedNothingIsExpected() {
        var dog = MicSignalWatchdog()
        XCTAssertNil(dog.tick(at: 100), "never armed")
        dog.arm(at: 0)
        dog.tick(at: 5)
        XCTAssertTrue(dog.noSignal)
        dog.disarm()
        XCTAssertFalse(dog.noSignal)
        XCTAssertNil(dog.observe(peak: 0, at: 50))
        XCTAssertFalse(dog.isArmed)
    }

    func testResumingRestartsTheClock() {
        var dog = MicSignalWatchdog()
        dog.arm(at: 0)
        dog.observe(peak: 500, at: 1)
        dog.disarm() // a call at 1 s
        dog.arm(at: 10) // resumed at 10 s
        XCTAssertNil(dog.tick(at: 12), "the 9 s paused do not count")
        XCTAssertEqual(dog.tick(at: 13), true)
    }
}

final class CaptureGateTests: XCTestCase {
    private func noise(_ rng: inout VADTestAudio.RNG, _ amplitude: Double = 40) -> [Int16] {
        (0 ..< VoiceAudioFormat.frameSamples).map { _ in Int16(rng.gaussian() * amplitude) }
    }

    private let tone = (0 ..< VoiceAudioFormat.frameSamples).map { Int16(8_000 * sin(2 * Double.pi * 700 * Double($0) / 16_000)) }

    func testRoomNoiseNeverOpensItAndSpeechDoes() {
        var gate = CaptureGate()
        var rng = VADTestAudio.RNG(seed: 1)
        for _ in 0 ..< 50 { XCTAssertNil(gate.push(noise(&rng, 400)).transition, "room noise well above a peak threshold") }
        XCTAssertTrue(gate.isGated)
        XCTAssertNotNil(gate.diagnostics.floorDBFS)
        var out = gate.push(tone)
        for _ in 0 ..< 2 { out = gate.push(tone) }
        XCTAssertEqual(out.transition, .opened)
        XCTAssertTrue(gate.diagnostics.isOpen)
        XCTAssertEqual(out.send.last, tone, "the pre-roll comes first, then the frame")
    }

    func testResetClosesWithoutATransitionAndKeepsTheFloor() {
        var gate = CaptureGate()
        var rng = VADTestAudio.RNG(seed: 3)
        for _ in 0 ..< 50 { gate.push(noise(&rng, 400)) }
        for _ in 0 ..< 3 { gate.push(tone) }
        XCTAssertFalse(gate.isGated)
        let floor = gate.diagnostics.floorDBFS
        gate.reset()
        XCTAssertTrue(gate.isGated)
        XCTAssertEqual(gate.diagnostics.floorDBFS, floor)
        XCTAssertNil(gate.push(noise(&rng, 400)).transition)
    }

    func testDiagnosticsFormatReadsLikeAMeter() {
        XCTAssertEqual(CaptureGate.Diagnostics.format(dBFS: -41.4), "−41 dBFS")
        XCTAssertEqual(CaptureGate.Diagnostics.format(dBFS: nil), "—")
        XCTAssertEqual(CaptureGate.Diagnostics.format(dBFS: VoiceActivityDetector.silenceDBFS), "—")
    }

    func testPeakIsTheLargestAbsoluteSample() {
        XCTAssertEqual(PCMLevel.peak(of: [0, -32_768, 5]), 32_768)
        XCTAssertEqual(PCMLevel.peak(of: [3, -7, 5]), 7)
        XCTAssertEqual(PCMLevel.peak(of: []), 0)
    }
}

final class VoiceAudioStateTests: XCTestCase {
    func testSpeakingHoldsAcrossAShortGapAndFlushEndsItAtOnce() {
        var hold = SpeakingHold()
        XCTAssertFalse(hold.update(playing: false, now: 0))
        XCTAssertTrue(hold.update(playing: true, now: 1))
        XCTAssertTrue(hold.update(playing: false, now: 2), "a gap between two chunks of one reply")
        XCTAssertTrue(hold.speaking(at: 2.7))
        XCTAssertFalse(hold.speaking(at: 2.9))
        hold.update(playing: true, now: 3)
        hold.reset()
        XCTAssertFalse(hold.update(playing: false, now: 3.1), "a flush is not a gap")
    }

    func testEchoCancellationNeedsEveryPart() {
        var status = VoiceProcessingStatus(inputEnabled: true, outputEnabled: true, voiceChatMode: true, outputRoute: "Speaker", inputRoute: "iPhone Microphone")
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.missing, [])
        status.voiceChatMode = false
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.missing, ["session not in voice-chat mode"])
        status = VoiceProcessingStatus()
        XCTAssertEqual(status.missing, ["voice processing is off", "session not in voice-chat mode"])
        let health = VoiceAudioHealth(echoCancellation: VoiceProcessingStatus(outputRoute: "Speaker", inputRoute: "iPhone Microphone"))
        XCTAssertEqual(health.route, "Speaker ← iPhone Microphone")
    }

    func testTheWatchdogRunsOnlyWhileCaptureCanDeliver() {
        XCTAssertTrue(AudioLifecycle.watchdogShouldRun(running: true, interrupted: false))
        XCTAssertFalse(AudioLifecycle.watchdogShouldRun(running: true, interrupted: true))
        XCTAssertFalse(AudioLifecycle.watchdogShouldRun(running: false, interrupted: false))
    }

    func testTheAudioFormatsAgreeWithTheWireFormat() {
        XCTAssertEqual(GeminiLive.inputSampleRate, 16_000)
        XCTAssertEqual(GeminiLive.outputSampleRate, 24_000)
        XCTAssertEqual(ComfortNoise.samplesPerFrame, VoiceAudioFormat.frameSamples)
        XCTAssertEqual(VoiceAudioFormat.frameSamples, Int(VoiceAudioFormat.captureRate) * VoiceAudioFormat.frameMilliseconds / 1000)
    }
}
