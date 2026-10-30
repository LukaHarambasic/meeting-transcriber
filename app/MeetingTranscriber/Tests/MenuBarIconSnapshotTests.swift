@testable import MeetingTranscriber
import SnapshotTesting
import XCTest

@MainActor
final class MenuBarIconSnapshotTests: XCTestCase {
    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Byte-exact image comparison tests the rasteriser as much as the icon. An
    /// Xcode update re-renders every badge identically to the eye and fails all
    /// 29 references at once, which is exactly what happened between May and
    /// August and cost half an hour to prove harmless. A perceptual tolerance
    /// absorbs that.
    ///
    /// It is not blind: anything a person would call a changed icon (the
    /// recording dot appearing or moving) fails by a wide margin.
    private static let icon = Snapshotting<NSImage, NSImage>.image(
        precision: 0.99, perceptualPrecision: 0.98,
    )

    override func invokeTest() {
        withSnapshotTesting(record: .missing) {
            super.invokeTest()
        }
    }

    func testIconSnapshots() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        assertSnapshot(of: MenuBarIcon.image(badge: .inactive), as: Self.icon, named: "idle")
        assertSnapshot(of: MenuBarIcon.image(badge: .recording), as: Self.icon, named: "recording")
    }

    func testAllBadgesProduceNonEmptyImages() {
        for badge in BadgeKind.allCases {
            let image = MenuBarIcon.image(badge: badge)
            // Verify the image has actual pixel data (not a blank image)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff)
            else {
                XCTFail("Could not get bitmap for \(badge)")
                continue
            }
            // At least some pixels should be non-transparent
            var hasContent = false
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y),
                       color.alphaComponent > 0 {
                        hasContent = true
                        break
                    }
                }
                if hasContent { break }
            }
            XCTAssertTrue(hasContent, "\(badge) should have visible content")
        }
    }
}
