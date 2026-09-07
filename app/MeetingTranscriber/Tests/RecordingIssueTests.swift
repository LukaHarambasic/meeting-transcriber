@testable import MeetingTranscriber
import XCTest

final class RecordingIssueTests: XCTestCase {
    // MARK: - Nothing wrong

    func testNoInputsMeansNoIssue() {
        XCTAssertNil(RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: false,
            askUnanswerable: false,
        ))
    }

    /// An empty-string error is not an error. `WatchLoop.lastError` is a
    /// `String?`, and treating `""` as a problem would put an issue row with no
    /// text in the menu and a red dot on the icon with nothing to explain it.
    func testEmptyRecordingErrorMeansNoIssue() {
        XCTAssertNil(RecordingIssue.compose(
            permissionProblems: [], recordingError: "", micSilent: false, appSilent: false,
            askUnanswerable: false,
        ))
    }

    // MARK: - Permission problems

    /// The exact case that prompted this: Screen Recording denied, nothing
    /// recording, and the menu previously said only "Idle".
    func testDeniedScreenRecordingBecomesAnIssueWithItsPane() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.screenRecordingDenied],
            recordingError: nil, micSilent: false, appSilent: false, askUnanswerable: false,
        )
        XCTAssertEqual(issue?.headline, PermissionProblem.screenRecordingDenied.description)
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
    }

    func testDeniedMicrophoneBecomesAnIssueWithItsPane() {
        let issue = RecordingIssue.compose(
            permissionProblems: [.microphoneDenied],
            recordingError: nil, micSilent: false, appSilent: false, askUnanswerable: false,
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
            recordingError: nil, micSilent: false, appSilent: false, askUnanswerable: false,
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
            recordingError: "Disk full", micSilent: false, appSilent: false, askUnanswerable: false,
        )
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
        XCTAssertNotEqual(issue?.headline, "Disk full", "the grant outranks the failed recording")
    }

    /// A recording error names a recording that failed; a silent channel is a
    /// recording that is running and producing at least one usable track.
    func testRecordingErrorOutranksASilentChannel() {
        let issue = RecordingIssue.compose(
            permissionProblems: [],
            recordingError: "Disk full", micSilent: true, appSilent: true, askUnanswerable: false,
        )
        XCTAssertEqual(
            issue?.headline, "Disk full",
            "the error message is the headline; a generic label plus a detail row said less",
        )
        XCTAssertNil(issue?.remedy, "a failed stop has no settings pane that would help")
    }

    func testMicSilenceOutranksAppSilence() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: true, appSilent: true,
            askUnanswerable: false,
        )
        XCTAssertEqual(issue?.remedy, .openMicrophone)
    }

    /// The whole reason `askUnanswerable` sits last: it blocks nothing (the
    /// recording is running and complete, only the unattended-stop safeguard
    /// is degraded), while a silent channel is losing audio on the very
    /// recording the menu describes right now. That silent channel must win
    /// the one line the menu has room for.
    func testAppSilenceOutranksAskUnanswerable() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: true,
            askUnanswerable: true,
        )
        XCTAssertEqual(
            issue?.remedy, .openScreenRecording,
            "a silent channel is losing audio right now and must outrank a degraded safeguard",
        )
    }

    func testMicSilenceOutranksAskUnanswerable() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: true, appSilent: false,
            askUnanswerable: true,
        )
        XCTAssertEqual(issue?.remedy, .openMicrophone)
    }

    // MARK: - Silent channels

    func testAppSilenceAloneBecomesAnIssue() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: true,
            askUnanswerable: false,
        )
        XCTAssertEqual(issue?.headline, "App audio is silent")
        XCTAssertEqual(issue?.remedy, .openScreenRecording)
    }

    func testMicSilenceAloneBecomesAnIssue() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: true, appSilent: false,
            askUnanswerable: false,
        )
        XCTAssertEqual(issue?.headline, "Microphone is silent")
    }

    // MARK: - Ask unanswerable

    /// The exact case this exists for: notifications for this app are
    /// suppressed by the OS, a "Still recording?" ask went unseen, and without
    /// this the menu said nothing about the safeguard being off.
    func testAskUnanswerableAloneBecomesAnIssueWithNotificationsPane() {
        let issue = RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: false,
            askUnanswerable: true,
        )
        XCTAssertEqual(issue?.remedy, .openNotifications)
        XCTAssertFalse(issue?.headline.isEmpty ?? true)
    }

    func testAskUnanswerableFalseMeansNoIssueWhenNothingElseIsWrong() {
        XCTAssertNil(RecordingIssue.compose(
            permissionProblems: [], recordingError: nil, micSilent: false, appSilent: false,
            askUnanswerable: false,
        ))
    }

    // MARK: - Remedies

    /// The button only renders when `settingsURL` resolves, so a broken literal
    /// would silently drop the one control that fixes the problem.
    func testAllRemediesResolveASettingsURL() {
        for remedy in [RecordingIssue.Remedy.openScreenRecording, .openMicrophone, .openNotifications] {
            XCTAssertNotNil(remedy.settingsURL, "\(remedy) must resolve a System Settings URL")
            XCTAssertFalse(remedy.buttonTitle.isEmpty)
        }
    }

    func testRemediesOpenDifferentPanes() {
        XCTAssertNotEqual(
            RecordingIssue.Remedy.openScreenRecording.settingsURL,
            RecordingIssue.Remedy.openMicrophone.settingsURL,
        )
        XCTAssertNotEqual(
            RecordingIssue.Remedy.openScreenRecording.settingsURL,
            RecordingIssue.Remedy.openNotifications.settingsURL,
        )
        XCTAssertNotEqual(
            RecordingIssue.Remedy.openMicrophone.settingsURL,
            RecordingIssue.Remedy.openNotifications.settingsURL,
        )
    }
}
