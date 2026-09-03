import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Manual-recording session driver.
///
/// Owns the lifecycle of a recording the user started explicitly (app picker,
/// "Record Microphone", "Record Meeting") through to enqueueing it on the
/// `PipelineQueue`. Meeting auto-detection ("watch mode") has been removed —
/// every recording here is started by an explicit user action, never by a
/// poll loop.
@MainActor
@Observable
class WatchLoop {
    enum State: String {
        case idle
        case recording
        case error
    }

    private(set) var state: State = .idle
    private(set) var lastError: String?
    private(set) var detail: String = ""

    // Manual recording
    private(set) var manualRecordingInfo: ManualRecordingInfo?
    /// Exposed for read-only access — AppState's per-channel level monitor polls
    /// `appLevelDBFS` / `micLevelDBFS` here at ~10 Hz to drive the asymmetric-silence
    /// indicator. Setter stays private so the recording lifecycle flows through
    /// this class only.
    private(set) var activeRecorder: (any RecordingProvider)?
    private var manualRecordingTask: Task<Void, Never>?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let recorderFactory: @MainActor () async -> any RecordingProvider
    var pipelineQueue: PipelineQueue?
    var permissionChecker: () async -> HealthCheckResult = { await PermissionHealthCheck.runLive() }

    // Settings
    /// Cadence of `monitorManualRecording`'s poll loop.
    let pollInterval: TimeInterval
    let maxDuration: TimeInterval
    let noMic: Bool
    let micDeviceUID: String?
    /// Dynamic accessor — read at recording-start time so toggling the setting
    /// at runtime takes effect on the next recording without an app restart.
    let verboseDiagnostics: () -> Bool
    /// Dynamic accessor — when true, skip the post-processing pipeline and
    /// instead write a `<basename>_meta.json` sidecar next to the recording.
    let recordOnly: () -> Bool
    /// Dynamic accessor — destination for record-only output (WAVs + sidecar
    /// JSON). Returns a `(scope, writeDir)` pair so we can call
    /// `startAccessingSecurityScopedResource()` on the *bookmark-resolved
    /// parent* (the URL the user actually picked) while writing into a
    /// `recordings/` subfolder. Calling start-access on a child URL silently
    /// fails inside the App Store sandbox — see `RecordOnlyDestination`.
    let recordOnlyDestination: () -> RecordOnlyDestination
    /// Surface user-facing failures (e.g. sidecar write errors) that don't
    /// transition state to `.error`. Defaults to a silent no-op for tests.
    let notifier: any AppNotifying

    /// Wall-clock source. Defaults to `Date()`; tests inject a `TestClock`
    /// so timing-sensitive paths become deterministic instead of racing
    /// against `Task.sleep`'s actual jitter on loaded CI runners.
    let nowProvider: () -> Date
    /// Sleep primitive. Defaults to `Task.sleep`; tests inject the
    /// matching `TestClock.sleep` so virtual time advances synchronously.
    let sleepProvider: (TimeInterval) async throws -> Void
    /// Process-alive probe. Defaults to `kill(pid, 0) == 0`; tests inject
    /// a closure with a deterministic answer so the
    /// `monitorManualRecording` switch arms can be exercised without
    /// spawning a real subprocess.
    let pidAliveCheck: (pid_t) -> Bool

    /// Holds the "don't idle-sleep" power assertion for the length of a
    /// recording. Optional so a test can pass nil and assert nothing else
    /// changed; production always supplies one. See `RecordingPowerAssertion`
    /// for why it blocks system sleep and deliberately not display sleep.
    let sleepBlocker: (any RecordingSleepBlocking)?

    /// When to ask whether an unattended recording should keep going, and how
    /// long an unanswered ask may stand. Injected whole so a test can drive
    /// both boundaries in virtual time.
    let confirmationPolicy: RecordingConfirmationPolicy

    /// Re-mixes the tracks a failed `stop()` left behind, returning how many
    /// recordings it rescued. Injectable because the production implementation
    /// scans and mutates `AppPaths.recordingsDir` — the real staging directory,
    /// which a unit test has no business writing into — and because the
    /// interesting assertion is that the *stop path calls it*, not that the
    /// recovery function works (which `DualSourceRecorder`'s own tests cover).
    let salvageInterrupted: () -> Int

    /// When this recording was last known to be wanted: its start, or the
    /// user's last confirmation. `private(set)` for the RPC snapshot and tests.
    private(set) var confirmedAt: Date = .distantPast

    /// When the live recording started, or nil when nothing is recording.
    ///
    /// Distinct from `confirmedAt`, which the still-recording check resets on
    /// every confirmation — reusing it for the menu's elapsed counter would
    /// restart the clock at 30-minute intervals.
    private(set) var recordingStartedAt: Date?

