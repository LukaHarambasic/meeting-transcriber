import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// What `startCapture` does differently depending on `TapTarget`, split out
/// of `AppAudioCapture.swift` to stay under the 600-line lint cap (same
/// reason as `+Restart` and `+AggregateDescription`), and because pulling the
/// per-target branching out of `startCapture` itself is what keeps that
/// function's cyclomatic complexity under the lint cap too.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// The `CATapDescription` shape for a target. Reads nothing off the
    /// instance, so a test can call it directly on a fabricated PID list
    /// without a live CATap. The `.systemMixdown` arm excludes no processes
    /// on purpose — the whole point of a global tap is to not have to name
    /// anything — and stays stereo to match `.processes`, rather than
    /// dropping to the mono initializer for no reason a caller would ask for.
    static func makeTapDescription(target: TapTarget, processObjectIDs: [AudioObjectID]) -> CATapDescription {
        switch target {
        case .processes:
            CATapDescription(stereoMixdownOfProcesses: processObjectIDs)

        case .systemMixdown:
            CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
    }

    /// Embedded in the aggregate device's name (`audiotap-<tag>`), purely so an
    /// orphaned device is identifiable in `system_profiler SPAudioDataType`:
    /// the root PID for `.processes`, or the literal "system" for a global tap
    /// that has no PID to show.
    var aggregateNameTag: String {
        switch target {
        case let .processes(pids):
            pids.first.map(String.init) ?? "0"

        case .systemMixdown:
            "system"
        }
    }

    /// What this capture is tapping, for the log lines that fire on a failure
    /// path rather than the per-PID summary built while translating.
    var targetDescription: String {
        switch target {
        case let .processes(pids):
            "pids=\(pids)"

        case .systemMixdown:
            "system mixdown"
        }
    }

    /// Resolve the `AudioObjectID`s `startCapture` hands `CATapDescription`,
    /// logging along the way. Pulled out of `startCapture` itself: the two
    /// arms share nothing but a return type, so folding them back in would
    /// only add to that function's already-long body and complexity.
    func resolveProcessObjectIDs() throws -> [AudioObjectID] {
        switch target {
        case .processes:
            let translated = try translatePIDs()

            // Always log at info level with exe names so a "silent _app.wav"
            // report can be triaged without the user toggling Verbose Audio
            // Logging first — process names like "MSTeams Helper (Renderer)"
            // make issue-#84-style failures actionable.
            let tapSummary = translated.map { "\(getExecutableName(pid: $0.pid))(\($0.pid))" }.joined(separator: ", ")
            logger.info(
                "App audio tap: \(translated.count) PID(s) [\(tapSummary, privacy: .public)]",
            )

            if debugLogging {
                for entry in translated {
                    let bundleID = getProcessBundleID(entry.audioObjectID) ?? "?"
                    let exeName = getExecutableName(pid: entry.pid)
                    logger.info(
                        "[debug] Tap target: pid=\(entry.pid, privacy: .public) exe=\(exeName, privacy: .public) bundle=\(bundleID, privacy: .public) audioObjectID=\(entry.audioObjectID, privacy: .public)",
                    )
                }
            }
            return translated.map(\.audioObjectID)

        case .systemMixdown:
            // Nothing to translate or enumerate up front — the tap follows
            // the output mixdown itself rather than any named process.
            logger.info("App audio tap: system-wide mixdown")
            return []
        }
    }
}
