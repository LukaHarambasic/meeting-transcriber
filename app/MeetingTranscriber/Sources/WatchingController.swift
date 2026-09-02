import Foundation
import Observation

// MARK: - WatchingController

/// Owns the manual-recording lifecycle: the active `WatchLoop`, the
/// per-recording recorder factory (which installs live-transcription sinks),
/// and the state-change handler that drives channel-health monitoring + error
/// notifications.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). Unlike the earlier leaf controllers, watching is a hub: it
/// reaches across the already-extracted siblings — `pipeline` (to ensure the
/// queue and pass it to the loop), `channelHealth` (start/stop on state
/// transitions), `permissions` (seed the loop's permission checker), and
/// `liveTranscription` (attach live sinks to each recorder). It holds those
/// siblings as direct references (not an `AppState` back-reference) since they
/// are all constructed before this controller in `AppState.init`.
///
/// Testability seam: `ensureMicAccess` is injectable (default to the production
/// `Permissions.ensureMicrophoneAccess`) so a manual start can be exercised
/// without real TCC.
@Observable
@MainActor
final class WatchingController {
    var watchLoop: WatchLoop?

    /// See `defaultStartJoinTimeout`.
    private let startJoinTimeout: Duration

    /// Set while `startManualRecording` is in flight, i.e. from the call until
    /// `watchLoop` holds the manual loop. Covers the window before the loop
    /// exists, which is why `isManualRecording` reads this instead of the loop
    /// alone.
    var manualStartTask: Task<ManualRecordingStartResult, Never>?

    let settings: AppSettings
    private let notifier: any AppNotifying
    private let pipeline: PipelineController
    private let channelHealth: ChannelHealthController
    private let permissions: PermissionsController
    private let liveTranscription: LiveTranscriptionCoordinator

    /// Microphone-access gate. Injectable so tests skip the real TCC prompt; the
    /// return value is intentionally ignored (the loop is created regardless, and
    /// surfaces a permission problem through its own `permissionChecker`).
    private let ensureMicAccess: () async -> Bool

    /// Screen-Recording request, fired at a manual recording start. Injectable
    /// so tests skip the real TCC prompt.
    ///
    /// Asking is what registers the app in the Screen Recording list at all —
    /// preflighting never does — and until it is listed there is nothing for
    /// the user to switch on. The result is ignored: a tap with neither grant
    /// still returns `noErr` and captures silence rather than failing outright,
    /// so a manual start proceeds either way and the health check reports the
    /// state.
    private let requestScreenRecording: () -> Void

    /// Recorder factory, injectable so a test can assert that a start succeeded,
    /// or make one fail on demand, without opening the machine's real input
    /// device. `DualSourceRecorder` writes into `AppPaths.recordingsDir`, the
    /// production staging directory that orphan recovery scans, which is not
    /// somewhere a unit test may leave files. (It does start on the hosted CI
    /// runners, so this is about where the bytes land, not about whether capture
    /// works.)
    private let makeRecorder: @MainActor () -> any RecordingProvider

    /// Builds the power assertion each recording holds. Injectable so a test can
    /// hand in a spy and assert the recording takes it and gives it back — the
    /// production type talks to IOKit, which a unit test has no business asking
    /// anything.
    private let makeSleepBlocker: @MainActor () -> any RecordingSleepBlocking

    /// The still-recording check's timings, threaded through to each `WatchLoop`
    /// so a test can shorten them without waiting out half an hour.
    private let confirmationPolicy: RecordingConfirmationPolicy

    /// Re-mixes tracks left behind by an interruption, returning how many
    /// recordings it rescued. Injectable for the same reason the loop's copy is:
    /// the production implementation writes into the real staging directory.
    private let recoverInterrupted: () -> Int