    /// When the outstanding "still recording?" ask was posted, or nil if none
    /// is. Non-nil suspends the interval entirely — see
    /// `RecordingConfirmationPolicy`.
    private(set) var confirmationPromptedAt: Date?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        recorderFactory: @MainActor @escaping () async -> any RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        maxDuration: TimeInterval = 14400,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        verboseDiagnostics: @escaping () -> Bool = { false },
        recordOnly: @escaping () -> Bool = { false },
        recordOnlyDestination: @escaping () -> RecordOnlyDestination = {
            .unscoped(AppPaths.recordingsDir)
        },
        notifier: any AppNotifying = SilentNotifier(),
        nowProvider: @escaping () -> Date = Date.init,
        sleepProvider: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        },
        pidAliveCheck: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 },
        sleepBlocker: (any RecordingSleepBlocking)? = nil,
        confirmationPolicy: RecordingConfirmationPolicy = RecordingConfirmationPolicy(),
        salvageInterrupted: @escaping () -> Int = {
            DualSourceRecorder.recoverCrashedRecordings(minAge: 0)
        },
    ) {
        self.recorderFactory = recorderFactory
        self.pipelineQueue = pipelineQueue
        self.pollInterval = pollInterval
        self.maxDuration = maxDuration
        self.noMic = noMic
        self.micDeviceUID = micDeviceUID
        self.verboseDiagnostics = verboseDiagnostics
        self.recordOnly = recordOnly
        self.recordOnlyDestination = recordOnlyDestination
        self.notifier = notifier
        self.nowProvider = nowProvider
        self.sleepProvider = sleepProvider
        self.pidAliveCheck = pidAliveCheck
        self.sleepBlocker = sleepBlocker
        self.confirmationPolicy = confirmationPolicy
        self.salvageInterrupted = salvageInterrupted
    }

    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    // MARK: - Shutdown

    /// Shutdown entry point (app quit, tests): cancels the manual-recording
    /// monitor and drops the in-flight recorder without finalizing it — unlike
    /// `stopManualRecording()`, nothing is stopped-and-enqueued here. Returns
    /// the loop to `.idle`.
    func stop() {
        cleanupManualRecording()
        update { next in
            next.phase = .idle
            next.detail = ""
        }
        logger.info("WatchLoop stopped")
    }

    // MARK: - Manual Recording

    func startManualRecording(pid: pid_t, appName: String, title: String) async throws {
        try await startManualRecording(
            source: .forApp(pid: pid, noMic: noMic),
            appName: appName,
            title: title,
        )
    }

    /// Record the microphone with no process tap, for a meeting that happens in
    /// the room rather than in an app (issue #633).
    ///
    /// Deliberately ignores `noMic`: that setting decides whether an *app*
    /// recording also takes the microphone, and honouring it here would turn
    /// this into a recording of nothing. Keeping the entry point out of reach
    /// while it is set is the menu's job, not this one's — a caller that got
    /// here asked for the microphone by name.
    func startMicrophoneRecording() async throws {
        try await startManualRecording(
            source: .micOnly,
            appName: ManualRecordingInfo.microphoneAppName,
            title: ManualRecordingInfo.microphoneTitle,
        )
    }

    /// "Record Meeting": tap the whole system output and record the microphone,
    /// for a meeting in the room where remote colleagues play through the
    /// speakers rather than headphones.
    ///
    /// Unlike `startMicrophoneRecording`, `noMic` *is* honoured here — the same
    /// "No Microphone (app audio only)" setting an app recording reads. Dropping
    /// the mic channel is the right response to it for this source (the system
    /// tap still captures everything), where refusing outright is the right
    /// response for a microphone-only source that would otherwise record
    /// nothing under it.
    func startMeetingRecording() async throws {
        try await startManualRecording(
            source: .forSystem(noMic: noMic),
            appName: ManualRecordingInfo.meetingAppName,
            title: ManualRecordingInfo.meetingTitle,
        )
    }

    private func startManualRecording(
        source: RecordingSource,
        appName: String,
        title: String,
    ) async throws {
        guard state != .recording else {
            logger.warning("Cannot start manual recording — already recording")
            return
        }

        // Gate on what this path needs, not on overall health (see `blocksRecording`).
        let health = await permissionChecker()
        if let refusal = health.recordingRefusalReason(for: source) {
            throw RecorderError.permissionDenied(refusal)
        }

        let recorder = await recorderFactory()
        try recorder.start(
            source: source, micDeviceUID: micDeviceUID,
            debugLogging: verboseDiagnostics(),
        )

        // Taken only once capture is actually open: a start that threw above
        // would otherwise leave the Mac awake for a recording that never
        // happened, and nothing releases an assertion no recording owns.
        sleepBlocker?.hold(reason: "Meeting Transcriber is recording")
        confirmedAt = nowProvider()
        recordingStartedAt = nowProvider()
        confirmationPromptedAt = nil

        let pid = source.appPID
        activeRecorder = recorder
        update { next in
            next.phase = .recording
            next.manualRecordingInfo = ManualRecordingInfo(pid: pid, appName: appName, title: title)
            next.detail = "Recording: \(title)"
            // A failure from a previous recording has been superseded: this one
            // got as far as opening capture. Without this the menu's issue row
            // would keep naming an error the user has visibly moved past, and
            // the icon would keep its red dot through a healthy recording.
            next.lastError = nil
        }

        manualRecordingTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorManualRecording(pid: pid)
        }

        let target = pid.map { "PID \($0)" } ?? "no target process"
        logger.info("Manual recording started for \(appName) (\(target)): \(title, privacy: .private)")
    }

    func stopManualRecording() {
        guard let recorder = activeRecorder, let info = manualRecordingInfo else { return }

        manualRecordingTask?.cancel()
        manualRecordingTask = nil

        var failureMessage: String?
        do {
            let recording = try recorder.stop()
            enqueueRecording(
                title: info.title, appName: info.appName, recording: recording, trigger: .manual,
            )
        } catch {
            logger.error("Failed to stop manual recording: \(error.localizedDescription, privacy: .public)")
            failureMessage = error.localizedDescription
            salvageInterruptedRecording()
        }

        sleepBlocker?.release()
        confirmationPromptedAt = nil
        recordingStartedAt = nil
        activeRecorder = nil
        update { next in
            next.phase = .idle
            next.manualRecordingInfo = nil
            next.detail = ""
            if let failureMessage { next.lastError = failureMessage }
        }
    }

    private func cleanupManualRecording() {
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        sleepBlocker?.release()
        confirmationPromptedAt = nil
        recordingStartedAt = nil
        activeRecorder = nil
        update { next in next.manualRecordingInfo = nil }
    }

    /// Rescue whatever the recorder had written when `stop()` failed.
    ///
    /// This is the "if an error occurs, save the rest" path. A failed stop is not
    /// an empty recording: the per-track WAVs and the in-progress marker are
    /// still on disk, which is precisely the shape `recoverCrashedRecordings`
    /// re-mixes after a crash. Until now that only ran at launch, so a stop
    /// failure meant the audio sat in the staging directory for however long it
    /// took the user to next quit and reopen the app — and looked, from the
    /// menu, exactly like a recording that was lost.
    ///
    /// `minAge: 0` is safe *because* this runs on the stop path: the guard the
    /// age window normally provides is "don't re-mix a recording that is still
    /// being written", and the only recording this app ever has is the one that
    /// just stopped. Recordings that finished cleanly have a `_mix.wav` and are
    /// skipped by `crashedRecordingStems` regardless of age.
    private func salvageInterruptedRecording() {
        let recovered = salvageInterrupted()
        guard recovered > 0 else {
            logger.warning("Stop failed and nothing was recoverable from the staging directory")
            return
        }
        logger.info("Salvaged \(recovered) recording(s) after a failed stop")
        // The re-mix produced a `_mix.wav` that no job tracks; the orphan scan
        // is what turns it into one, and it is the same call the launch path
        // makes, so the recording is processed exactly as any other.
        Task { [pipelineQueue] in
            await pipelineQueue?.recoverOrphanedRecordings()
        }
        notifier.notify(
            title: "Recording Salvaged",
            body: "Stopping the recording failed, but the audio was recovered and is being processed.",
            urgency: .timeSensitive,
        )
    }

    // MARK: - Still-recording confirmation

    /// The user answered the "still recording?" ask. Resets the clock so the
    /// next ask is a full interval away, and clears the outstanding prompt so
    /// the grace period stops running.
    ///
    /// A no-op when nothing is recording: the notification action can arrive
    /// after the recording already stopped (the user unlocks the Mac and clicks
    /// a banner from twenty minutes ago), and confirming then would seed
    /// `confirmedAt` for a recording that no longer exists.
    func confirmStillRecording() {
        guard state == .recording else { return }
        confirmedAt = nowProvider()
        confirmationPromptedAt = nil
        logger.info("Recording confirmed by the user — next check in \(self.confirmationPolicy.interval, privacy: .public)s")
    }

    /// One confirmation step, run from the manual-recording monitor's poll.
    /// Returns false when the recording was stopped, so the monitor can exit
    /// rather than poll a loop that is now idle.
    ///
    /// Lives here rather than in the monitor's extension because it mutates
    /// `confirmationPromptedAt`, which is `private(set)` and so unreachable from
    /// another file.
    func stepConfirmation(now: Date) -> Bool {
        switch confirmationPolicy.step(
            now: now, confirmedAt: confirmedAt, promptedAt: confirmationPromptedAt,
        ) {
        case .wait:
            return true

        case .prompt:
            confirmationPromptedAt = now
            // `.timeSensitive`: the whole point is to reach someone who is in a
            // meeting, and a meeting is exactly when Focus is on. A suppressed
            // ask is an ask nobody can answer, which the grace period below
            // would then read as an abandoned recording and stop.
            notifier.notify(
                title: RecordingConfirmationPolicy.promptTitle,
                body: confirmationPolicy.promptBody,
                urgency: .timeSensitive,
            )
            return true

        case .stopUnconfirmed:
            logger.info("Still-recording check went unanswered — stopping and saving")
            stopManualRecording()
            notifier.notify(
                title: "Recording Stopped",
                body: RecordingConfirmationPolicy.timedOutBody,
                urgency: .timeSensitive,
            )
            return false
        }
    }

    // MARK: - Helpers

    private func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
    ) {
        if recordOnly() {
            do {
                try writeRecordOnlySidecar(
                    title: title,
                    appName: appName,
                    recording: recording,
                    trigger: trigger,
                    // Participants (Teams roster) were only ever read on the
                    // auto-detected meeting path, which no longer exists — the
                    // sidecar field stays for schema compatibility with
                    // previously written sidecars.
                    participants: [],
                )
            } catch {
                // Error left redacted: a sidecar/WAV write error embeds the
                // meeting-title-derived basename in its description.
                logger.error("Record-only: \(error.localizedDescription)")
                update { next in
                    next.lastError = "Record-only output failed: \(error.localizedDescription)"
                }
                // Record-only performs no state transition, so this notification
                // is the entire report that a recording was lost. It breaks
                // through Focus on the same test as `captureAlert`: a failed
                // write has no benign reading.
                notifier.notify(
                    title: "Record-only output failed",
                    body: error.localizedDescription,
                    urgency: .timeSensitive,
                )
            }
            return
        }

        let job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            meetingStartTime: recording.recordingStartDate,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title, privacy: .private)")
    }

    /// Single funnel through which every observable-field mutation flows.
    /// Build the next snapshot, hand it to `apply` to commit only the
    /// fields that actually changed, and let `apply` fire `onStateChange`
    /// on a phase transition. Co-located mutations stay coherent
    /// (a phase-change-plus-detail-update is one funnel call, not two
    /// separate property writes that consumers could observe mid-flight).
    private func update(_ transform: (inout WatchLoopState) -> Void) {
        var next = snapshot
        transform(&next)
        apply(next)
    }

    /// Commit a new snapshot field-wise. Each `if old != new { old = new }`
    /// guard avoids gratuitous `@Observable` invalidations for fields the
    /// transform left alone; emit `onStateChange` if the phase moved.
    private func apply(_ next: WatchLoopState) {
        let oldPhase = state
        if state != next.phase { state = next.phase }
        if lastError != next.lastError { lastError = next.lastError }
        if detail != next.detail { detail = next.detail }
        if manualRecordingInfo != next.manualRecordingInfo {
            manualRecordingInfo = next.manualRecordingInfo
        }
        if oldPhase != next.phase {
            onStateChange?(oldPhase, next.phase)
        }
    }

    /// Map WatchLoop state to TranscriberState for compatibility with existing UI.
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .recording: .recording
        case .error: .error
        }
    }
}

