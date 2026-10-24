import SwiftUI

/// A screen a later release fills: the room's name and a plain line, so a tab is never blank.
struct PhoneSoonView: View {
    let room: Room

    var body: some View {
        ScrollView {
            EmptyState(title: T(room.label),
                       message: T("This part of Harbor for iPhone arrives in a later release."),
                       systemImage: room.icon)
                .padding(.top, 60)
        }
        .accessibilityIdentifier("soon-\(room.rawValue)")
    }
}
