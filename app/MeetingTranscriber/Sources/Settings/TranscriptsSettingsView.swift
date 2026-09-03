import SwiftUI

/// Settings → Transcripts: one row per recording the pipeline knows about, its
/// stage, and a way to open what came out.
///
/// The menu bar used to carry this and could not: a menu has no room for a
/// progress line, and its rows vanish the moment you click anywhere. Progress
/// that takes minutes needs a surface you can leave open and come back to.
struct TranscriptsSettingsView: View {
    let pipelineQueue: PipelineQueue
    let onDismissJob: (UUID) -> Void

    var body: some View {
        Form {
            Section("Transcripts") {
                if pipelineQueue.jobs.isEmpty {
                    Label("No recordings yet.", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pipelineQueue.jobs) { job in
                        jobRow(job)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func jobRow(_ job: PipelineJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.meetingTitle)
                    .font(.headline)
                Spacer()
                Text(job.state.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            progress(job)
            actions(job)
        }
        .padding(.vertical, 2)
    }

    /// An indeterminate bar while a stage is running, and nothing once it is
    /// not.
    ///
    /// Indeterminate on purpose: the stages that take the time (transcription,
    /// diarization, the LLM call) report no fraction, and a fake percentage
    /// that jumps or stalls is worse than an honest spinner. `job.state` is the
    /// real progress signal, and it is already on the row.
    @ViewBuilder
    private func progress(_ job: PipelineJob) -> some View {
        if Self.isRunning(job) {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private func actions(_ job: PipelineJob) -> some View {
        HStack(spacing: 12) {
            if let path = job.protocolPath ?? job.transcriptPath {
                Button("Open") { NSWorkspace.shared.open(path) }
                    .buttonStyle(.link)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    .buttonStyle(.link)
            }
            if Self.isRunning(job) {
                Button("Cancel") { pipelineQueue.cancelJob(id: job.id) }
                    .buttonStyle(.link)
            } else {
                Button("Remove") { onDismissJob(job.id) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    /// Whether a stage is currently working on this job. `static` and pure so
    /// the two call sites above cannot disagree about it.
    static func isRunning(_ job: PipelineJob) -> Bool {
        switch job.state {
        case .waiting, .transcribing, .diarizing, .generatingProtocol: true
        case .speakerNamingPending, .done, .error: false
        }
    }
}
