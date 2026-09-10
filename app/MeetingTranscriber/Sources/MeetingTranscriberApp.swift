import Combine
import SwiftUI

extension Notification.Name {
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
    static let showSettings = Notification.Name("showSettings")
    static let closeSettings = Notification.Name("closeSettings")
    /// Posted by the debug RPC `/action/openNotes` / `/action/closeNotes`, so a
    /// driver can put the notes panel on screen without a synthetic keystroke.
    static let showNotes = Notification.Name("showNotes")
    static let closeNotes = Notification.Name("closeNotes")
}

/// Renders the menu-bar icon and ticks the animation frame in its own
/// view body. Keeping the timer + frame @State scoped here means the
/// surrounding `MeetingTranscriberApp` scene body never re-evaluates on
/// each tick — only this view does. Without this isolation, animating
/// badges (recording, transcribing, …) would cascade re-renders through
/// every open Window.
private struct AnimatedMenuBarIcon: View {
    let badge: BadgeKind
    /// Whether to composite the red error dot. One flag, not the four overlay
    /// inputs this replaces — see `MenuBarIcon` for why colour is now reserved
    /// for a single meaning.
    let errorOverlay: Bool

    @State private var animationFrame = 0
    // `.default` (not `.common`) so the timer never fires inside the status-bar
    // menu's tracking loop — see MenuBarIcon.animationRunLoopMode for why.
    //
    // The interval comes from `MenuBarIcon` rather than being written here: it
    // is only meaningful against `frameCount`, and this file holding a separate
    // 0.4 s was how the animation ended up running at 2.5 fps.
    private let iconTimer = Timer.publish(
        every: MenuBarIcon.frameInterval, on: .main, in: MenuBarIcon.animationRunLoopMode,
    ).autoconnect()

    var body: some View {
        Image(nsImage: MenuBarIcon.image(
            badge: badge,
            animationFrame: animationFrame,
            errorOverlay: errorOverlay,
        ))
        .onReceive(iconTimer) { _ in
            let next = MenuBarIcon.nextFrame(animationFrame, badge: badge)
            if next != animationFrame {
                animationFrame = next
            }
        }
    }
}

/// Bridges a SwiftUI `Window` scene down to its hosting `NSWindow` so
/// window-level AppKit properties can be configured. macOS 14 (our deployment
/// target) has no scene-level `.windowLevel` / collection-behavior modifiers
/// (those are macOS 15+), so a zero-size representable placed in the content's
/// `.background` is the idiomatic way to reach the window. Mirrors the
/// `AccessibleTextField` `NSViewRepresentable` idiom already used in the naming
/// UI. `configure` runs once the view is attached and on subsequent updates;
/// the window properties it sets are sticky and idempotent.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let window = nsView.window { configure(window) }
    }
}

/// The notes panel's three scene-level reactions, in a modifier of their own.
///
/// Not three `.onChange` modifiers in the scene body: added there they pushed
/// its type-check to 321 ms against the package's 300 ms hard limit, the same
/// budget that already forced the `MenuBarView` and `AppState` splits. A
/// modifier gets its own `body`, so the cost lands in a separate budget.
///
/// Takes plain values and closures rather than `AppState`, which keeps it
/// independent of the observation graph and testable on its own.
private struct NotesSceneWiring: ViewModifier {
    let isVisible: Bool
    let hotkeyEnabled: Bool
    let isRecording: Bool
    let onVisibilityChange: (Bool) -> Void
    let onHotkeySettingChange: (Bool) -> Void
    let onRecordingChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isVisible) { _, visible in onVisibilityChange(visible) }
            .onChange(of: hotkeyEnabled, initial: true) { _, enabled in onHotkeySettingChange(enabled) }
            .onChange(of: isRecording) { _, _ in onRecordingChange() }
    }
}

@main
struct MeetingTranscriberApp: App {
    // `askDeliverability` is wired here rather than derived from the notifier:
    // this is the only place that knows the notifier IS a `NotificationManager`,
    // and `WatchingController` deliberately defaults it away from production so
    // no test can reach `UNUserNotificationCenter.current()` by omission.
    // Not trailing-closure: it would detach the closure from the argument label
    // that says what it is, in a call whose other argument is also a dependency.
    @State private var appState = AppState(
        notifier: NotificationManager.shared,
        // swiftlint:disable:next trailing_closure
        askDeliverability: { await NotificationManager.shared.alertDeliverability() },
    )
    @State private var captionsWindow: LiveCaptionsWindowController?
    /// Built on first use, like `captionsWindow`: the panel is an `NSPanel`
    /// rather than a SwiftUI `Window` scene because it needs
    /// `.nonactivatingPanel` and `sharingType = .none`, and neither is reachable
    /// from a scene modifier on the macOS 14 floor.
    @State private var notesWindow: NotesWindowController?
    /// Held for the process lifetime while the setting is on; releasing it
    /// unregisters the ⌥⌘N claim with the Carbon Event Manager.
    @State private var notesHotkey: GlobalHotkey?
    @Environment(\.openWindow)
    private var openWindow

