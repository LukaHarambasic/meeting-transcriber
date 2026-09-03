import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    /// What is currently wrong, or nil when nothing is. Passed separately from
    /// `status` on purpose: `status` is nil whenever no recording is active, so
    /// a problem that *stops* recordings from starting — a denied grant, the
    /// exact case the user hit — could never be shown through it.
    let issue: RecordingIssue?
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    let onRecordMeeting: () -> Void
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the Record item would sit enabled through it
    /// handing back a dead click.
    let manualRecordingPendingOrActive: Bool
    let onStopManualRecording: (() -> Void)?
    let onOpenLastProtocol: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    // The sections below are hoisted out of `body` into separate computed
    // properties so each is type-checked independently. Inlined as one
    // expression, the `body` getter crossed the 300 ms type-check budget that
    // the analyze build enforces (-warn-long-expression-type-checking=300 with
    // -warnings-as-errors), failing the build on slower CI hardware. The view
    // order, dividers, and conditionals are unchanged.
    // No status header. An idle app has nothing to say, and the row that said
    // "Idle" cost two menu items: a `Label`/`HStack` of icon plus text is
    // flattened by a menu into one row per control, so the icon and the word
    // landed on separate lines. What the app is doing is already legible from
    // the controls (Record vs Stop Recording) and from the queue rows.
    var body: some View {
        issueInfo

        recordControls
        problemRows

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    /// The problem, in one line, followed by the button that fixes it.
    ///
    /// It replaces a row that only rendered `status?.error` while the state was
    /// `.error` — unreachable for the failure that prompted it, since `status`
    /// is nil unless a recording is active, so a refused start showed nothing
    /// and the user saw a red icon above the word "Idle".
    ///
    /// The explanatory sentence that used to sit under the headline is gone.
    /// "Screen Recording permission denied" plus **Open Screen Recording
    /// Settings** already says what is wrong and what to do; a sentence
    /// restating the consequence only widened the menu, which is what made it
    /// stretch across the display in the first place.
    @ViewBuilder private var issueInfo: some View {
        if let issue {
            Text(issue.headline)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
            issueRemedyButton(issue)
            // After, not before: with no header above it, a leading `Divider()`
            // would draw a rule across the very top of the menu.
            Divider()
        }
    }

    /// Hoisted into its own function rather than inlined in `issueInfo`: the
    /// optional-chained `remedy?.settingsURL` inside a `ViewBuilder` is the
    /// shape this file's 300 ms type-check budget keeps failing on (see `body`).
    @ViewBuilder
    private func issueRemedyButton(_ issue: RecordingIssue) -> some View {
        if let remedy = issue.remedy, let url = remedy.settingsURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(remedy.buttonTitle, systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder private var recordControls: some View {
        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else if state != .recording {
            // THE record action, deliberately without siblings: the owner never
            // wants to choose a capture shape at record time. One press records
            // everything the Mac plays plus the microphone; narrower shapes
            // (mic-only, single app) exist only behind the automation API.
            // Always enabled — no permission or setting turns this into a
            // recording of nothing (see `WatchLoop.startMeetingRecording`).
            Button {
                onRecordMeeting()
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .keyboardShortcut("r")
            .disabled(manualRecordingPendingOrActive)
            .help("Record the meeting: all system audio plus the microphone")
        }

        if let onNameSpeakers {
            Button {
                onNameSpeakers()
            } label: {
                Label("Name Speakers...", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
        }
    }

    /// At most three one-line problems, each opening Settings.
    ///
    /// The menu used to render the whole queue: a "Processing" header plus a row
    /// per job carrying its error or warning text. That is the wrong job for a
    /// menu. A menu sizes to its widest item, so a warning sentence stretched
    /// it; the rows offered nothing to act on; and finished jobs lingered as
    /// entries that read like meetings rather than like problems.
    ///
    /// Three is a cap, not a target: enough to see that something is wrong and
    /// roughly what, few enough that the menu cannot grow. The text itself, and
    /// anything that can be done about it, is in Settings → Diagnostics.
    @ViewBuilder private var problemRows: some View {
        let problems = pipelineQueue.problemJobs
        if !problems.isEmpty {
            Divider()
            ForEach(problems.prefix(Self.menuProblemLimit)) { job in
                Button {
                    onOpenSettings()
                } label: {
                    Label(Self.problemRowTitle(job), systemImage: Self.problemRowIcon(job))
                }
            }
            if problems.count > Self.menuProblemLimit {
                Button {
                    onOpenSettings()
                } label: {
                    Text("\(problems.count - Self.menuProblemLimit) more in Settings")
                }
            }
        }
    }

    /// How many problems the menu will show before deferring the rest to
    /// Settings.
    static let menuProblemLimit = 3

    /// Meeting plus a short reason, hard-truncated. The full text is in
    /// Settings; this row exists to say "this one" and to get you there.
    static func problemRowTitle(_ job: PipelineJob) -> String {
        let reason = job.error ?? job.warnings.first ?? JobState.error.label
        let short = reason.count > 30 ? String(reason.prefix(29)) + "…" : reason
        let title = job.meetingTitle.count > 24
            ? String(job.meetingTitle.prefix(23)) + "…"
            : job.meetingTitle
        return title + " · " + short
    }

    static func problemRowIcon(_ job: PipelineJob) -> String {
        job.state == .error ? "exclamationmark.triangle" : "exclamationmark.circle"
    }

    @ViewBuilder private var protocolActions: some View {
        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("Open Last Protocol", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("Open Protocols Folder", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let update = updateChecker?.availableUpdate {
            Divider()
            Button {
                NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
            } label: {
                Label(
                    "Update Available: \(update.tagName)",
                    systemImage: "arrow.down.circle.fill",
                )
            }
        }
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label("Settings...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            onQuit()
        } label: {
            Text("Quit")
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    /// Live elapsed for the active stage, plus the historical average ("· Ø
    /// m:ss") when one exists, and a "longer than usual" hint once the live run
    /// runs meaningfully past that average — so the user can tell at a glance
    /// whether the current run is normal. Purely informational.
    private func stageProgressText(_ job: PipelineJob) -> String {
        let elapsed = pipelineQueue.activeJobElapsed
        let base = "\(job.state.label) \(formattedElapsed(elapsed))"
        guard let stage = StageKind(jobState: job.state),
              let avg = pipelineQueue.averageSeconds(forJobID: job.id, stage: stage), avg > 0 else { return base }
        let suffix = StageTimingStats.isSlowerThanUsual(elapsed: elapsed, average: avg)
            ? " · longer than usual (Ø \(formattedElapsed(avg)))"
            : " · Ø \(formattedElapsed(avg))"
        return base + suffix
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        formattedTime(seconds)
    }
}
