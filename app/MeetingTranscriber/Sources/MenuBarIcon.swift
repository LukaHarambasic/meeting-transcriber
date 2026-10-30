import AppKit

/// Badge overlay kind for the menu bar icon.
///
/// `String`-backed + `Codable` so the RPC `/state` snapshot can expose the
/// current badge directly (it encodes to the case-name raw value), letting a
/// driver script assert the menu-bar state deterministically instead of
/// pixel-matching a screenshot.
enum BadgeKind: String, CaseIterable, Codable {
    case inactive
    case recording
    case transcribing
    case diarizing
    case processing
    // SwiftFormat strips a redundant `= "userAction"`, which then trips the
    // camel-cased-Codable rule; the implicit rawValue already matches, so
    // disable rather than fight the formatter (same as JobState / AppSettings).
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case userAction
    case done
    case error
}

/// Composites the menu bar icon: a static waveform, a dot while recording, and
/// a red dot when something is wrong.
///
/// **Nothing animates.** The icon used to animate every pipeline stage (a wave
/// while recording, bars morphing into text while transcribing, and so on) at
/// 24 fps. That was replaced by one fixed waveform plus a recording dot: the
/// only state worth noticing at a glance is "this is recording right now", and
/// a dot says that without movement in the corner of the eye. The pipeline
/// stage is still in the menu's label, and `BadgeKind` still reports it on
/// `/state`.
///
/// **Colour is reserved for exactly one thing: an error.** Everything else is a
/// template image, so macOS inverts it for light and dark menu bars and for the
/// highlight the status item gets while its menu is open, the way every other
/// menu-bar icon behaves. That includes the recording dot, which is drawn in
/// the same template colour as the bars (black on a light menu bar, white on a
/// dark one). The one red mark is `errorOverlay`, and the menu shows the
/// matching `RecordingIssue` text whenever it is set.
///
/// `@MainActor` because cache initialisation and NSAppearance reads need to run
/// on the main actor. All call sites (menu bar UI, `BadgeKind.compute(...)`
/// consumers in AppState) are MainActor-bound already.
@MainActor
enum MenuBarIcon {
    // MARK: - Shared Layout Constants

    // All `nonisolated` because they're pure constants consumed from the
    // rendering closure (which can be invoked off-main during composition).

    nonisolated private static let barWidth: CGFloat = 2.2
    nonisolated private static let barSpacing: CGFloat = 3.6
    nonisolated private static let barCount = 5
    nonisolated private static let barHeights: [CGFloat] = [0.25, 0.50, 0.75, 0.45, 0.30]

    /// Diameter of both corner dots, and the transparent ring cut around the
    /// recording dot so it reads as a separate mark rather than merging into
    /// the bars it overlaps.
    nonisolated private static let dotSize: CGFloat = 6.0
    nonisolated private static let dotMargin: CGFloat = 0.5
    nonisolated private static let dotGap: CGFloat = 1.0

