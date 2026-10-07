@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
// swiftlint:disable:next attributes type_body_length
final class MenuBarViewTests: XCTestCase {
    // MARK: - Helpers

    private func makeStatus(
        state: TranscriberState = .idle,
        detail: String = "",
        meeting: MeetingInfo? = nil,
        protocolPath: String? = nil,
        error: String? = nil,
    ) -> TranscriberStatus {
        TranscriberStatus(
            version: 1,
            timestamp: "2024-01-01T00:00:00",
            state: state,
            detail: detail,
            meeting: meeting,
            protocolPath: protocolPath,
            error: error,
            audioPath: nil,
            pid: nil,
        )
    }

    private func makeView(
        status: TranscriberStatus? = nil,
        issue: RecordingIssue? = nil,
        pipelineQueue: PipelineQueue? = nil,
        onNameSpeakers: (() -> Void)? = nil,
        onStopManualRecording: (() -> Void)? = nil,
        onRecordMeeting: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        manualRecordingPendingOrActive: Bool = false,
    ) -> MenuBarView {
        MenuBarView(
            status: status,
            issue: issue,
            pipelineQueue: pipelineQueue ?? PipelineQueue(),
            onRecordMeeting: onRecordMeeting,
            manualRecordingPendingOrActive: manualRecordingPendingOrActive,
            onStopManualRecording: onStopManualRecording,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: onOpenSettings,
            onOpenNotes: {},
            onNameSpeakers: onNameSpeakers,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
    }

    /// A job in any state. Inserted through `insertJobForTesting` so no test
    /// starts the real processing trigger or writes a queue snapshot.
    private func makeJob(
        _ title: String,
        state: JobState = .waiting,
        error: String? = nil,
        warnings: [String] = [],
    ) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title,
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.state = state
        job.error = error
        job.warnings = warnings
        return job
    }

    private func makeQueue(_ jobs: [PipelineJob]) -> PipelineQueue {
        let queue = PipelineQueue()
        for job in jobs {
            queue.insertJobForTesting(job)
        }
        return queue
    }

    // MARK: - No status header

    /// There is deliberately no status header at all.
    ///
    /// It once rendered the state label, `status.detail`, the meeting title and
    /// the app name: the same fact four times. Condensing it to one line was not
    /// enough either, because a menu flattens a `Label`/`HStack` into one row
    /// per control, so the icon and the word "Idle" landed on separate rows for
    /// an app that had nothing to report. What the app is doing is legible from
    /// the controls (Record vs Stop Recording) and from the queue rows.
    func testNoStatusHeaderIsRendered() throws {
        let meeting = MeetingInfo(app: "Teams", title: "Standup", pid: 123)
        let sut = makeView(status: makeStatus(state: .recording, detail: "Recording: Standup", meeting: meeting))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Standup"), "the meeting title duplicated the state line")
        XCTAssertThrowsError(try body.find(text: "Recording: Standup"), "the detail duplicated it again")
        XCTAssertThrowsError(try body.find(text: "Teams (PID 123)"), "the app name duplicated it a third time")
        XCTAssertThrowsError(
            try body.find(text: TranscriberState.idle.label),
            "an idle app must not spend a menu row saying so",
        )
    }

    // MARK: - Issue display

