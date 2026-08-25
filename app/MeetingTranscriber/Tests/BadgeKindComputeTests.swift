@testable import MeetingTranscriber
import XCTest

final class BadgeKindComputeTests: XCTestCase {
    // MARK: Recording active

    func testBadgeRecordingWhenRecordingActiveAndStateIsRecording() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .recording)
    }

    func testBadgeTranscribingForTranscribingState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .transcribing,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeTranscribingForRecordingDoneState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recordingDone,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeUserActionForWaitingForSpeakerCount() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerCount,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeUserActionForWaitingForSpeakerNames() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerNames,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .userAction)
    }

    func testBadgeDoneForProtocolReadyState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .protocolReady,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .done)
    }

    func testBadgeErrorForErrorState() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .error,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .error)
    }

    func testBadgeProcessingForGeneratingProtocol() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .generatingProtocol,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .processing)
    }

    // MARK: Not recording, active job

    func testBadgeTranscribingForActiveTranscribingJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .transcribing)
    }

    func testBadgeDiarizingForActiveDiarizingJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .diarizing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .diarizing)
    }

    func testBadgeProcessingForActiveGeneratingProtocolJob() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .generatingProtocol,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .processing)
    }

    func testRecordingActiveTakesPriorityOverActiveJob() {
        let badge = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .recording)
    }

    // MARK: No recording, no jobs

    func testBadgeUpdateAvailableWhenNoRecordingNoJobs() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
        )
        XCTAssertEqual(badge, .updateAvailable)
    }

    func testBadgeInactiveWhenNothingActive() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(badge, .inactive)
    }

    // MARK: Permission problem

    func testBadgeErrorWhenPermissionProblemAndIdle() {
        let badge = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(badge, .error)
    }
}
