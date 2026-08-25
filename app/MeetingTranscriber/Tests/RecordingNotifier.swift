@testable import MeetingTranscriber

// MARK: - AppNotifying spy

/// Records all notify() calls for assertions.
///
/// Its own file rather than another block in `TestHelpers.swift`, which sits on
/// the 600-line `file_length` cap: this double grows whenever `AppNotifying`
/// does, so it is the piece under pressure.
final class RecordingNotifier: AppNotifying {
    private(set) var calls: [(title: String, body: String, urgency: NotificationUrgency)] = []

    func notify(title: String, body: String, urgency: NotificationUrgency) {
        calls.append((title: title, body: body, urgency: urgency))
    }
}
