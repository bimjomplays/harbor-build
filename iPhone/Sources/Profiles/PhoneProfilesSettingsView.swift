import SwiftUI

/// Settings → Profiles (the TV's ManageProfilesView and its Settings buttons): every profile on this phone
/// with its face, name, kind and lock; tap one to edit it, Add profile for a new one, and for the primary
/// profile Edit to reorder (drag) or remove (swipe). A profile that is not primary edits only itself, as on
/// the TV (picker-modal.tsx `canEditThis`); kid profiles synced from the TV are listed and kept as they are.
struct PhoneProfilesSettingsView: View {
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var editing: ProfilesStore.Profile?
    @State private var adding = false
    @State private var editMode: EditMode = .inactive
    @State private var removing: ProfilesStore.Profile?

    private var activeIsPrimary: Bool { profiles.active?.isPrimary == true }

    private func canEdit(_ p: ProfilesStore.Profile) -> Bool { activeIsPrimary || p.id == profiles.activeId }
    /// Only the primary removes a profile, never the primary itself or the profile in use.
    private func canRemove(_ p: ProfilesStore.Profile) -> Bool { activeIsPrimary && !p.isPrimary && p.id != profiles.activeId }

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { p in row(p) }
                    .onMove { from, to in if activeIsPrimary { profiles.move(from: from, to: to) } }
                    .onDelete { offsets in
                        removing = offsets.compactMap { profiles.profiles[safe: $0] }.first(where: canRemove)
                    }
            } header: {
                Text(verbatim: T("%lld profiles on this iPhone", profiles.profiles.count))
            } footer: {
                Text(verbatim: T(activeIsPrimary ? "Pick a profile to edit its name, avatar, PIN and tab locks." : "You can edit your own profile. The primary profile edits the others."))
            }
            Section {
                Button { adding = true } label: {
                    Label(T("Add profile"), systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("settings-add-profile")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Profiles"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(BP.accent)
        .environment(\.editMode, $editMode)
        .toolbar {
            if activeIsPrimary, profiles.profiles.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T(editMode.isEditing ? "Done" : "Edit")) {
                        withMotion { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .accessibilityIdentifier("profiles-edit")
                }
            }
        }
        .sheet(item: $editing) { p in
            PhoneProfileEditor(editing: p, dismiss: { editing = nil })
                // A sheet over a pushed page: hand the store down explicitly.
                .environmentObject(profiles)
        }
        .sheet(isPresented: $adding) {
            PhoneProfileEditor(editing: nil, dismiss: { adding = false })
                .environmentObject(profiles)
        }
        .alert(T("Delete %@?", removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(T("Delete"), role: .destructive) {
                if let p = removing { Task { await profiles.delete(p.id) } }
                removing = nil
            }
            Button(T("Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(verbatim: T("This removes the profile, with its PIN and resume points, from this iPhone."))
        }
        .accessibilityIdentifier("settings-profiles")
    }

    private func row(_ p: ProfilesStore.Profile) -> some View {
        Button {
            if canEdit(p) { editing = p }
        } label: {
            HStack(spacing: 14) {
                ProfileFace(name: p.name, colorHex: p.color, avatar: p.avatar, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: p.name)
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                    Text(verbatim: subtitle(p))
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .caption))
                        .foregroundStyle(BP.inkMuted)
                }
                Spacer(minLength: 8)
                if p.passwordHash != nil {
                    Image(systemName: "lock.fill").foregroundStyle(BP.inkMuted).accessibilityHidden(true)
                }
                if canEdit(p), !editMode.isEditing {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BP.inkSubtle)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .deleteDisabled(!canRemove(p))
        .moveDisabled(!activeIsPrimary)
        .accessibilityLabel(Text(verbatim: canEdit(p) ? T("Edit %@", p.name) : p.name))
        .accessibilityValue(Text(verbatim: subtitle(p)))
        .accessibilityIdentifier("manage-profile-\(p.id)")
    }

    private func subtitle(_ p: ProfilesStore.Profile) -> String {
        var kind = p.isPrimary ? T("Primary") : (p.kid != nil ? T("Kid profile") : T("Standard profile"))
        if p.id == profiles.activeId { kind += " · " + T("Watching now") }
        return kind
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
