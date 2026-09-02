@testable import MeetingTranscriber
import XCTest

final class RecordingIssueTests: XCTestCase {
    // MARK: - Nothing wrong

    func testNoInputsMeansNoIssue() {
        XCTAssertNil(RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: false,
        ))
    }

    /// An empty-string error is not an error. `WatchLoop.lastError` is a
    /// `String?`, and treating `""` as a problem would put an issue row with no
    /// text in the menu and a red dot on the icon with nothing to explain it.
    func testEmptyRecordingErrorMeansNoIssue() {
        XCTAssertNil(RecordingIssue.compose(
            permissionProblems: [], recordingError: "", micSilent: false, appSilent: false,
        ))
    }

    // MARK: - Permission problems

    /// The exact case that prompted this: Screen Recording denied, nothing
    /// recording, and the menu previously said only "Idle".
    func testDeniedScreenRecordingBecomesAnIssueWithItsPane() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.screenRecordingDenied],
            recordingError: nil, micSilent: false, appSilent: false,
        )
        XCTAssertEqual(issue?.headline, PermissionProblem.screenRecordingDenied.description)
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
        XCTAssertFalse(issue?.detail.isEmpty ?? true, "the row has to say what the denial costs")
    }

    func testDeniedMicrophoneBecomesAnIssueWithItsPane() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.microphoneDenied],
            recordingError: nil, micSilent: false, appSilent: false,
        )
        XCTAssertEqual(issue?.headline, PermissionProblem.microphoneDenied.description)
        XCTAssertEqual(issue?.remedy, .openMicrophone)
    }

    /// A `.broken` grant needs the toggle-off-and-on remedy, which
    /// `PermissionProblem.description` already carries — so the headline must be
    /// that description verbatim, not a rewrite that drops it.
    func testBrokenGrantKeepsItsOwnRemedyWording() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.screenRecordingBroken],
            recordingError: nil, micSilent: false, appSilent: false,
        )
        XCTAssertEqual(issue?.headline, PermissionProblem.screenRecordingBroken.description)
        XCTAssertTrue(issue?.headline.contains("toggle it off and on") ?? false)
    }

    // MARK: - Precedence

    /// A missing grant refuses the recording outright and takes ten seconds to
    /// fix, so it outranks the record of a recording that already failed.
    func testPermissionProblemOutranksARecordingError() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.screenRecordingDenied],
            recordingError: "Disk full", micSilent: false, appSilent: false,
        )
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
        XCTAssertNotEqual(issue?.detail, "Disk full")
    }

    /// A recording error names a recording that failed; a silent channel is a
    /// recording that is running and producing at least one usable track.
    func testRecordingErrorOutranksASilentChannel() {
        let issue = RecordingIssue.compose(
            permissionProblems: [],
            recordingError: "Disk full", micSilent: true, appSilent: true,
        )
        XCTAssertEqual(issue?.headline, "Last recording failed")
        XCTAssertEqual(issue?.detail, "Disk full")
        XCTAssertNil(issue?.remedy, "a failed stop has no settings pane that would help")
    }

    func testMicSilenceOutranksAppSilence() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: true, appSilent: true,
        )
        XCTAssertEqual(issue?.remedy, .openMicrophone)
    }

    // MARK: - Silent channels

    func testAppSilenceAloneBecomesAnIssue() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: true,
        )
        XCTAssertEqual(issue?.headline, "App audio is silent")
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
    }

    func testMicSilenceAloneBecomesAnIssue() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: true, appSilent: false,
        )
        XCTAssertEqual(issue?.headline, "Microphone is silent")
    }

    // MARK: - Remedies

    /// The button only renders when `settingsURL` resolves, so a broken literal
    /// would silently drop the one control that fixes the problem.
    func testBothRemediesResolveASettingsURL() {
        for remedy in [RecordingIssue.Remedy.openScreenRecording, .openMicrophone] {
            XCTAssertNotNil(remedy.settingsURL, "\(remedy) must resolve a System Settings URL")
            XCTAssertFalse(remedy.buttonTitle.isEmpty)
        }
    }

    func testRemediesOpenDifferentPanes() {
        XCTAssertNotEqual(
            RecordingIssue.Remedy.openScreenRecording.settingsURL,
            RecordingIssue.Remedy.openMicrophone.settingsURL,
        )
    }
}
