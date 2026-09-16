import SwiftUI

/// The floating notes panel's content: a header naming what the text belongs
/// to, the live-styled markdown editor, and a footer naming the file it is
/// being written to.
///
/// Deliberately thin — `controller` (`NotesController`) owns the text, the
/// target and the write-through to disk; this view only renders that state
/// and forwards the editor's key commands (Return/Tab/⌘B/⌘I/Escape, all in
/// `NotesMarkdownTextView`).
struct NotesEditorView: View {
    @Bindable var controller: NotesController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            NotesTextView(text: $controller.text) {
                controller.close()
            }
            .frame(minWidth: 360, minHeight: 240)
            footer
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack {
            Image(systemName: controller.target.isLive ? "record.circle" : "note.text")
                .foregroundStyle(controller.target.isLive ? .red : .secondary)
            Text(targetLabel)
                .font(.headline)
                .accessibilityIdentifier(A11yID.notesTargetLabel)
        }
    }

    private var footer: some View {
        Text(controller.fileURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var targetLabel: String {
        switch controller.target {
        case let .liveRecording(_, startedAt):
            let time: String = Self.timeFormatter.string(from: startedAt)
            return "Recording since " + time

        case let .scratch(day):
            return Self.dateFormatter.string(from: day)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
