@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The still-recording ask's delivery half: the action category is registered,
/// the ask carries it, and ordinary notifications do not.
///
/// This is not cosmetic. A notification whose `categoryIdentifier` names an
/// unregistered category still delivers — silently, with no buttons — so the
/// user would have no way to answer, and the unanswered ask would then stop
/// their recording five minutes later.
@MainActor
final class RecordingConfirmationNotificationTests: XCTestCase {
    private static let deliverable: @Sendable () -> Bool = { true }

    private func makeManager() -> (NotificationManager, FakeNotificationScheduler) {
        let fake = FakeNotificationScheduler()
        let manager = NotificationManager(scheduler: fake, canDeliver: Self.deliverable)
        return (manager, fake)
    }

    func testSetUpRegistersTheConfirmationCategoryWithItsAction() throws {
        let (manager, fake) = makeManager()
        manager.setUp()

        let confirmation = fake.categories.first { category in
            category.identifier == NotificationManager.recordingConfirmationCategoryID
        }
        let registered = try XCTUnwrap(
            confirmation,
            "without the category the ask arrives with no way to answer it",
        )
        XCTAssertEqual(
            registered.actions.map(\.identifier),
            [NotificationManager.keepRecordingActionID],
        )
    }

    func testTheAskIsPostedUnderTheConfirmationCategory() {
        let (manager, fake) = makeManager()
        manager.setUp()

        manager.notify(
            title: RecordingConfirmationPolicy.promptTitle,
            body: "anything",
            urgency: .timeSensitive,
        )

        XCTAssertEqual(
            fake.added.last?.content.categoryIdentifier,
            NotificationManager.recordingConfirmationCategoryID,
        )
    }

    /// The routing is a title match, so the inverse has to be pinned: an
    /// ordinary notification must not sprout a "Keep Recording" button.
    func testOtherNotificationsCarryNoCategory() {
        let (manager, fake) = makeManager()
        manager.setUp()

        manager.notify(title: "Protocol Ready", body: "anything")

        XCTAssertEqual(
            fake.added.last?.content.categoryIdentifier, "",
            "an unset categoryIdentifier reads back as the empty string",
        )
    }

    /// Guards the coupling that makes the title match work at all: the policy
    /// owns the title, and `categoryID(forTitle:)` matches it. If either side
    /// drifts, the ask loses its button and nothing fails to compile.
    func testCategoryLookupIsDrivenByThePolicysOwnTitle() {
        XCTAssertEqual(
            NotificationManager.categoryID(forTitle: RecordingConfirmationPolicy.promptTitle),
            NotificationManager.recordingConfirmationCategoryID,
        )
        XCTAssertNil(NotificationManager.categoryID(forTitle: "Something Else"))
    }
}
