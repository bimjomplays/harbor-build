import SwiftUI

/// Settings → Tabs, the TV's TabsPanel for the phone's tab bar: the same settings.navCustomization
/// (engine/navEdit.ts), so the TV, the desktop sidebar and the phone follow each other per profile.
/// The phone's tabs hold rooms (PhoneTab): a room switched off leaves its tab's chips, and a tab
/// whose rooms are all off leaves the bar. Dragging a room reorders the chips, and the tabs follow
/// the order of their first room. Home and Search stay put. PhoneShellView reads the result live.
struct PhoneTabsPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @ObservedObject private var parental = ParentalGate.shared
    @State private var editMode: EditMode = .inactive
    /// A drag's order until the engine answers with it, so the row does not jump back meanwhile.
    @State private var dragged: [Room]?

    /// The rooms the phone's tabs show, in the profile's order.
    private var rows: [Room] {
        dragged ?? Room.arranged(settings.navLayout).filter { $0.navEditable && PhoneTab.of($0) != .home }
    }
    private var hidden: Set<String> { Set(settings.navLayout?.hidden ?? []) }

    var body: some View {
        Form {
            Section {
                ForEach(rows) { room in row(room) }
                    .onMove(perform: move)
            } footer: {
                Text(verbatim: T("Hide or reorder what the tab bar shows. Home and Search stay put. A tab whose rooms are all hidden leaves the bar."))
            }
            Section {
                // One press keeps the film / series / anime side and hides Sports, Live TV, Calendar and Collections.
                Button(T("Streaming only")) { run { await settings.streamingOnlyTabs() } }
                    .accessibilityIdentifier("tabs-streaming-only")
                Button(T("Show all tabs")) { run { await settings.showAllTabs() } }
                    .disabled(hidden.isEmpty)
                    .accessibilityIdentifier("tabs-show-all")
                Button(T("Reset layout")) { run { await settings.resetTabs() } }
                    .accessibilityIdentifier("tabs-reset")
            } footer: {
                if hidden.isEmpty { Text(verbatim: T("Nothing hidden.")) }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Tabs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? T("Done Reordering") : T("Reorder")) {
                    PhoneFeedback.shared.selection()
                    withMotion { editMode = editMode.isEditing ? .inactive : .active }
                }
                .accessibilityIdentifier("tabs-reorder")
            }
        }
        .onChange(of: settings.navLayout) { _, _ in dragged = nil }
        .task { if settings.navLayout == nil { await settings.loadNavLayout() } }
        .accessibilityIdentifier("settings-tabs")
    }

    private func row(_ room: Room) -> some View {
        let locked: Bool = parental.hides(room)
        let tab: PhoneTab = PhoneTab.of(room)
        return Toggle(isOn: shown(room)) {
            HStack(spacing: 14) {
                Image(systemName: room.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BP.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: T(room.label))
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                    Text(verbatim: locked ? T("Hidden for this profile") : T("In the %@ tab", T(tab.title)))
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(locked)
        .accessibilityIdentifier("tabs-toggle-\(room.rawValue)")
    }

    private func shown(_ room: Room) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(room.rawValue) },
            set: { on in
                guard on == hidden.contains(room.rawValue) else { return }
                run { await settings.toggleTabHidden(room) }
            }
        )
    }

    /// The list's drag as one engine move: before the room now below it, or after the one above.
    private func move(_ from: IndexSet, _ to: Int) {
        var list: [Room] = rows
        guard let i = from.first, to != i, to != i + 1 else { return }
        let room: Room = list[i]
        let neighbour: Room = to > i ? list[to - 1] : list[to]
        let after: Bool = to > i
        list.move(fromOffsets: from, toOffset: to)
        dragged = list
        run { await settings.moveTab(room, beside: neighbour, after: after) }
    }

    private func run(_ work: @escaping () async -> Void) {
        PhoneFeedback.shared.selection()
        Task {
            await work()
            dragged = nil
        }
    }
}
