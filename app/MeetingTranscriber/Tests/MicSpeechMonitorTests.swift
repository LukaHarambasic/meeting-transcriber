import AudioTapLib
import Foundation
@testable import MeetingTranscriber
import os
import XCTest

/// Judges a chunk by its first sample (loud = speech) and counts how many it
/// has been asked about, so a test can wait for the consumer task to catch up
/// instead of sleeping. Optionally throws from the Nth chunk on.
private final class ScriptedClassifier: SpeechChunkClassifying {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let failFrom: Int?

    init(failFromCall failFrom: Int? = nil) {
        self.failFrom = failFrom
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    // swiftlint:disable:next async_without_await
    func isSpeech(_ chunk: [Float]) async throws -> Bool {
        let call = calls.withLock { count -> Int in
            count += 1
            return count
        }
        if let failFrom, call >= failFrom { throw MicSpeechTestError.noModel }
        return (chunk.first ?? 0) > 0.5
    }
}

private final class StepClock: @unchecked Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}

private let chunk = MicSpeechChunker.chunkSize

/// One 16 kHz mono buffer of exactly `chunks` model chunks, loud or silent.
private func audio(loud: Bool, chunks: Int = 1) -> LiveAudioBuffer {
    LiveAudioBuffer(
        samples: [Float](repeating: loud ? 0.9 : 0, count: chunk * chunks),
        channelCount: 1,
        sampleRate: 16000,
        hostTime: 0,
    )
}

