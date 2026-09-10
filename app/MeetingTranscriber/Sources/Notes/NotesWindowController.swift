import AppKit

/// Floating, non-activating panel hosting the notes editor content view.
///
/// Deliberately not fully borderless: `titleVisibility = .hidden` with a
/// transparent titlebar hides the title text and background while keeping
/// the drag region `isMovableByWindowBackground` relies on, and keeping the
/// panel resizable. `styleMask` includes `.nonactivatingPanel` so the panel
/// can become key (the user types into it) without stealing activation from
/// whatever app is frontmost — a plain `.titled` window would activate the
/// app and pull focus away from the meeting the user is taking notes on.
/// Neither `becomesKeyOnlyIfNeeded` nor `ignoresMouseEvents` is set: both
/// default to `false`, which is what lets every click and keystroke reach
/// the editor.
///
/// `NotesWindowPolicy.apply(to:)` is applied once at construction — it is
/// static configuration (sharing type, level, collection behavior), not
/// something that needs reapplying per show/hide cycle.
@MainActor
final class NotesWindowController {
    /// UserDefaults key for the panel's frame (origin + size), stored as
    /// `{"x", "y", "width", "height"}`. Absence means "first run, use the
    /// default size centred on the main screen".
    static let frameDefaultsKey = "notesPanelFrame"

    private static let defaultSize = NSSize(width: 420, height: 560)

    private let panel: NSPanel
    private var moveObserver: (any NSObjectProtocol)?
    private var resizeObserver: (any NSObjectProtocol)?

    init(contentView: NSView) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.contentView = contentView
        panel.identifier = NSUserInterfaceItemIdentifier("notes")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        NotesWindowPolicy.apply(to: panel)
        self.panel = panel
        installFrameObservers()
    }

    /// Show the panel at its saved (or default) frame and give it key focus.
    func show() {
        panel.setFrame(savedFrame() ?? defaultFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hide the panel without destroying it — re-showing is cheap and the
    /// hosted editor view stays bound to the same controller.
    func hide() {
        panel.orderOut(nil)
    }

    private func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: Self.defaultSize)
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - Self.defaultSize.width / 2,
            y: visible.midY - Self.defaultSize.height / 2,
        )
        return NSRect(origin: origin, size: Self.defaultSize)
    }

    /// Read the saved frame and reject it if no currently-attached screen
    /// intersects it (handles "user disconnected the monitor this panel was
    /// parked on"). Returns nil → caller falls back to the default frame.
    private func savedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.frameDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double
        else { return nil }
        let candidate = NSRect(x: x, y: y, width: width, height: height)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(candidate) }
        return onScreen ? candidate : nil
    }

    private func persistFrame(_ frame: NSRect) {
        UserDefaults.standard.set(
            [
                "x": Double(frame.origin.x), "y": Double(frame.origin.y),
                "width": Double(frame.size.width), "height": Double(frame.size.height),
            ],
            forKey: Self.frameDefaultsKey,
        )
    }

    private func installFrameObservers() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.persistFrame(self.panel.frame)
            }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.persistFrame(self.panel.frame)
            }
        }
    }
}
