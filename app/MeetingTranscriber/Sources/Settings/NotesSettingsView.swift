import SwiftUI

/// Settings → Notes. Two toggles only: the notes feature itself (opening the
/// panel, typing, autosave) has no settings of its own — everything else
/// about it lives in the panel.
struct NotesSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Notes") {
                Toggle("Global shortcut (⌥⌘N)", isOn: $settings.notesHotkeyEnabled)
                    .accessibilityIdentifier(A11yID.notesHotkeyToggle)
                Text(
                    "Opens or hides the floating notes panel from anywhere, even" +
                        " while another app is focused.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Feed notes to the transcript summary", isOn: $settings.notesFeedToProtocol)
                    .accessibilityIdentifier(A11yID.notesFeedToProtocolToggle)
                Text(
                    "Notes are always written into the transcript verbatim. With" +
                        " this on, they are also given to the summary generator as" +
                        " authoritative context, on top of that.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(A11yID.notesSection)
        }
        .formStyle(.grouped)
    }
}