    /// Pure layout math used from the rendering closure (off-main during
    /// composition). `nonisolated` so the closure isn't forced onto MainActor.
    nonisolated static func barsLayout(in rect: NSRect) -> (left: CGFloat, centerY: CGFloat) {
        let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barSpacing - barWidth)
        return (left: (rect.width - barsWidth) / 2, centerY: rect.height / 2)
    }

    // MARK: - Cache

    /// The two template images, without and with the recording dot. Rendered
    /// once when the type is first referenced.
    private static let plain = renderImage(recording: false)
    private static let recordingDot = renderImage(recording: true)

    // MARK: - Public

    /// Returns the 18x18pt menu bar icon for `badge`.
    ///
    /// Only `.recording` changes the drawing (it adds the dot); every other badge
    /// renders the same waveform.
    ///
    /// `errorOverlay` composites a solid red dot in the bottom-right corner and
    /// is the icon's only use of colour. It bypasses the cache and forces a
    /// non-template image, because red would not survive template rendering,
    /// and it is rendered per call so it picks up a light/dark switch that
    /// happened after launch. The recording dot stays in its own corner, so a
    /// recording that hits a problem shows both.
    static func image(badge: BadgeKind, errorOverlay: Bool = false) -> NSImage {
        let recording = badge == .recording
        if errorOverlay {
            return renderImage(recording: recording, errorOverlay: true)
        }
        return recording ? recordingDot : plain
    }

    // MARK: - Rendering

    private static func renderImage(recording: Bool, errorOverlay: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // `NSAppearance.currentDrawing()`, read HERE rather than hoisted, is
            // the whole fix for a black icon on a dark menu bar.
            //
            // The obvious thing — `NSApp.effectiveAppearance` computed before
            // this closure — reports the *system* Light/Dark setting, and that
            // is not what the menu bar is. Since Big Sur the menu bar is
            // translucent and goes dark whenever the desktop picture behind it
            // is dark, in Light Mode too. So on a light system with a dark
            // wallpaper the hoisted read said "light", we filled black, and the
            // icon was black-on-dark: exactly the state this was reported in.
            //
            // Only AppKit knows the menu bar's effective appearance, and the way
            // it tells you is by invoking this closure with that appearance
            // current. That is also why every non-error icon is a template
            // image: AppKit then derives the colour itself and this question
            // never arises. `errorOverlay` cannot be a template (red would be
            // tinted away), so it has to ask — and this is the only place where
            // asking gets a truthful answer.
            let isDark = NSAppearance.currentDrawing()
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink = errorOverlay && isDark ? NSColor.white : NSColor.black
            ink.setFill()

            drawBars(in: rect)

            if recording {
                drawRecordingDot(in: rect, ink: ink)
            }
            if errorOverlay {
                drawErrorDot(in: rect)
            }

            return true
        }
        image.isTemplate = !errorOverlay
        return image
    }

    /// The five centred, capsule-ended bars.
    private static func drawBars(in rect: NSRect) {
        let layout = barsLayout(in: rect)
        for i in 0 ..< barCount {
            let x = layout.left + CGFloat(i) * barSpacing
            let barH = rect.height * barHeights[i]
            let barRect = NSRect(
                x: x,
                y: layout.centerY - barH / 2,
                width: barWidth,
                height: barH,
            )
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    /// Recording: a dot in the top-right corner, in the icon's own ink.
    ///
    /// The bars reach that corner, so a transparent ring is cleared first; a dot
    /// drawn straight over them would fuse with the two right-hand bars into one
    /// blob at 18pt.
    private static func drawRecordingDot(in rect: NSRect, ink: NSColor) {
        let center = NSPoint(
            x: rect.maxX - dotSize / 2 - dotMargin,
            y: rect.maxY - dotSize / 2 - dotMargin,
        )
        let ringSize = dotSize + 2 * dotGap
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: circle(at: center, size: ringSize)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        ink.setFill()
        NSBezierPath(ovalIn: circle(at: center, size: dotSize)).fill()
    }

    // MARK: - Error Dot (solid red dot in bottom-right)

    /// The icon's only coloured mark: something is wrong, and the menu says what.
    private static func drawErrorDot(in rect: NSRect) {
        let center = NSPoint(
            x: rect.maxX - dotSize / 2 - dotMargin,
            y: rect.minY + dotSize / 2 + dotMargin,
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circle(at: center, size: dotSize)).fill()
    }

    private static func circle(at center: NSPoint, size: CGFloat) -> NSRect {
        NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }
}

// MARK: - Badge State Logic (pure function, testable without UI)

extension BadgeKind {
    /// Computes the current badge from plain value inputs.
    ///
    /// This is a pure function with no object dependencies — tests can call it
    /// directly with any combination of inputs without driving a recording loop
    /// into states.
    static func compute(
        recordingActive: Bool,
        transcriberState: TranscriberState,
        activeJobState: JobState?,
        permissionProblem: Bool = false,
    ) -> BadgeKind {
        if recordingActive {
            switch transcriberState {
            case .recording: return .recording
            case .waitingForSpeakerCount, .waitingForSpeakerNames: return .userAction
            case .protocolReady: return .done
            case .error: return .error
            case .transcribing, .recordingDone: return .transcribing
            case .generatingProtocol: return .processing
            default: break
            }
        }
        switch activeJobState {
        case .transcribing: return .transcribing
        case .diarizing: return .diarizing
        case .some: return .processing
        case .none: break
        }
        if permissionProblem { return .error }
        return .inactive
    }
}
