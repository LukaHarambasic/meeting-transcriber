@testable import MeetingTranscriber
import XCTest

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testImageWithNoBadgeIsTemplate() {
        let image = MenuBarIcon.image(badge: .inactive)
        XCTAssertTrue(image.isTemplate)
    }

    func testImageSizeIs18x18() {
        let image = MenuBarIcon.image(badge: .inactive)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
    }

    // MARK: - Error overlay (the icon's only use of colour)

    /// The load-bearing half of the adaptive-icon change: with no problem, every
    /// state — including `.error`, which used to paint its own red exclamation —
    /// must be a template image, or macOS will not invert it for a dark menu bar
    /// or for the highlight the status item gets while its menu is open. A black
    /// waveform sitting on that blue highlight is what the user reported.
    func testEveryBadgeIsTemplateWithoutTheErrorOverlay() {
        for badge in BadgeKind.allCases {
            let image = MenuBarIcon.image(badge: badge)
            XCTAssertTrue(
                image.isTemplate,
                "Badge \(badge) must be a template image so macOS adapts it to the menu bar",
            )
            XCTAssertEqual(image.size.width, 18, accuracy: 0.01, "Badge \(badge) width")
            XCTAssertEqual(image.size.height, 18, accuracy: 0.01, "Badge \(badge) height")
        }
    }

    func testErrorOverlayProducesNonTemplateImageOverAnyBadge() {
        for badge in BadgeKind.allCases {
            let image = MenuBarIcon.image(badge: badge, errorOverlay: true)
            XCTAssertFalse(
                image.isTemplate,
                "error overlay must be non-template for \(badge) so the red dot stays red",
            )
        }
    }

    func testErrorOverlayChangesTheRenderedImage() {
        let plain = MenuBarIcon.image(badge: .inactive, animationFrame: 0)
        let dotted = MenuBarIcon.image(badge: .inactive, animationFrame: 0, errorOverlay: true)
        XCTAssertNotEqual(
            plain.tiffRepresentation,
            dotted.tiffRepresentation,
            "the red dot has to actually be drawn, not just flip isTemplate",
        )
    }

    /// The reported bug: the icon rendered black on a dark menu bar while every
    /// other status item was white.
    ///
    /// The cause was reading `NSApp.effectiveAppearance` *before* the image's
    /// drawing closure. That reports the system Light/Dark setting, which is not
    /// what the menu bar is — since Big Sur the menu bar goes dark whenever the
    /// desktop picture behind it is dark, in Light Mode too. On a light system
    /// with a dark wallpaper the read said "light", the fill was black, and the
    /// icon was invisible against its own menu bar.
    ///
    /// This pins the fix by driving the two drawing appearances directly: the
    /// error image must differ between them. Under the old hoisted read both
    /// renders were byte-identical, because `NSApp`'s appearance does not change
    /// inside these blocks — so this test fails on the old code for the stated
    /// reason, which is the only reason to trust it.
    func testErrorIconTakesItsColourFromTheDrawingAppearance() throws {
        var light: Data?
        var dark: Data?
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = MenuBarIcon.image(badge: .inactive, errorOverlay: true).tiffRepresentation
        }
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = MenuBarIcon.image(badge: .inactive, errorOverlay: true).tiffRepresentation
        }
        XCTAssertNotNil(light, "the error image must actually rasterise")
        XCTAssertNotNil(dark)
        XCTAssertNotEqual(
            light, dark,
            "the error icon must follow the appearance it is drawn into, not the app's setting",
        )
    }

    /// The other half, and the reason only the error state has to ask: every
    /// non-error badge is a template image, so AppKit derives the colour and the
    /// render is appearance-independent. If one of these ever started varying,
    /// it would mean a badge had silently stopped being a template.
    func testNonErrorIconsAreAppearanceIndependent() throws {
        var light: Data?
        var dark: Data?
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = MenuBarIcon.image(badge: .inactive).tiffRepresentation
        }
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = MenuBarIcon.image(badge: .inactive).tiffRepresentation
        }
        XCTAssertEqual(light, dark, "a template image must not bake in an appearance")
    }

    func testErrorOverlayDefaultsOff() {
        let withoutParam = MenuBarIcon.image(badge: .recording, animationFrame: 0)
        let explicitFalse = MenuBarIcon.image(badge: .recording, animationFrame: 0, errorOverlay: false)
        XCTAssertEqual(withoutParam.isTemplate, explicitFalse.isTemplate)
        XCTAssertEqual(withoutParam.tiffRepresentation, explicitFalse.tiffRepresentation)
    }

    /// Regression test: a non-animated badge rendered with the error overlay must
    /// NOT pick up the live `animationFrame` — otherwise the idle waveform
    /// bounces as if recording. See MenuBarIcon.image(...) frame-clamp logic.
    func testErrorOverlayDoesNotAnimateStaticBadges() {
        let staticBadges: [BadgeKind] = [.inactive, .userAction, .done, .error, .updateAvailable]
        for badge in staticBadges {
            let frame0 = MenuBarIcon.image(badge: badge, animationFrame: 0, errorOverlay: true)
            let frame3 = MenuBarIcon.image(badge: badge, animationFrame: 3, errorOverlay: true)
            XCTAssertEqual(
                frame0.tiffRepresentation,
                frame3.tiffRepresentation,
                "Static badge \(badge) should render identically across frames under errorOverlay",
            )
        }
    }

    /// Inverse check, and a requirement in its own right: a recording that hits a
    /// problem keeps animating *under* the dot. Freezing it would say "recording
    /// stopped" about a recording that is still running.
    func testErrorOverlayKeepsAnimatedBadgesAnimating() {
        let animatedBadges: [BadgeKind] = [.recording, .transcribing, .diarizing, .processing]
        for badge in animatedBadges {
            let frame0 = MenuBarIcon.image(badge: badge, animationFrame: 0, errorOverlay: true)
            let frame3 = MenuBarIcon.image(badge: badge, animationFrame: 3, errorOverlay: true)
            XCTAssertNotEqual(
                frame0.tiffRepresentation,
                frame3.tiffRepresentation,
                "Animated badge \(badge) should advance under errorOverlay",
            )
        }
    }

    // MARK: - Layout Math

    func testBarsLayoutCentersHorizontally() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.barsLayout(in: rect)
        // 5 bars × 2.2 width + 4 gaps × (3.6 - 2.2) = 11 + 5.6 = 16.6
        // left = (18 - 16.6) / 2 = 0.7
        let barsWidth: CGFloat = 5 * 2.2 + 4 * (3.6 - 2.2)
        let expectedLeft = (18 - barsWidth) / 2
        XCTAssertEqual(layout.left, expectedLeft, accuracy: 0.01)
    }

    func testBarsLayoutCentersVertically() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.barsLayout(in: rect)
        XCTAssertEqual(layout.centerY, 9.0, accuracy: 0.01)
    }

    func testTextLayoutLeft() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.textLayout(in: rect)
        XCTAssertEqual(layout.left, 18 * 0.12, accuracy: 0.01)
    }

    func testTextLayoutTopCentersVertically() {
        let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let layout = MenuBarIcon.textLayout(in: rect)
        // 5 lines × 1.4 height + 4 gaps × (2.8 - 1.4) = 7 + 5.6 = 12.6
        // top = 9 + 12.6/2 = 15.3
        let linesHeight: CGFloat = 5 * 1.4 + 4 * (2.8 - 1.4)
        let expectedTop = 18.0 / 2 + linesHeight / 2
        XCTAssertEqual(layout.top, expectedTop, accuracy: 0.01)
    }

    // MARK: - BadgeKind.compute()

    // 1. Recording while recordingActive
    func testCompute_recordingActive_returnsRecording() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .recording)
    }

    // 2. Recording takes priority over transcriberState.transcribing
    func testCompute_recordingActive_priorityOverTranscriberState() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .recording)
    }

    // 3. UserAction for waitingForSpeakerCount
    func testCompute_waitingForSpeakerCount_returnsUserAction() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerCount,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .userAction)
    }

    // 4. UserAction for waitingForSpeakerNames
    func testCompute_waitingForSpeakerNames_returnsUserAction() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .waitingForSpeakerNames,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .userAction)
    }

    // 5. Done for protocolReady
    func testCompute_protocolReady_returnsDone() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .protocolReady,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .done)
    }

    // 6. Error for transcriberError
    func testCompute_transcriberError_returnsError() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .error,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .error)
    }

    // 7. Transcribing for transcriberTranscribing
    func testCompute_transcriberTranscribing_returnsTranscribing() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .transcribing,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 8. Transcribing for recordingDone
    func testCompute_recordingDone_returnsTranscribing() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recordingDone,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 9. Processing for generatingProtocol
    func testCompute_generatingProtocol_returnsProcessing() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .generatingProtocol,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 10. ActiveJob transcribing (not recording)
    func testCompute_activeJobTranscribing_returnsTranscribing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 11. ActiveJob diarizing
    func testCompute_activeJobDiarizing_returnsDiarizing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .diarizing,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .diarizing)
    }

    // 12. ActiveJob generatingProtocol → processing
    func testCompute_activeJobGeneratingProtocol_returnsProcessing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .generatingProtocol,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 13. ActiveJob waiting → processing
    func testCompute_activeJobWaiting_returnsProcessing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .waiting,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 14. ActiveJob done → processing
    func testCompute_activeJobDone_returnsProcessing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .done,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 15. ActiveJob error → processing
    func testCompute_activeJobError_returnsProcessing() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .error,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .processing)
    }

    // 16. UpdateAvailable when all idle
    func testCompute_updateAvailable_returnsUpdateAvailable() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .updateAvailable)
    }

    // 17. Inactive when all idle
    func testCompute_allIdle_returnsInactive() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .inactive)
    }

    // 18. recordingActive true but transcriberState idle → inactive (desynced state)
    func testCompute_recordingActiveIdleTranscriber_returnsInactive() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
        )
        XCTAssertEqual(result, .inactive)
    }

    // 19. ActiveJob takes priority over updateAvailable
    func testCompute_activeJob_priorityOverUpdateAvailable() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: .transcribing,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .transcribing)
    }

    // 19. Recording takes priority over activeJob and updateAvailable
    func testCompute_recordingActive_priorityOverActiveJobAndUpdate() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: .transcribing,
            updateAvailable: true,
        )
        XCTAssertEqual(result, .recording)
    }

    func testCompute_permissionBroken_returnsError() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .error)
    }

    func testCompute_recordingOverridesPermissionProblem() {
        let result = BadgeKind.compute(
            recordingActive: true,
            transcriberState: .recording,
            activeJobState: nil,
            updateAvailable: false,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .recording)
    }

    func testCompute_permissionProblemOverridesUpdate() {
        let result = BadgeKind.compute(
            recordingActive: false,
            transcriberState: .idle,
            activeJobState: nil,
            updateAvailable: true,
            permissionProblem: true,
        )
        XCTAssertEqual(result, .error)
    }
}
