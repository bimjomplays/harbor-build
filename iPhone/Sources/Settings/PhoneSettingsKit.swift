import SwiftUI

/// Bits the Settings panels share.
enum PhoneSettingsFixtures {
    /// `--fixtures` (no engine to ask, nothing leaves the app): panels that read the world, such as the
    /// stream addons or a home server, show a fixed set. `--fixtures live` reads the real engine.
    @MainActor static var active: Bool { Fixtures.active && !Fixtures.liveRooms }
}

/// A Form row with a check on the option in use, a title and an optional line under it.
struct PhoneChoiceRow: View {
    let title: String
    var detail: String?
    let on: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(PhoneTheme.sans(17, .regular, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                    if let detail {
                        Text(verbatim: detail)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BP.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }
}

/// A note under a control: green when it reports a success, red when it does not.
struct PhoneSettingsNote: View {
    let text: String
    var ok = false

    var body: some View {
        Text(verbatim: text)
            .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
            .foregroundStyle(ok ? BP.live : BP.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Reorder / Done Reordering button a panel with a draggable list puts in its bar.
struct PhoneReorderButton: ToolbarContent {
    @Binding var editMode: EditMode
    let id: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode.isEditing ? T("Done Reordering") : T("Reorder")) {
                PhoneFeedback.shared.selection()
                withMotion { editMode = editMode.isEditing ? .inactive : .active }
            }
            .accessibilityIdentifier(id)
        }
    }
}
