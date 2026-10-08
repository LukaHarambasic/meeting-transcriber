@testable import MeetingTranscriber
import XCTest

/// The quiet-room rule on its own: when a stop becomes due, asserted in plain
/// seconds with no loop, clock or detector involved. Whether the monitor
/// consults it at all is `WatchLoopQuietRoomTests`' job.
///
/// Each test varies one dimension and keeps the others at the values a real
/// quiet room would have, so a wrong rule fails as the one test about it.
final class QuietRoomPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let policy = QuietRoomPolicy(quietWindow: 600)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func decide(
        _ reading: MicSpeechReading,
        at seconds: TimeInterval,
        usage: MicUsage = .free,
    ) -> QuietRoomDecision {
        policy.decide(micSpeech: reading, micUsage: usage, now: at(seconds))
    }

    func testDefaultWindowIsTenMinutes() {
        XCTAssertEqual(QuietRoomPolicy().quietWindow, 600)
        XCTAssertEqual(QuietRoomPolicy().windowDescription, "10 minutes")
    }

    func testWindowDescriptionNeverReadsBelowAMinute() {
        XCTAssertEqual(QuietRoomPolicy(quietWindow: 0.5).windowDescription, "1 minute")
        XCTAssertEqual(QuietRoomPolicy(quietWindow: 90).windowDescription, "2 minutes")
    }

    // MARK: - No evidence, no stop

    func testUnavailableNeverStops() {
        XCTAssertEqual(decide(.unavailable, at: 0), .wait)
        XCTAssertEqual(decide(.unavailable, at: 3600), .wait, "no detector means no evidence, however long it has been")
    }

    func testHeldNeverStopsEvenAfterAnHourOfQuiet() {
        let reading = MicSpeechReading.listening(since: start, lastSpeech: nil)
        XCTAssertEqual(decide(reading, at: 3600, usage: .held), .wait, "another app on the microphone is a call, the call-end rule's case")
    }

    func testUnknownUsageNeverStops() {
        let reading = MicSpeechReading.listening(since: start, lastSpeech: nil)
        XCTAssertEqual(decide(reading, at: 3600, usage: .unknown), .wait)
    }

    // MARK: - The window

    func testFreeAndQuietForTheWholeWindowStops() {
        let reading = MicSpeechReading.listening(since: start, lastSpeech: nil)
        XCTAssertEqual(decide(reading, at: 601), .stopQuiet(quietFor: 601))
    }

    func testStopsExactlyAtTheWindow() {
        let reading = MicSpeechReading.listening(since: start, lastSpeech: nil)
        XCTAssertEqual(decide(reading, at: 599), .wait)
        XCTAssertEqual(decide(reading, at: 600), .stopQuiet(quietFor: 600), "inclusive, like the call-end grace")
    }

    func testSpeechNineMinutesAgoDoesNotStop() {
        let reading = MicSpeechReading.listening(since: start, lastSpeech: at(3600))
        XCTAssertEqual(decide(reading, at: 3600 + 9 * 60), .wait)
    }

    func testClockStartsWhenListeningStartedNotAtRecordingStart() {
        // The detector began listening 8 minutes into the recording: 10 minutes
        // after the recording began is only 2 observed minutes.
        let reading = MicSpeechReading.listening(since: at(480), lastSpeech: nil)
        XCTAssertEqual(decide(reading, at: 600), .wait)
        XCTAssertEqual(decide(reading, at: 480 + 600), .stopQuiet(quietFor: 600))
    }

    func testLastSpeechResetsTheClock() {
        let early = MicSpeechReading.listening(since: start, lastSpeech: nil)
        XCTAssertEqual(decide(early, at: 700), .stopQuiet(quietFor: 700))
        let spoke = MicSpeechReading.listening(since: start, lastSpeech: at(650))
        XCTAssertEqual(decide(spoke, at: 700), .wait, "speech at 650 s restarts the window")
        XCTAssertEqual(decide(spoke, at: 1250), .stopQuiet(quietFor: 600))
    }
}
