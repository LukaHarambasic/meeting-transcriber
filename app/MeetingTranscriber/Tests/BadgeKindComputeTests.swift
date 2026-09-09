@testable import MeetingTranscriber
import XCTest

final class BadgeKindComputeTests: XCTestCase {
    // MARK: Recording active

    func testBadgeRecordingWhenRecordingActiveAndStateIsRecording() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .recording)
    }

    func testBadgeTranscribingForTranscribingState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .transcribing,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeTranscribingForRecordingDoneState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recordingDone,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeUserActionForWaitingForSpeakerCount() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerCount,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeUserActionForWaitingForSpeakerNames() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerNames,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeDoneForProtocolReadyState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .protocolReady,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .done)
    }

    func testBadgeErrorForErrorState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .error,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .error)
    }

    func testBadgeProcessingForGeneratingProtocol() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .generatingProtocol,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .processing)
    }

    // MARK: Not recording, active job

    func testBadgeTranscribingForActiveTranscribingJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .transcribing,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeDiarizingForActiveDiarizingJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .diarizing,
        )
        XCTAssertEqual(badge, .diarizing)
    }

    func testBadgeProcessingForActiveGeneratingProtocolJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .generatingProtocol,
        )
        XCTAssertEqual(badge, .processing)
    }

    func testRecordingActiveTakesPriorityOverActiveJob() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: .transcribing,
        )
        XCTAssertEqual(badge, .recording)
    }

    // MARK: No recording, no jobs

    func testBadgeInactiveWhenNothingActive() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
        )
        XCTAssertEqual(badge, .inactive)
    }

    // MARK: Permission problem

    func testBadgeErrorWhenPermissionProblemAndIdle() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            permissionProblem: true,
        )
        XCTAssertEqual(badge, .error)
    }
}