    init() {
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        // Temp-file cleanup moved into the queue-build recovery flow
        // (`PipelineController.makeQueue`): a crashed `_app_raw.tmp` must be
        // re-mixed by `recoverCrashedRecordings` BEFORE it's cleaned up, so the
        // delete can no longer run first here (issue #379).
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: appState.currentStatus,
                issue: appState.currentIssue,
                pipelineQueue: appState.pipelineQueue,
                onRecordMeeting: { appState.watching.startMeetingRecording() },
                manualRecordingPendingOrActive: appState.watching.isManualRecording,
                onStopManualRecording: appState.isManualRecording ? {
                    appState.watching.stopManualRecording()
                } : nil,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    bringWindowToFront(id: "settings")
                },
                onOpenNotes: toggleNotes,
                onNameSpeakers: appState.hasPendingSpeakerNamingJobs ? {
                    bringWindowToFront(id: "speaker-naming")
                } : nil,
                onQuit: quit,
            )
        } label: { // swiftlint:disable:this closure_body_length
            Label {
                Text(appState.currentStateLabel)
            } icon: {
                AnimatedMenuBarIcon(
                    badge: appState.currentBadge,
                    // The dot and the menu's issue row read the same
                    // `currentIssue`, so the icon can never show a problem the
                    // menu declines to name — the failure that sent the user
                    // looking at a red mark next to the word "Idle".
                    errorOverlay: appState.hasIssue,
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                bringWindowToFront(id: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeSettings)) { _ in
                closeWindow(id: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showNotes)) { _ in
                appState.notes.open()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeNotes)) { _ in
                appState.notes.close()
            }
            .task {
                await appState.engines.preloadActiveModel()
            }
            .task {
                await appState.permissions.check()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Re-check permissions when the user returns to the app (e.g. from System
                // Settings after toggling a permission). Opening the menu bar dropdown
                // activates the app too, so this fires constantly — which is exactly why
                // the check behind it must stay device-free (`PermissionHealthCheck.runPassive`).
                // The debounce is a cheapness measure, never the thing keeping the audio
                // device shut.
                Task { @MainActor in
                    await appState.permissions.check(minimumInterval: 3)
                }
            }
            .modifier(notesWiring)
            .onChange(of: appState.shouldShowLiveCaptions, initial: true) { _, visible in
                let controller = captionsWindow ?? LiveCaptionsWindowController(state: appState.liveCaptions)
                captionsWindow = controller
                if visible {
                    controller.show()
                } else {
                    controller.hide()
                }
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            speakerNamingContent
                // Pin the naming window so it stays visible + on top while the
                // user works in other apps instead of vanishing on focus loss
                // (issue #504). Applied via the hosting NSWindow because macOS 14
                // has no scene-level window-level / collection-behavior modifier.
                .background(WindowAccessor { NamingWindowPolicy.apply(to: $0) })
                .onAppear {
                    // Close restored window if no naming data available (macOS state restoration)
                    if appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
                // Auto-close when the pending list drains. Covers RPC-driven
                // skip (`POST /action/skipNaming`), where the data layer
                // transitions but the UI callback never fires.
                .onChange(of: appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty) { _, isEmpty in
                    if isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.engines.whisperKit,
                parakeetEngine: appState.engines.parakeetEngine,
                // Share the pipeline's actor instance so both writers serialise on
                // the same `recognition_log.jsonl` file. Fallback only fires in the
                // test-only PipelineQueue init that intentionally leaves it nil.
                recognitionStatsLog: appState.pipeline.queue.recognitionStatsLog ?? RecognitionStatsLog(),
                // Same actor instance the pipeline writes to, so both writers
                // serialise on stage_timing.jsonl. Fallback fires only in the
                // test-only PipelineQueue init that leaves it nil.
                stageTimingLog: appState.pipeline.queue.stageTimingLog ?? StageTimingLog(),
                enrollmentDiarizerFactory: { FluidDiarizer(mode: appState.settings.diarizerMode) },
                namingDialogActive: appState.pipeline.queue.pendingSpeakerNaming != nil,
                pipelineBusy: appState.pipeline.queue.isProcessing,
                onSpeakerMutate: appState.pipeline.queue.refreshKnownSpeakerNames,
                pipelineQueue: appState.pipelineQueue,
                onDismissJob: dismissJob,
            )
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Speaker Naming Window

    @ViewBuilder private var speakerNamingContent: some View {
        if let data = appState.pipeline.queue.speakerNamingData(
            forJobID: appState.selectedNamingJobID,
        ) {
            VStack(spacing: 0) {
                speakerNamingPicker
                speakerNamingForm(data: data)
            }
        } else {
            Text("No speaker data available.")
                .padding()
        }
    }

    @ViewBuilder private var speakerNamingPicker: some View {
        if appState.pipeline.queue.pendingSpeakerNamingJobs.count > 1 {
            Picker("Meeting", selection: Binding(
                get: {
                    appState.selectedNamingJobID
                        ?? appState.pipeline.queue.pendingSpeakerNamingJobs.first?.id
                },
                set: { appState.selectedNamingJobID = $0 },
            )) {
                ForEach(appState.pipeline.queue.pendingSpeakerNamingJobs) { job in
                    Text(job.meetingTitle).tag(Optional(job.id))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func speakerNamingForm(
        data: PipelineQueue.SpeakerNamingData,
    ) -> some View {
        SpeakerNamingView(
            data: data,
            knownSpeakerNames: appState.pipeline.queue.knownSpeakerNames,
            currentDiarizerMode: appState.pipeline.queue.usedDiarizerMode(forJobID: data.jobID)
                ?? appState.settings.diarizerMode,
            pendingJobCount: appState.pipeline.queue.pendingSpeakerNamingJobs.count,
            onDismissRequest: { closeWindow(id: "speaker-naming") },
            onComplete: { result in
                appState.pipeline.queue.completeSpeakerNaming(jobID: data.jobID, result: result)
                if appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty {
                    closeWindow(id: "speaker-naming")
                } else {
                    appState.selectedNamingJobID =
                        appState.pipeline.queue.pendingSpeakerNamingJobs.first?.id
                }
            },
        )
    }

    // MARK: - Notes panel

    /// The notes wiring, constructed outside the scene body.
    ///
    /// Even as a single `.modifier(...)` call, building this inline left the
    /// body at 313 ms against a 300 ms limit: six arguments is six more
    /// expressions for the type-checker. An explicitly-typed property moves
    /// that cost into its own budget. The observable reads still happen during
    /// body evaluation, so the scene keeps tracking all three values.
    private var notesWiring: NotesSceneWiring {
        NotesSceneWiring(
            isVisible: appState.notes.isVisible,
            hotkeyEnabled: appState.settings.notesHotkeyEnabled,
            isRecording: appState.watching.isRecording,
            onVisibilityChange: applyNotesVisibility,
            onHotkeySettingChange: applyNotesHotkeySetting,
            onRecordingChange: retargetNotes,
        )
    }

    /// Show or hide the notes panel, building it on first use.
    ///
    /// Split out of the scene body for the type-check budget the package
    /// enforces as an error, and because the hosting view has to be constructed
    /// exactly once: a fresh `NSHostingView` per toggle would drop the text
    /// view's first responder status and the caret with it.
    private func applyNotesVisibility(_ visible: Bool) {
        let controller: NotesWindowController = notesWindow ?? {
            let host = NSHostingView(rootView: NotesEditorView(controller: appState.notes))
            let made = NotesWindowController(contentView: host)
            notesWindow = made
            return made
        }()
        if visible {
            controller.show()
            // The panel is `.nonactivatingPanel`, so it can take keys without
            // pulling the whole app forward, but it does need to *be* the key
            // window for typing to reach it.
            NSApp.activate(ignoringOtherApps: true)
        } else {
            controller.hide()
        }
    }

    /// A recording starting or stopping changes where a note belongs.
    /// Re-targeting reloads from the new destination rather than carrying text
    /// across: words typed before a meeting started were not said in it.
    ///
    /// Named rather than a closure literal at the call site, which is the shape
    /// SwiftLint's `trailing_closure` rule wants here.
    private func retargetNotes() {
        appState.notes.retarget()
    }

    /// The menu row's action. Named rather than a closure literal at the call
    /// site, which is what SwiftLint's `trailing_closure` rule wants in an
    /// argument list whose neighbours are closures.
    private func toggleNotes() {
        appState.notes.toggle()
    }

    /// Register or release the ⌥⌘N claim to match the setting.
    private func applyNotesHotkeySetting(_ enabled: Bool) {
        guard enabled else {
            notesHotkey?.stop()
            notesHotkey = nil
            return
        }
        guard notesHotkey == nil else { return }
        notesHotkey = GlobalHotkey { appState.notes.toggle() }
    }

    // MARK: - UI Actions

    /// Named rather than a closure literal at the call site: as the final
    /// argument, a closure trips SwiftLint's `trailing_closure` rule.
    private func dismissJob(_ id: UUID) {
        appState.pipelineQueue.removeJob(id: id)
    }

    private func openLastProtocol() {
        if let job = appState.pipeline.queue.completedJobs.last,
           let path = job.protocolPath ?? job.transcriptPath {
            NSWorkspace.shared.open(path)
        }
    }

    private func bringWindowToFront(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure the window is brought to front even if already open
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == id {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func closeWindow(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            window.close()
        }
    }

    private func openProtocolsFolder() {
        let protocols = appState.settings.effectiveOutputDir
        let accessing = protocols.startAccessingSecurityScopedResource()
        defer { if accessing { protocols.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func quit() {
        appState.watching.watchLoop?.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Pure Helpers (testable without @main)

    /// Returns the protocol path from the last completed job, if any.
    static func lastCompletedProtocolPath(completedJobs: [PipelineJob]) -> URL? {
        completedJobs.last?.protocolPath
    }
}