    init(
        settings: AppSettings,
        notifier: any AppNotifying,
        pipeline: PipelineController,
        channelHealth: ChannelHealthController,
        permissions: PermissionsController,
        liveTranscription: LiveTranscriptionCoordinator,
        ensureMicAccess: @escaping () async -> Bool = { await Permissions.ensureMicrophoneAccess() },
        requestScreenRecording: @escaping () -> Void = { Permissions.ensureScreenRecordingAccess() },
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { DualSourceRecorder() },
        makeSleepBlocker: @escaping @MainActor () -> any RecordingSleepBlocking = {
            RecordingPowerAssertion()
        },
        confirmationPolicy: RecordingConfirmationPolicy = RecordingConfirmationPolicy(),
        recoverInterrupted: @escaping () -> Int = {
            DualSourceRecorder.recoverCrashedRecordings(minAge: 0)
        },
    ) {
        self.settings = settings
        self.notifier = notifier
        self.pipeline = pipeline
        self.channelHealth = channelHealth
        self.permissions = permissions
        self.liveTranscription = liveTranscription
        self.ensureMicAccess = ensureMicAccess
        self.requestScreenRecording = requestScreenRecording
        self.startJoinTimeout = startJoinTimeout
        self.makeRecorder = makeRecorder
        self.makeSleepBlocker = makeSleepBlocker
        self.confirmationPolicy = confirmationPolicy
        self.recoverInterrupted = recoverInterrupted
    }

    // MARK: - Derived

    /// Whether a recording is currently in progress (the watch loop is in its
    /// `.recording` state).
    var isRecording: Bool {
        watchLoop?.state == .recording
    }

    /// Whether a manual (app-picker) recording owns the loop, or is on its way
    /// to owning it. Exposed because the automation API turns a start that
    /// refuses in this state into a 409.
    ///
    /// The in-flight half matters: `startManualRecording` assigns `watchLoop`
    /// only after awaiting the mic gate, so reading the loop alone reports
    /// "no manual recording" for the whole of that window.
    var isManualRecording: Bool {
        manualStartTask != nil || watchLoop?.isManualRecording == true
    }

    // MARK: - Settling in-flight starts (shared by both control surfaces)

    /// How long a control call waits for an in-flight start before giving up.
    /// Generous against the ~2 s warm start, short enough that a wedged request
    /// still answers well inside a polling controller's patience. Injectable so
    /// a test can pin the give-up path without waiting it out.
    static let defaultStartJoinTimeout: Duration = .seconds(20)

    /// Bounded wait for the manual start alone, for a caller that just launched
    /// one and has to answer for how it went.
    ///
    /// The task parks on the microphone TCC prompt, which on a menu-bar app can
    /// sit unanswered behind other windows for as long as nobody looks. Awaiting
    /// its value directly would hold an HTTP handler and its connection open for
    /// exactly that long. The task clears `manualStartTask` in its own `defer`,
    /// so polling that is polling its completion, and giving up here does not
    /// cancel a start the user may still be about to answer.
    func joinManualStart() async -> Bool {
        await join { self.manualStartTask != nil }
    }

