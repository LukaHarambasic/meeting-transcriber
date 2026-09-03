import SwiftUI

/// Settings → Diagnostics: the full text of anything that went wrong, and the
/// only place it is written out.
///
/// This exists because the menu bar was doing the job and doing it badly. A
/// menu sizes itself to its widest item, so a warning sentence stretched the
/// whole dropdown; the rows carried paragraphs with nothing to act on; and
/// finished jobs lingered there reading like meetings rather than problems. The
/// menu now shows at most three one-line problems, each of which opens this
/// pane.
struct DiagnosticsSettingsView: View {
    let pipelineQueue: PipelineQueue
    let onDismissJob: (UUID) -> Void

    var body: some View {
        Form {
            problemsSection
        }
        .formStyle(.grouped)
    }

    private var problemsSection: some View {
        Section("Problems") {
            let problems = pipelineQueue.problemJobs
            if problems.isEmpty {
                Label("Nothing to report.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(problems) { job in
                    problemRow(job)
                }
            }
        }
    }

    /// One problem, with its text in full and unwrapped-to-fit rather than
    /// truncated — a window can afford the words a menu could not.
    private func problemRow(_ job: PipelineJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(job.meetingTitle, systemImage: icon(job))
                    .font(.headline)
                Spacer()
                Button("Dismiss") { onDismissJob(job.id) }
            }
            if let error = job.error, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(Array(job.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            // Deliberately offered here and not in the menu: a finished job's
            // output is worth opening, but only once you can see which job it
            // belongs to and why it is flagged.
            if let path = job.protocolPath ?? job.transcriptPath {
                Button("Open Protocol") { NSWorkspace.shared.open(path) }
                    .buttonStyle(.link)
            }
        }
        // `textSelection` above is the point of putting these here: an error
        // message you cannot copy is one you cannot search for or paste into a
        // bug report.
        .padding(.vertical, 2)
    }

    private func icon(_ job: PipelineJob) -> String {
        job.state == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
    }
}