    func testIssueHeadlineShown() throws {
        let issue = RecordingIssue(
            headline: "Screen Recording permission denied",
            remedy: .openScreenRecording,
        )
        let sut = makeView(status: nil, issue: issue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Screen Recording permission denied"))
    }

    /// The regression the whole issue row exists for: the problem has to show
    /// while *nothing* is recording, because that is exactly when a refused
    /// start leaves the user with a red icon and the word "Idle". `status` is nil
    /// here, and the old error row read `status?.error` and so could never fire.
    func testIssueShownWithNoActiveStatus() throws {
        let issue = RecordingIssue(headline: "Boom", remedy: nil)
        let sut = makeView(status: nil, issue: issue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Boom"))
    }

    func testNoIssueMeansNoIssueRow() throws {
        let sut = makeView(status: makeStatus(state: .idle), issue: nil)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Boom"))
    }

    func testRemedyButtonShownForPermissionIssue() throws {
        let issue = RecordingIssue(headline: "Denied", remedy: .openScreenRecording)
        let sut = makeView(status: nil, issue: issue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: RecordingIssue.Remedy.openScreenRecording.buttonTitle))
    }

    func testRemedyButtonAbsentWhenNoPaneWouldHelp() throws {
        let issue = RecordingIssue(headline: "Disk full", remedy: nil)
        let sut = makeView(status: nil, issue: issue)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Disk full"))
        XCTAssertThrowsError(
            try body.find(button: RecordingIssue.Remedy.openScreenRecording.buttonTitle),
        )
    }

    // MARK: - Name Speakers button

    func testNameSpeakersButtonShownWhenWaiting() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .waitingForSpeakerNames), onNameSpeakers: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Name Speakers..."))
    }

    func testNameSpeakersButtonHiddenWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Name Speakers..."))
    }

    // MARK: - Protocol link

    func testOpenLastProtocolShownWhenPathPresent() throws {
        let sut = makeView(status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Last Transcript"))
    }

    func testOpenLastProtocolHiddenWhenNoPath() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Open Last Transcript"))
        // Control: the same body does render its other static rows, so the
        // absence above is about this row and not about an empty inspection.
        XCTAssertNoThrow(try body.find(text: "Open Transcripts Folder"))
    }

    // MARK: - Static buttons always present

    func testSettingsButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Settings..."))
    }

    func testOpenProtocolsFolderButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Open Transcripts Folder"))
    }

    func testQuitButtonExists() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Quit"))
    }

    // MARK: - Record button

    func testRecordButtonShownWhenIdle() throws {
        let sut = makeView(status: makeStatus(state: .idle))
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Record"))
    }

    func testRecordButtonCallsCallback() throws {
        var called = false
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .idle), onRecordMeeting: { called = true })

        try sut.inspect().find(button: "Record").tap()

        XCTAssertTrue(called)
    }

    func testRecordButtonHiddenWhileRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Record"))
    }

    // MARK: - Button tap callbacks

    func testQuitButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onOpenNotes: {},
            onNameSpeakers: nil,
            onQuit: { called = true }, // swiftlint:disable:this trailing_closure
        )
        let body = try sut.inspect()
        try body.find(button: "Quit").tap()
        XCTAssertTrue(called)
    }

    func testSettingsButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: { called = true },
            onOpenNotes: {},
            onNameSpeakers: nil,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
        let body = try sut.inspect()
        try body.find(button: "Settings...").tap()
        XCTAssertTrue(called)
    }

    func testProtocolsFolderButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .idle),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: { called = true },
            onOpenSettings: {},
            onOpenNotes: {},
            onNameSpeakers: nil,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
        let body = try sut.inspect()
        try body.find(button: "Open Transcripts Folder").tap()
        XCTAssertTrue(called)
    }

    func testOpenLastProtocolButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .protocolReady, protocolPath: "/tmp/p.md"),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: { called = true },
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onOpenNotes: {},
            onNameSpeakers: nil,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
        let body = try sut.inspect()
        try body.find(button: "Open Last Transcript").tap()
        XCTAssertTrue(called)
    }

    func testNameSpeakersButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .waitingForSpeakerNames),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: nil,
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onOpenNotes: {},
            // No `disable:this` on `onQuit` here, unlike the other call sites:
            // `trailing_closure` does not fire when the argument immediately
            // before the final closure is itself a closure literal, and
            // `superfluous_disable_command` fails the build on the unused
            // suppression.
            onNameSpeakers: { called = true },
            onQuit: {},
        )
        let body = try sut.inspect()
        try body.find(button: "Name Speakers...").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Queue rows

    /// The menu lists problems, not progress. A job that is waiting, running or
    /// finished cleanly adds no row at all: no title, no state text, and none of
    /// the Open / Cancel / Dismiss buttons the per-job rows used to carry (those
    /// moved to Settings, Transcripts and Diagnostics).
    func testJobsWithoutAProblemAddNoMenuRows() throws {
        let states: [JobState] = [.waiting, .transcribing, .diarizing, .generatingProtocol, .done]
        for state in states {
            let queue = makeQueue([makeJob("Standup", state: state)])
            let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
            XCTAssertThrowsError(try body.find(text: "Standup"), "a \(state) job leaked into the menu")
            XCTAssertThrowsError(try body.find(text: "Processing"), "\(state)")
            XCTAssertThrowsError(try body.find(button: "Cancel"), "\(state)")
            XCTAssertThrowsError(try body.find(button: "Dismiss"), "\(state)")
            XCTAssertThrowsError(try body.find(button: "Open"), "\(state)")
            // Control: the menu itself did render.
            XCTAssertNoThrow(try body.find(text: "Quit"), "\(state)")
        }
    }

    func testProcessingSectionHiddenWhenNoJobs() throws {
        let sut = makeView(status: makeStatus())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Processing"))
    }

    /// Both a warning and an error make a row; the row carries the meeting and
    /// a short reason (`problemRowTitle`), not the whole sentence.
    func testWarningJobShowsWarningRow() throws {
        let queue = makeQueue([
            makeJob("Standup", state: .done, warnings: ["App track diarization failed"]),
        ])
        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try body.find(text: "Standup · App track diarization failed"))
    }

    func testErrorJobShowsErrorRow() throws {
        let queue = makeQueue([makeJob("Broken", state: .error, error: "Transcription failed")])
        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try body.find(text: "Broken · Transcription failed"))
    }

    func testEveryProblemJobGetsARow() throws {
        let queue = makeQueue([
            makeJob("Meeting 1", state: .error, error: "Empty transcript"),
            makeJob("Meeting 2", state: .done, warnings: ["Speakers not identified"]),
        ])
        let body = try makeView(status: makeStatus(), pipelineQueue: queue).inspect()
        XCTAssertNoThrow(try body.find(text: "Meeting 1 · Empty transcript"))
        XCTAssertNoThrow(try body.find(text: "Meeting 2 · Speakers not identified"))
    }

    /// A problem row is a pointer to Settings, where the full text lives.
    func testProblemRowOpensSettings() throws {
        var opened = false
        let queue = makeQueue([makeJob("Broken", state: .error, error: "Transcription failed")])
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(), pipelineQueue: queue, onOpenSettings: { opened = true })

        try sut.inspect().find(button: "Broken · Transcription failed").tap()

        XCTAssertTrue(opened)
    }

    /// At most `menuProblemLimit` rows; the rest collapse into one count row so
    /// the menu cannot grow with the queue.
    func testProblemRowsAreCappedWithAMoreRow() throws {
        let limit = MenuBarView.menuProblemLimit
        let jobs = (1 ... (limit + 2)).map { makeJob("Job \($0)", state: .error, error: "Failed") }
        let body = try makeView(status: makeStatus(), pipelineQueue: makeQueue(jobs)).inspect()
        for index in 1 ... limit {
            XCTAssertNoThrow(try body.find(text: "Job \(index) · Failed"))
        }
        XCTAssertThrowsError(try body.find(text: "Job \(limit + 1) · Failed"))
        XCTAssertNoThrow(try body.find(text: "2 more in Settings"))
    }

    func testNoMoreRowAtTheLimit() throws {
        let limit = MenuBarView.menuProblemLimit
        let jobs = (1 ... limit).map { makeJob("Job \($0)", state: .error, error: "Failed") }
        let body = try makeView(status: makeStatus(), pipelineQueue: makeQueue(jobs)).inspect()
        XCTAssertNoThrow(try body.find(text: "Job \(limit) · Failed"))
        XCTAssertThrowsError(try body.find(text: "0 more in Settings"))
    }

    func testProblemRowTitleTruncatesTitleAndReason() {
        let job = makeJob(
            "A very long meeting title that overflows",
            state: .error,
            error: "A very long failure reason that would stretch the menu",
        )
        XCTAssertEqual(
            MenuBarView.problemRowTitle(job),
            "A very long meeting tit… · A very long failure reason th…",
        )
    }

    func testProblemRowTitlePrefersErrorOverWarning() {
        let job = makeJob("Standup", state: .error, error: "Boom", warnings: ["Soft problem"])
        XCTAssertEqual(MenuBarView.problemRowTitle(job), "Standup · Boom")
    }

    func testProblemRowTitleFallsBackToStateLabel() {
        let job = makeJob("Standup", state: .error)
        XCTAssertEqual(MenuBarView.problemRowTitle(job), "Standup · \(JobState.error.label)")
    }

    func testProblemRowIconDistinguishesErrorFromWarning() {
        XCTAssertNotEqual(
            MenuBarView.problemRowIcon(makeJob("A", state: .error, error: "x")),
            MenuBarView.problemRowIcon(makeJob("B", state: .done, warnings: ["x"])),
        )
    }

    // MARK: - Stop Recording button (manual)

    func testStopRecordingButtonVisibleDuringManualRecording() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .recording), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonHiddenWhenNoManualRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording))
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingButtonCallsCallback() throws {
        var called = false
        let sut = MenuBarView(
            status: makeStatus(state: .recording),
            issue: nil,
            pipelineQueue: PipelineQueue(),
            onRecordMeeting: {},
            manualRecordingPendingOrActive: false,
            onStopManualRecording: { called = true },
            onOpenLastProtocol: {},
            onOpenProtocolsFolder: {},
            onOpenSettings: {},
            onOpenNotes: {},
            onNameSpeakers: nil,
            onQuit: {}, // swiftlint:disable:this trailing_closure
        )
        let body = try sut.inspect()
        try body.find(button: "Stop Recording").tap()
        XCTAssertTrue(called)
    }

    // MARK: - Record/Stop button mutual exclusion

    func testRecordAndStopBothHiddenDuringAutoRecording() throws {
        let sut = makeView(status: makeStatus(state: .recording), onStopManualRecording: nil)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(button: "Record"))
        XCTAssertThrowsError(try body.find(text: "Stop Recording"))
    }

    func testStopRecordingReplacesRecordButton() throws {
        // swiftlint:disable:next trailing_closure
        let sut = makeView(status: makeStatus(state: .idle), onStopManualRecording: {})
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Stop Recording"))
        XCTAssertThrowsError(try body.find(button: "Record"))
    }

    // MARK: - No state labels

    /// `TranscriberState.label` is no longer rendered anywhere in the menu, for
    /// any state; the controls and the problem rows carry what the app is doing.
    func testNoTranscriberStateLabelIsRendered() throws {
        let states: [TranscriberState] = [
            .idle, .recording, .transcribing,
            .generatingProtocol, .protocolReady, .error,
        ]
        for state in states {
            let body = try makeView(status: makeStatus(state: state)).inspect()
            XCTAssertThrowsError(
                try body.find(text: state.label),
                "State label '\(state.label)' is rendered for \(state)",
            )
            // Control: the menu itself did render.
            XCTAssertNoThrow(try body.find(text: "Quit"), "\(state)")
        }
    }
}