@MainActor
final class MicSpeechMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "MicSpeechMonitorTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    // MARK: - Tracker and chunker

    func testNothingIsReportedBeforeTheFirstVerdict() {
        XCTAssertEqual(MicSpeechTracker().reading, .unavailable)
    }

    func testQuietStartReportsListeningWithNoSpeech() {
        var tracker = MicSpeechTracker()
        tracker.record(at: t0, inSpeech: false)
        tracker.record(at: t0 + 5, inSpeech: false)
        XCTAssertEqual(tracker.reading, .listening(since: t0, lastSpeech: nil))
    }

    func testSpeechAdvancesLastSpeechAndSilenceDoesNot() {
        var tracker = MicSpeechTracker()
        tracker.record(at: t0, inSpeech: false)
        tracker.record(at: t0 + 1, inSpeech: true)
        tracker.record(at: t0 + 2, inSpeech: true)
        tracker.record(at: t0 + 60, inSpeech: false)
        XCTAssertEqual(tracker.reading, .listening(since: t0, lastSpeech: t0 + 2))
    }

    func testInvalidateReturnsToNoEvidence() {
        var tracker = MicSpeechTracker()
        tracker.record(at: t0, inSpeech: true)
        tracker.invalidate()
        XCTAssertEqual(tracker.reading, .unavailable)
    }

    func testChunkerEmitsExactChunksAndCarriesTheRemainder() {
        var chunker = MicSpeechChunker()
        XCTAssertTrue(chunker.append([Float](repeating: 1, count: chunk - 1)).isEmpty)
        let first = chunker.append([Float](repeating: 2, count: chunk))
        XCTAssertEqual(first.map(\.count), [chunk])
        XCTAssertEqual(first[0][chunk - 2], 1, "the carried remainder heads the next chunk, not dropped")
        XCTAssertEqual(first[0][chunk - 1], 2)
        let rest = chunker.append([2])
        XCTAssertEqual(rest.count, 1, "the leftover chunk - 1 samples plus one more complete a chunk")
        XCTAssertEqual(rest.first?.first, 2)
    }

    // MARK: - Monitor

    private func makeMonitor(
        _ classifier: ScriptedClassifier,
        clock: StepClock,
    ) -> MicSpeechMonitor {
        MicSpeechMonitor(makeClassifier: { classifier }, now: { clock.now })
    }

    /// Poll until `condition` holds, failing with `message` at the deadline: a
    /// consumer that never runs must read as a failure, not a hang.
    private func waitUntil(
        _ message: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool,
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testReadingIsUnavailableUntilAudioHasBeenProcessed() async {
        let monitor = makeMonitor(ScriptedClassifier(), clock: StepClock(t0))
        XCTAssertEqual(monitor.reading(), .unavailable, "before begin")
        monitor.begin()
        defer { monitor.end() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            monitor.reading(), .unavailable,
            "a recording with no microphone channel delivers no buffers and must not read as an empty room",
        )
    }

    func testSpeechIsStampedAndSilenceDoesNotAdvanceIt() async {
        let clock = StepClock(t0)
        let classifier = ScriptedClassifier()
        let monitor = makeMonitor(classifier, clock: clock)
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        defer { monitor.end() }

        sink(audio(loud: true))
        await waitUntil("speech chunk never reached the reading") {
            monitor.reading() == .listening(since: t0, lastSpeech: t0)
        }

        clock.set(t0 + 90)
        sink(audio(loud: false, chunks: 3))
        await waitUntil("quiet chunks never reached the classifier") { classifier.callCount == 4 }
        XCTAssertEqual(
            monitor.reading(), .listening(since: t0, lastSpeech: t0),
            "ninety quiet seconds later the last speech must still be the first stamp",
        )

        clock.set(t0 + 120)
        sink(audio(loud: true))
        await waitUntil("later speech never advanced lastSpeech") {
            monitor.reading() == .listening(since: t0, lastSpeech: t0 + 120)
        }
    }

    func testBufferThatIsNotAWholeNumberOfChunksCarriesOver() async {
        let classifier = ScriptedClassifier()
        let monitor = makeMonitor(classifier, clock: StepClock(t0))
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        defer { monitor.end() }

        let half = LiveAudioBuffer(
            samples: [Float](repeating: 0.9, count: chunk / 2),
            channelCount: 1, sampleRate: 16000, hostTime: 0,
        )
        sink(half)
        sink(half)
        await waitUntil("two half chunks never joined into one") { classifier.callCount == 1 }
    }

    func testTeeDeliversEveryBufferToTheExistingSinkAndTheMonitor() async {
        let received = OSAllocatedUnfairLock(initialState: 0)
        let existing: LiveAudioSink = { _ in received.withLock { $0 += 1 } }
        let classifier = ScriptedClassifier()
        let monitor = makeMonitor(classifier, clock: StepClock(t0))
        let sink = monitor.sink(teeing: existing)
        monitor.begin()
        defer { monitor.end() }

        sink(audio(loud: false))
        sink(audio(loud: false))
        XCTAssertEqual(received.withLock { $0 }, 2, "captions must keep receiving every buffer")
        await waitUntil("the monitor side of the tee never saw the audio") { classifier.callCount == 2 }
    }

    func testEndDropsTheReadingAndIgnoresLaterAudio() async {
        let classifier = ScriptedClassifier()
        let monitor = makeMonitor(classifier, clock: StepClock(t0))
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        sink(audio(loud: true))
        await waitUntil("speech never registered") { monitor.reading() != .unavailable }

        monitor.end()
        XCTAssertEqual(monitor.reading(), .unavailable)
        sink(audio(loud: true))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.reading(), .unavailable, "audio after end() must not revive the reading")
    }

    func testBeginStartsAFreshSession() async {
        let clock = StepClock(t0)
        let monitor = makeMonitor(ScriptedClassifier(), clock: clock)
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        sink(audio(loud: true))
        await waitUntil("first session never heard speech") { monitor.reading() != .unavailable }

        clock.set(t0 + 600)
        monitor.begin()
        defer { monitor.end() }
        XCTAssertEqual(monitor.reading(), .unavailable, "the previous recording's speech must not carry over")
        sink(audio(loud: false))
        await waitUntil("second session never started listening") {
            monitor.reading() == .listening(since: t0 + 600, lastSpeech: nil)
        }
    }

    func testModelThatCannotLoadLeavesTheReadingUnavailable() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        // A local, not `self.t0`: the clock closure is `@Sendable`, and the
        // test class is not.
        let start: Date = t0
        let monitor = MicSpeechMonitor(
            makeClassifier: {
                attempts.withLock { $0 += 1 }
                throw MicSpeechTestError.noModel
            },
            now: { start },
        )
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        defer { monitor.end() }
        sink(audio(loud: true))
        await waitUntil("the load was never attempted") { attempts.withLock { $0 } == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.reading(), .unavailable, "no model means no evidence, never an empty room")
    }

    func testInferenceFailureMidRecordingVoidsTheReading() async {
        let classifier = ScriptedClassifier(failFromCall: 2)
        let monitor = makeMonitor(classifier, clock: StepClock(t0))
        let sink = monitor.sink(teeing: nil)
        monitor.begin()
        defer { monitor.end() }

        sink(audio(loud: true))
        await waitUntil("first chunk never registered") { monitor.reading() != .unavailable }
        sink(audio(loud: false))
        await waitUntil("a dead detector kept reporting its last verdict") { monitor.reading() == .unavailable }
    }

    // MARK: - Wiring into WatchingController

    /// The recorder factory is the only caller of the tee, so this is the test
    /// that fails if the wiring line is deleted: the recorder it hands back
    /// must carry a mic sink that reaches the monitor, and no app sink.
    func testRecorderFactoryFeedsTheMonitorFromTheMicrophoneOnly() async {
        let classifier = ScriptedClassifier()
        let monitor = MicSpeechMonitor(makeClassifier: { classifier }, now: { Date() })
        let recordingsDir = tmpDir.appendingPathComponent("recordings")
        let controller = makeWatchingController(
            logDir: tmpDir,
            makeRecorder: { DualSourceRecorder(recordingsDir: recordingsDir) },
            micSpeech: monitor,
        )
        defer { monitor.end() }

        let made = await controller.makeRecorderFactory()()
        guard let recorder = made as? DualSourceRecorder else {
            XCTFail("the factory should hand back the injected DualSourceRecorder")
            return
        }
        XCTAssertNil(recorder.appLiveSink, "system audio must never feed the speech detector")
        guard let micSink = recorder.micLiveSink else {
            XCTFail("no microphone sink was installed")
            return
        }
        micSink(audio(loud: true))
        await waitUntil("the recorder's mic sink never reached the monitor") {
            monitor.reading() != .unavailable
        }
    }

    /// Leaving `.recording` must release the detector: otherwise the next
    /// recording would inherit this one's last speech.
    func testStoppingTheRecordingEndsTheMonitor() async {
        let monitor = MicSpeechMonitor(makeClassifier: { ScriptedClassifier() }, now: { Date() })
        let controller = makeWatchingController(
            logDir: tmpDir, permissionHealth: .allHealthy, micSpeech: monitor,
        )
        monitor.begin()
        defer { monitor.end() }
        monitor.sink(teeing: nil)(audio(loud: true))
        await waitUntil("speech never registered") { monitor.reading() != .unavailable }

        controller.beginManualRecording(.meeting)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertTrue(controller.isManualRecording, "precondition: a recording is running")
        XCTAssertNotEqual(monitor.reading(), .unavailable, "starting must not clear the reading")

        controller.stopManualRecording()
        XCTAssertEqual(monitor.reading(), .unavailable)
    }

    /// The loop must be handed the monitor's reading, not a stub.
    func testTheLoopReadsTheMonitorsReading() async {
        let monitor = MicSpeechMonitor(makeClassifier: { ScriptedClassifier() }, now: { Date() })
        let controller = makeWatchingController(
            logDir: tmpDir, permissionHealth: .allHealthy, micSpeech: monitor,
        )
        monitor.begin()
        defer { monitor.end() }
        monitor.sink(teeing: nil)(audio(loud: true))
        await waitUntil("speech never registered") { monitor.reading() != .unavailable }

        controller.beginManualRecording(.meeting)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(controller.watchLoop?.micSpeech(), monitor.reading())
        XCTAssertNotEqual(controller.watchLoop?.micSpeech(), .unavailable)
    }
}
