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
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case updateAvailable

    /// Whether this badge kind uses animation.
    var isAnimated: Bool {
        switch self {
        case .recording, .transcribing, .diarizing, .processing: true

        default: false
        }
    }
}

/// Composites a menu bar icon (waveform + optional red error dot).
///
/// The base icon is a waveform (5 vertical bars). Depending on the badge kind,
/// the waveform animates differently:
/// - `.recording`: a wave travels across the bars
/// - `.transcribing`: bars morph into horizontal text lines (audio → text)
/// - `.diarizing`: bars split into two groups (speaker separation)
/// - `.processing`: text lines appear sequentially (protocol being written)
///
/// **Colour is reserved for exactly one thing: an error.** Everything else is a
/// template image, so macOS inverts it for light and dark menu bars and for the
/// highlight the status item gets while its menu is open, the way every other
/// menu-bar icon behaves. Three earlier red marks — a record-only dot, a
/// permission exclamation, and per-channel half-tinted bars — each forced a
/// non-template image, and a non-template image does not invert: the icon stayed
/// black-on-blue under the open-menu highlight, and a permanent red mark that
/// was never explained anywhere in the UI read as decoration rather than as a
/// problem. The one remaining red mark is `errorOverlay`, and the menu shows the
/// matching `RecordingIssue` text whenever it is set.
///
/// Rendered as template image — macOS handles light/dark mode automatically.
/// `@MainActor` because cache initialisation, NSApp / NSAppearance reads, and
/// `image(badge:…)` all need to run on the main actor. All known call sites
/// (menu bar UI, `BadgeKind.compute(...)` consumers in AppState) are
/// MainActor-bound already, so the annotation tightens the contract without
/// breaking anyone.
@MainActor
enum MenuBarIcon {
    /// Number of distinct animation frames. Pure constant.
    nonisolated static let frameCount = 6

    /// Run-loop mode for the menu-bar animation timer (`AnimatedMenuBarIcon`).
    ///
    /// `.default`, not `.common`: `.common` includes `.eventTracking`, so the
    /// timer would fire while the status-bar menu is tracked and deliver its
    /// `@MainActor` tick from inside that nested run loop — which crashes in the
    /// Swift concurrency executor check (`swift_task_isCurrentExecutor` →
    /// EXC_BAD_ACCESS). Trade-off: the badge animation pauses while a menu is
    /// open (cosmetic, sub-second) and resumes when tracking ends.
    nonisolated static let animationRunLoopMode: RunLoop.Mode = .default

    /// Returns the next animation frame for `badge`, or `current` if `badge`
    /// is non-animated. Static badges (idle, error, …) ignore the timer tick
    /// so the App scene's body does not re-evaluate every 0.4 s. Pure math —
    /// `nonisolated` so it can be called from any context (tests, off-main).
    nonisolated static func nextFrame(_ current: Int, badge: BadgeKind) -> Int {
        guard badge.isAnimated else { return current }
        return (current + 1) % frameCount
    }

    // MARK: - Shared Layout Constants

    // All `nonisolated` because they're pure constants consumed from the
    // rendering closure (which can be invoked off-main during composition).

    nonisolated private static let barWidth: CGFloat = 2.2
    nonisolated private static let barSpacing: CGFloat = 3.6
    nonisolated private static let barCount = 5
    nonisolated private static let defaultBarHeights: [CGFloat] = [0.25, 0.50, 0.75, 0.45, 0.30]

    nonisolated private static let lineHeight: CGFloat = 1.4
    nonisolated private static let lineSpacing: CGFloat = 2.8
    nonisolated private static let lineWidths: [CGFloat] = [0.70, 0.55, 0.65, 0.50, 0.40]
    nonisolated private static let lineLeftInset: CGFloat = 0.12 // multiplied by rect width

