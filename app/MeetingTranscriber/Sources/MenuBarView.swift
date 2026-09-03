import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    /// What is currently wrong, or nil when nothing is. Passed separately from
    /// `status` on purpose: `status` is nil whenever no recording is active, so
    /// a problem that *stops* recordings from starting — a denied grant, the
    /// exact case the user hit — could never be shown through it.
    let issue: RecordingIssue?
    /// When the live recording started, or nil when nothing is recording. Drives
    /// the header's elapsed counter — the one fact about a running recording the
    /// menu can add.
    let recordingStartedAt: Date?
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
    var body: some View {
        statusHeader
        issueInfo

        Divider()

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

    /// One line: what the app is doing, and for a recording how long it has been
    /// doing it.
    ///
    /// This replaces four rows that all said the same thing. A live recording
    /// rendered `state.label` ("Recording"), then `status.detail` ("Recording:
    /// Meeting Recording"), then `meeting.title` ("Meeting Recording"), then
    /// `meetingLabel` ("Meeting") — the same fact four times, none of it
    /// actionable, and the meeting block was placeholder text for the
    /// system-wide recording that has no single app to name.
    ///
    /// The elapsed time is the one thing a running recording can tell you that
    /// you do not already know. `Text(_:style:.timer)` updates itself, so it
    /// needs no timer of ours and cannot go stale while the menu is open.
    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: state.icon)
            Text(state.label)
            if let startedAt = recordingStartedAt {
                Text(startedAt, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.headline)
        .padding(.horizontal, 4)
    }

    /// The row that says what is wrong and offers the pane that fixes it.
    ///
    /// Replaces a row that only rendered `status?.error` while the state was
    /// `.error`. That combination was unreachable for the failure that prompted
    /// this: `status` is nil unless a recording is active, so a refusal to start
    /// one showed nothing, and the user saw a red icon above the word "Idle"
    /// with no explanation anywhere in the app.
    ///
    /// The remedy button is separate from the text block so it is a real menu
    /// item the user can click, not a caption inside a `VStack`.
    /// The problem, in one line, followed by the button that fixes it.
    ///
    /// The explanatory sentence that used to sit under the headline is gone.
    /// "Screen Recording permission denied" plus **Open Screen Recording
    /// Settings** already says what is wrong and what to do; a sentence
    /// restating the consequence only widened the menu, which is what made it
    /// stretch across the display in the first place.
    @ViewBuilder private var issueInfo: some View {
        if let issue {
            Divider()
            Text(issue.headline)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
            issueRemedyButton(issue)
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

        Button {
            onProcessFiles()
        } label: {
            Label("Process Audio/Video Files...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
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

    private func jobRow(_ job: PipelineJob) -> some View {
        HStack {
            Circle()
                .fill(jobColor(job))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(job.meetingTitle)
                    .font(.caption)
                jobStateLabel(job)
            }
            Spacer()
            if job.state == .done, let path = job.protocolPath ?? job.transcriptPath {
                Button("Open") { onOpenProtocol(path) }
                    .font(.caption2)
            }
            if job.state == .speakerNamingPending {
                Button("Name Speakers") { onNameSpeakers?() }
                    .font(.caption2)
            }
            if job.state == .waiting || job.state == .transcribing
                || job.state == .diarizing || job.state == .generatingProtocol {
                Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
                    .font(.caption2)
            }
            if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
                Button("Dismiss") { onDismissJob(job.id) }
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 4)
    }

    private func jobStateLabel(_ job: PipelineJob) -> some View {
        Group {
            if [.transcribing, .diarizing, .generatingProtocol].contains(job.state) {
                Text(stageProgressText(job))
                    .foregroundStyle(.secondary)
            } else if job.state == .error, let msg = job.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else if job.state == .done, !job.warnings.isEmpty {
                Text(job.warnings.joined(separator: "; "))
                    .foregroundStyle(.orange)
            } else {
                Text(job.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
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

    private func jobColor(_ job: PipelineJob) -> Color {
        switch job.state {
        case .waiting: .gray
        case .transcribing: .blue
        case .diarizing: .purple
        case .generatingProtocol: .orange
        case .speakerNamingPending: .purple
        case .done: job.warnings.isEmpty ? .green : .yellow
        case .error: .red
        }
    }
}