    /// Bounded wait for an in-flight start. True when it settled, false on
    /// expiry or cancellation. See `joinManualStart` for why the bound and the
    /// polling shape are what they are.
    private func join(while inFlight: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + startJoinTimeout
        while inFlight() {
            if Task.isCancelled { return false }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: - Manual recording

    func startManualRecording(pid: pid_t, appName: String, title: String) {
        beginManualRecording(.app(pid: pid, appName: appName, title: title))
    }

    /// Record the system microphone with no app audio, for a meeting happening
    /// in the room (issue #633). Same ownership rules as the app path.
    ///
    /// Refused outright while "No Microphone (app audio only)" is set. The menu
    /// disables the item for the same reason, but a disabled control cannot be
    /// the enforcement: every other entry point onto this path (the automation
    /// API, a future shortcut) would otherwise record the one thing that setting
    /// exists to keep off tape, with no compile error and nothing failing.
    func startMicrophoneRecording() {
        guard !settings.noMic else {
            notifier.notify(
                title: "Microphone Recording Refused",
                body: MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason ?? "",
            )
            return
        }
        beginManualRecording(.microphone)
    }

    /// Start a manual recording, or refuse. Returns the start's task so a caller
    /// that has to answer for the outcome can await it; nil means the ownership
    /// guard below refused before anything began.
    @discardableResult
    func beginManualRecording(
        _ request: ManualRecordingRequest,
    ) -> Task<ManualRecordingStartResult, Never>? {
        // Without this a second start replaces the field while the first is
        // still in flight, whose `defer` then clears the second's registration
        // and reopens the window.
        guard manualStartTask == nil else { return nil }
        // Refuse while one is already recording. Without this the assignment
        // below replaces `watchLoop` without stopping the live loop, so its
        // recording is never enqueued while its recorder keeps capturing,
        // retained by its own monitor task and reachable by nothing (#624).
        // The picker disables Start for the same reason, but it cannot be the
        // enforcement: a recording can begin between opening it and pressing.
        guard watchLoop?.isManualRecording != true else { return nil }
        let task = Task { @MainActor in
            defer { manualStartTask = nil }
            return await performManualRecording(request)
        }
        // Assigned after construction, not inline: the body is `@MainActor` and
        // so is this, so it cannot run before we return, and the field is set
        // for the whole window either way.
        manualStartTask = task
        return task
    }

    /// Body of `beginManualRecording`, split out so the task closure stays a
    /// two-liner and the work is readable on its own.
    private func performManualRecording(
        _ request: ManualRecordingRequest,
    ) async -> ManualRecordingStartResult {
        _ = await ensureMicAccess()

        pipeline.ensureQueue()

        let loop = WatchLoop(
            recorderFactory: makeRecorderFactory(),
            pipelineQueue: pipeline.queue,
            noMic: settings.noMic,
            micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
            recordOnly: { [settings] in settings.recordOnly },
            recordOnlyDestination: { [settings] in
                .production(parent: settings.effectiveOutputDir)
            },
            notifier: notifier,
            sleepBlocker: makeSleepBlocker(),
            confirmationPolicy: confirmationPolicy,
        )
        watchLoop = loop

        // Wire channel-health monitoring + error notification on state
        // transitions, so the red-tint indicator and asymmetric-silence
        // notification work for manual recordings.
        attachStateChangeHandler(to: loop)

        // Use cached health check result instead of live probe
        if let health = permissions.health {
            loop.permissionChecker = { health }
        }

        // A manual tap start has no moment that asks for Screen Recording up
        // front — on a fresh install the tap would silently capture silence
        // (issue #524). A no-op once already granted.
        if request.capturesAppAudio { requestScreenRecording() }

        do {
            switch request {
            case let .app(pid, appName, title):
                try await loop.startManualRecording(pid: pid, appName: appName, title: title)

            case .microphone:
                try await loop.startMicrophoneRecording()

            case .meeting:
                try await loop.startMeetingRecording()
            }
            // Read the title back off the loop rather than re-deriving it here:
            // the loop stamps it into `manualRecordingInfo`, and that is the
            // same value the job and the record-only sidecar get, so the
            // notification cannot end up naming the recording something else.
            notifier.notify(
                title: "Manual Recording",
                body: "Recording: \(loop.manualRecordingInfo?.title ?? "")",
            )
            return .started
        } catch {
            notifier.notify(title: "Error", body: error.localizedDescription)
            watchLoop = nil
            // The permission arm is told apart by the error the gate raises, not
            // by re-asking the health check here: only the loop knows which
            // source it was about to record, and the whole point of that gate is
            // that the answer differs per source.
            guard let recorderError = error as? RecorderError,
                  case .permissionDenied = recorderError
            else { return .failed }
            return .permissionRefused
        }
    }

    func stopManualRecording() {
        watchLoop?.stopManualRecording()
        watchLoop = nil
    }

    /// The user confirmed the recording should keep going, from the
    /// "Still recording?" notification.
    func confirmStillRecording() {
        watchLoop?.confirmStillRecording()
    }

    // MARK: - Sleep and wake

    /// Finalize and enqueue the active recording because the machine is about to
    /// sleep.
    ///
    /// The power assertion each recording holds
    /// (`RecordingPowerAssertion`) stops *idle* sleep, so in the reported
    /// failure — screen darkens, Mac sleeps, recording gone — this handler no
    /// longer fires at all. It exists for the sleeps an assertion cannot block:
    /// a closed lid, Apple menu → Sleep, and a critically low battery. In those,
    /// the process is suspended and the audio devices torn out from under it, so
    /// a recording left running comes back on wake as a half-written file with
    /// no clean end.
    ///
    /// Stopping is the same path the menu's Stop item takes, so the recording is
    /// mixed and handed to the pipeline exactly as a user-stopped one. macOS
    /// waits for this notification's observers before sleeping, and if it stops
    /// waiting mid-mix the process is suspended rather than killed: the mix
    /// resumes on wake, and if even that fails the in-progress marker and tracks
    /// are still on disk for `recoverAfterWake()`.
    func finalizeForSleep() {
        guard watchLoop?.isManualRecording == true else { return }
        notifier.notify(
            title: "Recording Saved",
            body: "The Mac is going to sleep, so the recording was stopped and saved.",
            urgency: .timeSensitive,
        )
        stopManualRecording()
    }

    /// After wake: re-mix and enqueue anything a sleep truncated.
    ///
    /// `finalizeForSleep()` handles the sleeps we are told about, but not every
    /// interruption gives notice — a kernel panic, a battery that ran out, or a
    /// sleep whose observers were cut short mid-mix all leave per-track WAVs and
    /// an in-progress marker with no `_mix.wav`. That was already recoverable,
    /// but only at launch, which for a menu-bar app that never quits could be
    /// weeks away.
    ///
    /// The guard matters: with a recording still live, `minAge: 0` would re-mix
    /// tracks that are still being written to.
    func recoverAfterWake() {
        guard watchLoop?.isManualRecording != true else { return }
        let recovered = recoverInterrupted()
        guard recovered > 0 else { return }
        Task { [pipeline] in
            await pipeline.queue.recoverOrphanedRecordings()
        }
        notifier.notify(
            title: "Recording Recovered",
            body: "A recording interrupted by sleep was recovered and is being processed.",
            urgency: .standard,
        )
    }

    // MARK: - Recorder factory

    /// Build the `recorderFactory` closure for `WatchLoop`. Returns a fresh
    /// `DualSourceRecorder` on each invocation; when live captions are eligible,
    /// the coordinator installs mic + app live sinks that pipe captured buffers to
    /// the `LiveTranscriptionController`. `async` so the coordinator can await the
    /// prior recording's stop-time flush before reusing a kept EOU session.
    private func makeRecorderFactory() -> @MainActor () async -> any RecordingProvider {
        { [weak self, makeRecorder] in
            let recorder = makeRecorder()
            // Live captions tap the concrete recorder's buffer sinks, so this is
            // the production recorder or nothing. An injected double has no
            // sinks and needs none: captions are off in every test that uses one.
            if let dualSource = recorder as? DualSourceRecorder {
                await self?.liveTranscription.attachSinks(to: dualSource)
            }
            return recorder
        }
    }

    // MARK: - State-change handler

    /// Attaches the state-change callback that drives channel-health monitoring
    /// and post-`.error` notifications for a manual recording.
    private func attachStateChangeHandler(to loop: WatchLoop) {
        loop.onStateChange = { [weak self, weak loop, notifier] oldState, newState in
            // Leaving `.recording` (manual stop or mid-recording cancel — both
            // route through this transition) is the stop signal. Flush the live
            // pipeline here so the pending tail utterance is committed before
            // the next recording's prepareForNextRecording() clears state. The
            // flush runs after `recorder.stop()` (WatchLoop stops the recorder
            // before this transition fires); the buffered tail lives in the
            // streaming actors, not the recorder, so it survives the stop.
            if oldState == .recording {
                Task { @MainActor in await self?.liveTranscription.flush() }
            }
            switch newState {
            case .recording:
                // No source means no live recording, so there are no channels to
                // watch and starting the monitor would only assume a topology.
                if let source = self?.watchLoop?.activeRecordingSource {
                    self?.channelHealth.start(source: source) { [weak self] in
                        self?.watchLoop?.activeRecorder
                    }
                }

            case .error:
                if let err = loop?.lastError {
                    notifier.notify(title: "Error", body: err)
                }
                self?.channelHealth.stop()

            default:
                self?.channelHealth.stop()
            }
        }
    }
}
