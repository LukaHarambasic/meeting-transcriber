import Foundation
@testable import MeetingTranscriber
import XCTest

/// Transcription engine that parks inside `transcribeSegments` until the test
/// releases it. Lets a test hold one pipeline run mid-stage, past the point
/// where it has written its intermediate 16 kHz files, while a second run of
/// the same job is driven to completion. That is the only way to observe how
/// two concurrent runs treat each other's working files.
///
/// Callers wait for `isParked` via `waitFor` rather than a second continuation,
/// so a run that regresses and never reaches transcription fails the test on
/// the timeout instead of hanging the suite.
///
/// The parked side is bounded too. A test that leaves the scope between parking
/// and `release()` (a thrown error, a failed `try`) would otherwise leave the
/// run parked forever, and an `async let` over that run waits for it on the way
/// out: the whole suite then hangs instead of failing the one test. After
/// `parkDeadline` the engine fails the test with a message and releases itself.
///
/// Kept out of `TestHelpers.swift` so that file stays under its length limit.
@MainActor
final class ParkedEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    var providesTimestamps = true
    var segmentsToReturn: [TimestampedSegment] = []

    /// True once a run has entered `transcribeSegments` and suspended there.
    private(set) var isParked = false

    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var deadlineTask: Task<Void, Never>?

    /// How long a run may stay parked before the engine gives up on the test
    /// and lets it go. Generous against a loaded CI runner, short against the
    /// suite's own timeout.
    let parkDeadline: Duration

    init(parkDeadline: Duration = .seconds(20)) {
        self.parkDeadline = parkDeadline
    }

    func loadModel() {}

    func transcribeSegments(audioPath _: URL) async -> [TimestampedSegment] {
        isParked = true
        // Parking only when the release has not already happened keeps the two
        // orderings equivalent. Otherwise a run that arrives here after the
        // caller gave up waiting would park with nobody left to release it, and
        // the suite would hang rather than fail.
        if !isReleased {
            let deadline = parkDeadline
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled, let self else { return }
                XCTFail("ParkedEngine was not released within \(deadline); the test left a run parked")
                release()
            }
            await withCheckedContinuation { parkedContinuation = $0 }
        }
        return segmentsToReturn
    }

    /// Let the parked run continue, whether or not it has parked yet.
    func release() {
        isReleased = true
        deadlineTask?.cancel()
        deadlineTask = nil
        parkedContinuation?.resume()
        parkedContinuation = nil
    }
}