/// Pair of URLs used by `WatchLoop` when persisting record-only output: the
/// `scope` URL is what `startAccessingSecurityScopedResource()` is called on
/// (the bookmark-resolved parent the user actually picked), and `writeDir` is
/// the sub-path under that scope where the WAV + sidecar files land.
///
/// The split exists because Apple's security-scoped-bookmark API only grants
/// access on the URL that resolved from the bookmark — calling start-access
/// on a *child* path silently fails inside the App Store sandbox while
/// appearing to work in the unsandboxed Homebrew build. The factory methods
/// below make the two cases (real bookmark vs. transient app dir) explicit
/// at every call site.
struct RecordOnlyDestination: Equatable {
    let scope: URL
    let writeDir: URL

    /// Production path: `parent` is the user-picked Output Folder (potentially
    /// resolved from a security-scoped bookmark) and the WAVs land under
    /// `parent/recordings/` so a Syncthing or rsync pair has a stable subtree.
    static func production(parent: URL) -> Self {
        Self(
            scope: parent,
            writeDir: parent.appendingPathComponent("recordings", isDirectory: true),
        )
    }

    /// Test/default path: no security scope to manage — `scope == writeDir`,
    /// so start-access is a harmless no-op and the writer hits `url` directly.
    static func unscoped(_ url: URL) -> Self {
        Self(scope: url, writeDir: url)
    }
}
