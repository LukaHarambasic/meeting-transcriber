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
    let onProcessFiles: () -> Void
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
        processingQueue

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

        // "Process Audio/Video Files..." read as "process the recordings you
        // already made", which is not what it does and made the app look like
        // it needed to be told to finish its own work. Recordings go onto the
        // pipeline the moment they stop; this item is for audio that came from
        // somewhere else.
        Button {
            onProcessFiles()
        } label: {
            Label("Transcribe Audio or Video...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
        .help("Transcribe an existing file from disk, e.g. a recording someone sent you")
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label("Processing", systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(pipelineQueue.jobs) { job in
                jobRow(job)
            }
        }
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

    /// One job, one menu row.
    ///
    /// It used to be an `HStack` of a status dot, a two-line `VStack` and up to
    /// three `Button`s. A menu cannot render that: SwiftUI flattens the controls
    /// into separate rows, so a single finished job became a title row, a status
    /// row and a bare "Dismiss" row with nothing tying them together — the
    /// sprawling faded block that was reported. Long warning text widened the
    /// menu on top of that.
    ///
    /// So: one `Button` per job, its label carrying title and state, and exactly
    /// one action — the one that job's state actually affords. A running job has
    /// no action, so its row is disabled rather than fabricating one.
    private func jobRow(_ job: PipelineJob) -> some View {
        Button {
            jobAction(job)
        } label: {
            Label(jobRowTitle(job), systemImage: jobRowIcon(job))
        }
        .disabled(!jobHasAction(job))
    }

    /// Title and state on one line, truncated. The state word is what changes;
    /// repeating the meeting title on a second line added no information.
    private func jobRowTitle(_ job: PipelineJob) -> String {
        let title = job.meetingTitle.count > 28
            ? String(job.meetingTitle.prefix(27)) + "…"
            : job.meetingTitle
        return title + " · " + jobRowStatus(job)
    }

    /// The shortest true description of where this job is.
    ///
    /// An error or warning wins over the state word, because "Error" alone sends
    /// the user hunting. Both are truncated: the untruncated warning text is
    /// what stretched the menu.
    private func jobRowStatus(_ job: PipelineJob) -> String {
        let detail: String? = if job.state == .error {
            job.error
        } else if !job.warnings.isEmpty {
            job.warnings.first
        } else if [.transcribing, .diarizing, .generatingProtocol].contains(job.state) {
            stageProgressText(job)
        } else {
            nil
        }
        guard let detail, !detail.isEmpty else { return job.state.label }
        return detail.count > 44 ? String(detail.prefix(43)) + "…" : detail
    }

    private func jobRowIcon(_ job: PipelineJob) -> String {
        switch job.state {
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        case .speakerNamingPending: "person.2"
        default: "clock"
        }
    }

    /// Whether this job's row does anything when clicked. Drives `.disabled`, so
    /// a row that cannot act says so instead of swallowing the click.
    private func jobHasAction(_ job: PipelineJob) -> Bool {
        switch job.state {
        case .done, .error, .speakerNamingPending: true
        default: false
        }
    }

    /// The single action a job's state affords: open the finished output, name
    /// its speakers, or clear a failure. A running job is not cancellable from
    /// here any more — a "Cancel" that sat next to "Dismiss" on a flattened row
    /// was one mis-click away from discarding a recording mid-transcription.
    private func jobAction(_ job: PipelineJob) {
        switch job.state {
        case .done:
            if let path = job.protocolPath ?? job.transcriptPath { onOpenProtocol(path) }

        case .speakerNamingPending:
            onNameSpeakers?()

        case .error:
            onDismissJob(job.id)

        default:
            break
        }
    }

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
