@testable import MeetingTranscriber
import XCTest

/// The menu-bar animation's shape and timing.
///
/// Split out of `MenuBarIconTests`, which sits at the 400-line type-body cap.
/// These are also the tests that answer a complaint no screenshot can settle:
/// "it looks like 4fps, it's not smooth". Smoothness is asserted as arithmetic
/// on the frame-to-frame deltas rather than by eye.
@MainActor
final class MenuBarIconAnimationTests: XCTestCase {
    // MARK: - Recording animation shape

    /// The wave has to actually travel: every bar at a different height on a
    /// given frame, and each bar's height changing frame to frame. A constant
    /// would satisfy "renders an image" and animate nothing.
    func testRecordingWaveTravelsAcrossBarsAndFrames() {
        let frame0 = (0 ..< 5).map { MenuBarIcon.recordingBarHeight(bar: $0, frame: 0) }
        XCTAssertGreaterThan(
            Set(frame0.map { ($0 * 1000).rounded() }).count, 1,
            "bars on one frame must differ, or the icon is five identical bars",
        )
        let bar0 = (0 ..< MenuBarIcon.frameCount).map { MenuBarIcon.recordingBarHeight(bar: 0, frame: $0) }
        XCTAssertGreaterThan(
            Set(bar0.map { ($0 * 1000).rounded() }).count, 1,
            "one bar across frames must differ, or nothing moves",
        )
    }

    /// Amplitude bounds, so no frame clips the icon or collapses a bar to
    /// nothing. Checked over two full cycles to also pin the frame wrap.
    func testRecordingWaveStaysWithinItsAmplitudeBounds() {
        for frame in 0 ..< (MenuBarIcon.frameCount * 2) {
            for bar in 0 ..< 5 {
                let height = MenuBarIcon.recordingBarHeight(bar: bar, frame: frame)
                XCTAssertGreaterThanOrEqual(height, 0.30, "bar \(bar) frame \(frame) too short")
                XCTAssertLessThanOrEqual(height, 0.70, "bar \(bar) frame \(frame) would clip")
            }
        }
    }

    /// Smoothness, as arithmetic rather than as an opinion.
    ///
    /// "Looks like 4fps" was the report, and it was two problems at once: the
    /// frame rate (2.5 fps) and the size of each step. This pins the second: no
    /// single frame may move a bar more than a small fraction of the icon, so a
    /// future frame-count change cannot quietly reintroduce visible jumps.
    ///
    /// The bound is derived, not guessed: a sine of amplitude 0.40 advancing by
    /// one of `frameCount` steps moves at most `0.40 * π / frameCount` per
    /// frame. At 36 frames that is ~0.035 of the icon height, well under 1 pt at
    /// 18 pt. Asserting against the derived value means the test tracks the
    /// design rather than a hard-coded number that would need re-tuning.
    func testRecordingWaveAdvancesInSmallSteps() {
        let bound = 0.40 * CGFloat.pi / CGFloat(MenuBarIcon.frameCount)
        for frame in 0 ..< MenuBarIcon.frameCount {
            for bar in 0 ..< 5 {
                let delta = abs(
                    MenuBarIcon.recordingBarHeight(bar: bar, frame: frame + 1)
                        - MenuBarIcon.recordingBarHeight(bar: bar, frame: frame),
                )
                XCTAssertLessThanOrEqual(
                    delta, bound + 0.0001,
                    "bar \(bar) jumps \(delta) between frames \(frame) and \(frame + 1)",
                )
            }
        }
    }

    /// The frame rate itself. 24 fps or better; the reported choppiness was the
    /// 0.4 s interval this replaced.
    func testFrameRateIsSmooth() {
        XCTAssertLessThanOrEqual(
            MenuBarIcon.frameInterval, 1.0 / 24,
            "at more than ~40 ms per frame the animation reads as discrete poses",
        )
        // Guard the other direction too: the product is what matters, and a fast
        // interval with few frames would be a frantic loop rather than a calm one.
        let cycleSeconds = Double(MenuBarIcon.frameCount) * MenuBarIcon.frameInterval
        XCTAssertGreaterThanOrEqual(cycleSeconds, 1.0, "a sub-second cycle reads as agitation")
        XCTAssertLessThanOrEqual(cycleSeconds, 3.0, "a multi-second cycle reads as stalled")
    }

    /// Every animation must be a function of `phase`, so `frameCount` can move
    /// without retuning each one. The protocol animation is the one that used to
    /// index `frameCount` directly, which broke the moment 36 > `barCount`.
    func testEveryAnimatedBadgeUsesTheWholeCycle() {
        for badge in BadgeKind.allCases where badge.isAnimated {
            var distinct = Set<Data>()
            for frame in 0 ..< MenuBarIcon.frameCount {
                if let tiff = MenuBarIcon.image(badge: badge, animationFrame: frame).tiffRepresentation {
                    distinct.insert(tiff)
                }
            }
            XCTAssertGreaterThan(
                distinct.count, 5,
                "\(badge) only reaches \(distinct.count) distinct frames across a \(MenuBarIcon.frameCount)-frame cycle",
            )
        }
    }

    /// The cycle closes: frame `frameCount` renders as frame 0, so the animation
    /// loops without a visible jump.
    func testRecordingWaveLoopsSeamlessly() {
        for bar in 0 ..< 5 {
            XCTAssertEqual(
                MenuBarIcon.recordingBarHeight(bar: bar, frame: 0),
                MenuBarIcon.recordingBarHeight(bar: bar, frame: MenuBarIcon.frameCount),
                accuracy: 0.0001,
                "bar \(bar) jumps at the loop boundary",
            )
        }
    }

    func testAnimatedBadgeKinds() {
        XCTAssertTrue(BadgeKind.recording.isAnimated)
        XCTAssertTrue(BadgeKind.transcribing.isAnimated)
        XCTAssertTrue(BadgeKind.diarizing.isAnimated)
        XCTAssertTrue(BadgeKind.processing.isAnimated)
        XCTAssertFalse(BadgeKind.inactive.isAnimated)
        XCTAssertFalse(BadgeKind.done.isAnimated)
    }

    func testAllAnimationFramesProduceValidImages() {
        let animatedBadges: [BadgeKind] = [.recording, .transcribing, .diarizing, .processing]
        for badge in animatedBadges {
            for frame in 0 ..< MenuBarIcon.frameCount {
                let image = MenuBarIcon.image(badge: badge, animationFrame: frame)
                XCTAssertTrue(image.isTemplate, "\(badge) frame \(frame)")
                XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
                XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
            }
        }
    }

    // MARK: - Frame Wrapping

    func testAnimationFrameWrapsAroundFrameCount() {
        let badge = BadgeKind.recording
        let normal = MenuBarIcon.image(badge: badge, animationFrame: 2)
        let wrapped = MenuBarIcon.image(badge: badge, animationFrame: 2 + MenuBarIcon.frameCount)
        XCTAssertTrue(normal.isTemplate)
        XCTAssertTrue(wrapped.isTemplate)
        XCTAssertEqual(normal.size, wrapped.size)
    }

    func testErrorOverlayKeepsImageSize() {
        for badge in BadgeKind.allCases {
            let image = MenuBarIcon.image(badge: badge, animationFrame: 0, errorOverlay: true)
            XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
            XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
        }
    }

    func testLargeAnimationFrameDoesNotCrash() {
        for badge in BadgeKind.allCases where badge.isAnimated {
            let image = MenuBarIcon.image(badge: badge, animationFrame: 999)
            XCTAssertTrue(image.isTemplate, "Large frame index should wrap safely for \(badge)")
        }
    }
}