    /// Pure layout math used from the rendering closure (off-main during
    /// composition). `nonisolated` so the closure isn't forced onto MainActor.
    nonisolated static func barsLayout(in rect: NSRect) -> (left: CGFloat, centerY: CGFloat) {
        let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barSpacing - barWidth)
        return (left: (rect.width - barsWidth) / 2, centerY: rect.height / 2)
    }

    nonisolated static func textLayout(in rect: NSRect) -> (top: CGFloat, left: CGFloat) {
        let linesHeight = CGFloat(barCount) * lineHeight + CGFloat(barCount - 1) * (lineSpacing - lineHeight)
        return (top: rect.height / 2 + linesHeight / 2, left: rect.width * lineLeftInset)
    }

    // MARK: - Cache

    /// Pre-rendered frames keyed by BadgeKind. Populated once eagerly when
    /// the type is first referenced. The type is `@MainActor`, so the
    /// initialiser runs on MainActor and can safely read NSApp/NSAppearance.
    private static let cache: [BadgeKind: [NSImage]] = {
        var result: [BadgeKind: [NSImage]] = [:]
        for badge in BadgeKind.allCases {
            let count = badge.isAnimated ? frameCount : 1
            result[badge] = (0 ..< count).map { frame in renderImage(badge: badge, frame: frame) }
        }
        return result
    }()

    // MARK: - Public

    /// Returns a pre-rendered 18x18pt template `NSImage` for the given badge and animation frame.
    ///
    /// `errorOverlay` composites a solid red dot in the bottom-right corner and
    /// is the icon's only use of colour. It bypasses the pre-rendered cache and
    /// forces a non-template image, because red would not survive template
    /// rendering — and it is rendered per call rather than cached so it picks up
    /// a light/dark switch that happened after launch.
    ///
    /// The badge body still animates underneath the dot: a recording that hits a
    /// problem keeps moving *and* shows the dot, rather than freezing into a
    /// static error icon that reads as "recording stopped".
    static func image(
        badge: BadgeKind,
        animationFrame: Int = 0,
        errorOverlay: Bool = false,
    ) -> NSImage {
        if errorOverlay {
            // Honour the cache's frame discipline: animated badges advance, static ones
            // stay on frame 0. Without this, the live animationFrame leaks through and
            // makes `.inactive` (idle waveform) bounce as if recording.
            let frame = badge.isAnimated ? animationFrame : 0
            return renderImage(badge: badge, frame: frame, errorOverlay: true)
        }
        guard let frames = cache[badge] else { return renderImage(badge: badge, frame: animationFrame) }
        return frames[animationFrame % frames.count]
    }

    // MARK: - Rendering

    private static func renderImage(
        badge: BadgeKind,
        frame: Int,
        errorOverlay: Bool = false,
    ) -> NSImage {
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
            // current. That is also why every non-error badge is a template
            // image: AppKit then derives the colour itself and this question
            // never arises. `errorOverlay` cannot be a template (red would be
            // tinted away), so it has to ask — and this is the only place where
            // asking gets a truthful answer.
            let isDark = NSAppearance.currentDrawing()
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if errorOverlay {
                (isDark ? NSColor.white : NSColor.black).setFill()
            } else {
                NSColor.black.setFill()
            }

            drawBadgeBody(badge: badge, in: rect, frame: frame)

            if errorOverlay {
                drawErrorDot(in: rect)
            }

            return true
        }
        image.isTemplate = !errorOverlay
        return image
    }

    /// Single dispatch for the badge's main body shape.
    ///
    /// Every non-animated badge draws `drawStaticBars`, i.e. `defaultBarHeights`
    /// — which is also the shape the transcribing morph interpolates *from*, so
    /// idle → transcribing starts where idle left off instead of jumping. The
    /// old code drew `recordingFrames[0]` here, which happened to equal
    /// `defaultBarHeights`; with the recording wave now computed rather than
    /// tabulated that coincidence is gone, so the static shape is named.
    private static func drawBadgeBody(badge: BadgeKind, in rect: NSRect, frame: Int) {
        switch badge {
        case .recording:
            drawRecordingAnimation(in: rect, frame: frame)

        case .transcribing:
            drawTranscribingAnimation(in: rect, frame: frame)

        case .diarizing:
            drawDiarizingAnimation(in: rect, frame: frame)

        case .processing:
            drawProtocolAnimation(in: rect, frame: frame)

        case .updateAvailable:
            drawStaticBars(in: rect)
            drawUpdateArrow(in: rect)

        case .inactive, .userAction, .done, .error:
            drawStaticBars(in: rect)
        }
    }

    /// The resting waveform: five bars at `defaultBarHeights`. Drawn for every
    /// badge that does not animate.
    private static func drawStaticBars(in rect: NSRect) {
        drawBars(in: rect, heights: defaultBarHeights)
    }

    // MARK: - Recording Animation (a wave travelling across the bars)

    /// Bar height as a fraction of the icon, for one bar on one frame.
    ///
    /// A sine wave rather than the six hand-written height rows this replaces.
    /// Those rows were random-looking by design — "bars bounce like a live audio
    /// signal" — and at 18pt and 2.5 frames a second the result read as jitter
    /// rather than as sound. One wave phase spread across the five bars and
    /// advanced by one frame per tick gives a calm, obviously-periodic motion
    /// that says "running" without competing for attention, and it loops
    /// seamlessly for any `frameCount` because both offsets are full turns.
    ///
    /// Amplitude stops well short of the icon's edges (0.30…0.70 of the height)
    /// so no frame clips and the wave keeps a visible baseline.
    nonisolated static func recordingBarHeight(bar: Int, frame: Int) -> CGFloat {
        let framePhase = 2 * CGFloat.pi * CGFloat(frame % frameCount) / CGFloat(frameCount)
        let barPhase = 2 * CGFloat.pi * CGFloat(bar) / CGFloat(barCount)
        let unit = (sin(framePhase + barPhase) + 1) / 2 // 0…1
        return 0.30 + 0.40 * unit
    }

    private static func drawRecordingAnimation(in rect: NSRect, frame: Int) {
        drawBars(in: rect, heights: (0 ..< barCount).map { recordingBarHeight(bar: $0, frame: frame) })
    }

    /// Draw the five centred, capsule-ended bars at the given fractional
    /// heights. Shared by the wave and the resting shape so the two cannot
    /// drift in width, spacing or corner radius.
    private static func drawBars(in rect: NSRect, heights: [CGFloat]) {
        let layout = barsLayout(in: rect)
        for i in 0 ..< min(barCount, heights.count) {
            let x = layout.left + CGFloat(i) * barSpacing
            let barH = rect.height * heights[i]
            let barRect = NSRect(
                x: x,
                y: layout.centerY - barH / 2,
                width: barWidth,
                height: barH,
            )
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    // MARK: - Transcribing Animation (waveform → text lines)

    private static let transcribeMorphSteps: [CGFloat] = [0.0, 0.15, 0.35, 0.6, 0.85, 1.0]

    private static func drawTranscribingAnimation(in rect: NSRect, frame: Int) {
        let h = rect.height
        let t = transcribeMorphSteps[frame % transcribeMorphSteps.count]
        let bars = barsLayout(in: rect)
        let text = textLayout(in: rect)

        for i in 0 ..< barCount {
            // Source: vertical bar
            let srcX = bars.left + CGFloat(i) * barSpacing
            let srcH = h * defaultBarHeights[i]
            let srcY = bars.centerY - srcH / 2

            // Target: horizontal text line
            let tgtX = text.left
            let tgtW = rect.width * lineWidths[i]
            let tgtY = text.top - CGFloat(i) * lineSpacing - lineHeight

            // Interpolate
            let x = srcX + (tgtX - srcX) * t
            let y = srcY + (tgtY - srcY) * t
            let rw = barWidth + (tgtW - barWidth) * t
            let rh = srcH + (lineHeight - srcH) * t
            let radius = min(rw, rh) / 2

            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: rw, height: rh),
                xRadius: radius,
                yRadius: radius,
            ).fill()
        }
    }

    // MARK: - Diarizing Animation (bars split into two speaker groups)

    private static let diarizeSplitSteps: [CGFloat] = [0.0, 0.2, 0.5, 0.8, 1.0, 0.8]

    private static func drawDiarizingAnimation(in rect: NSRect, frame: Int) {
        let h = rect.height
        let t = diarizeSplitSteps[frame % diarizeSplitSteps.count]
        let layout = barsLayout(in: rect)

        let maxShift: CGFloat = 2.5
        let verticalSep: CGFloat = 1.5

        for i in 0 ..< barCount {
            let isGroupA = i.isMultiple(of: 2)
            let barH = h * defaultBarHeights[i]

            let x = layout.left + CGFloat(i) * barSpacing + (isGroupA ? -maxShift : maxShift) * t
            let y = layout.centerY - barH / 2 + (isGroupA ? verticalSep : -verticalSep) * t

            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: barH),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2,
            ).fill()
        }
    }

    // MARK: - Error Dot (solid red dot in bottom-right)

    /// The icon's only coloured mark: something is wrong, and the menu says what.
    ///
    /// A plain dot, not the exclamation-in-a-circle it replaces. At 18pt the
    /// white "!" inside a 7pt circle was a smudge rather than a glyph, so it
    /// carried no more meaning than a dot while taking more room and forcing
    /// white into an otherwise two-colour icon.
    private static func drawErrorDot(in rect: NSRect) {
        let size: CGFloat = 6.0
        let margin: CGFloat = 0.5
        let cx = rect.maxX - size / 2 - margin
        let cy = rect.minY + size / 2 + margin

        NSColor.systemRed.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size),
        ).fill()
    }

    // MARK: - Update Available (small upward arrow badge in bottom-right)

    private static func drawUpdateArrow(in rect: NSRect) {
        let size: CGFloat = 6.0
        let margin: CGFloat = 0.5
        let cx = rect.maxX - size / 2 - margin
        let cy = rect.minY + size / 2 + margin

        // Arrow pointing up: triangle + stem
        let arrow = NSBezierPath()
        // Triangle head
        arrow.move(to: NSPoint(x: cx, y: cy + size / 2)) // top
        arrow.line(to: NSPoint(x: cx - size / 3, y: cy + 0.5)) // bottom-left
        arrow.line(to: NSPoint(x: cx + size / 3, y: cy + 0.5)) // bottom-right
        arrow.close()
        arrow.fill()

        // Stem
        let stemWidth: CGFloat = 1.4
        let stem = NSRect(x: cx - stemWidth / 2, y: cy - size / 3, width: stemWidth, height: size / 2)
        NSBezierPath(roundedRect: stem, xRadius: stemWidth / 2, yRadius: stemWidth / 2).fill()
    }

    // MARK: - Protocol Generation Animation (text lines appearing sequentially)

    private static func drawProtocolAnimation(in rect: NSRect, frame: Int) {
        let text = textLayout(in: rect)
        let visibleLines = (frame % frameCount) + 1

        for i in 0 ..< min(visibleLines, barCount) {
            let lineW = rect.width * lineWidths[i]
            let lineY = text.top - CGFloat(i) * lineSpacing - lineHeight
            NSBezierPath(
                roundedRect: NSRect(x: text.left, y: lineY, width: lineW, height: lineHeight),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2,
            ).fill()
        }
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
        updateAvailable: Bool,
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
        if updateAvailable { return .updateAvailable }
        return .inactive
    }
}
