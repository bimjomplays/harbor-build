import SwiftUI

/// Create or edit a profile (the TV's ProfileEditorView, editor-view.tsx): name, colour, avatar, and for
/// whoever may (the primary profile, or anyone making a new one) the PIN and the tabs it locks. A kid
/// profile synced from the TV keeps its kid setup untouched: no kid toggle is offered and nothing here
/// writes the kid config, so it works as it did.
struct PhoneProfileEditor: View {
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var parental = ParentalGate.shared
    let editing: ProfilesStore.Profile?
    let dismiss: () -> Void

    struct AvatarGroup: Decodable, Identifiable {
        struct Item: Decodable, Identifiable { var id: String; var name: String; var path: String }
        var group: String
        var transparent: Bool
        var items: [Item]
        var id: String { group }
    }

    /// The PIN pads the editor opens, one at a time.
    private enum PinStep: String, Identifiable {
        case verifyChange, verifyRemove, verifyUnlock, choose
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var avatar: String?
    @State private var color = ""
    @State private var groups: [AvatarGroup] = []
    @State private var colors: [String] = ProfilesStore.colors
    @State private var draftLocks: [String: Bool] = [:]
    @State private var initialLocks: [String: Bool] = [:]
    /// A new profile's PIN, kept until Create (an existing profile's PIN is set at once).
    @State private var draftPin = ""
    @State private var pinStep: PinStep?
    /// The PIN pad's verdict, acted on once its sheet has gone (a sheet cannot open another while it closes).
    @State private var afterPin: PinStep?
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var deleting = false

    private var activeIsPrimary: Bool { profiles.active?.isPrimary == true }
    /// The profile as the store has it now: a PIN set in this editor lands there at once.
    private var current: ProfilesStore.Profile? {
        editing.map { e in profiles.profiles.first(where: { $0.id == e.id }) ?? e }
    }

    /// editor-view.tsx `showAdvanced = canEditAdvanced || mode.kind === "create"`: the PIN and tab locks
    /// are the primary profile's to change (a child on their own profile cannot lift them).
    private var showAdvanced: Bool { editing == nil || activeIsPrimary }
    /// A kid profile has its own parent PIN (set on the TV) instead of tab locks.
    private var showSecurity: Bool { showAdvanced && current?.kid == nil }
    private var hasPin: Bool { current.map { $0.passwordHash != nil } ?? ProfilesStore.isValidPin(draftPin) }
    /// Changing or removing the PIN of the profile in use asks for that PIN first, so whoever is holding
    /// an unlocked phone cannot just lift it. The primary editing another profile is the parent override.
    private var asksCurrentPin: Bool { current.map { $0.passwordHash != nil && $0.id == profiles.activeId } ?? false }
    /// The profile in use is locked right now: its locks change only after its PIN (parental.tsx `locked`).
    private var needsUnlock: Bool {
        guard let e = editing, e.id == profiles.activeId else { return false }
        return parental.gate.locked
    }
    private var lockedCount: Int { draftLocks.values.filter { $0 }.count }
    private var canDelete: Bool {
        guard let e = editing else { return false }
        return !e.isPrimary && activeIsPrimary && e.id != profiles.activeId
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !color.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileFace(name: name.isEmpty ? "?" : name, colorHex: color.isEmpty ? ProfilesStore.colors[0] : color, avatar: avatar, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField(T("Who is this for?"), text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("profile-name-field")
                } header: {
                    Text(verbatim: T("Name"))
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 14) {
                        ForEach(Array(colors.enumerated()), id: \.element) { index, c in
                            Button { color = c; PhoneFeedback.shared.selection() } label: {
                                Circle().fill(Color(css: c) ?? BP.ink)
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().strokeBorder(BP.ink, lineWidth: color == c ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: "\(T("Color")) \(index + 1)"))
                            .accessibilityAddTraits(color == c ? .isSelected : [])
                            .accessibilityIdentifier("profile-color-\(index + 1)")
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(verbatim: T("Colour"))
                }
                if showSecurity { securitySection }
                if let kid = current?.kid { kidSection(kid) }
                Section {
                    NavigationLink {
                        PhoneAvatarPicker(groups: groups, avatar: $avatar, name: name, colorHex: color)
                    } label: {
                        HStack {
                            Text(verbatim: T("Avatar"))
                            Spacer(minLength: 8)
                            ProfileFace(name: name.isEmpty ? "?" : name, colorHex: color.isEmpty ? ProfilesStore.colors[0] : color, avatar: avatar, size: 34)
                        }
                    }
                    .accessibilityIdentifier("profile-avatar-row")
                    if avatar != nil {
                        Button(T("Use initials instead")) { avatar = nil }
                            .accessibilityIdentifier("profile-avatar-none")
                    }
                }
                if canDelete {
                    Section {
                        Button(T("Delete profile"), role: .destructive) { confirmDelete = true }
                            .disabled(deleting)
                            .accessibilityIdentifier("profile-delete")
                    } footer: {
                        Text(verbatim: T("This removes the profile, with its PIN and resume points, from this iPhone."))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PhoneBackground())
            .navigationTitle(T(editing == nil ? "New profile" : "Edit profile"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(BP.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("Cancel"), action: dismiss).accessibilityIdentifier("profile-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T(editing == nil ? "Create" : "Save")) { Task { await save() } }
                        .disabled(!canSave || saving)
                        .accessibilityIdentifier("profile-save")
                }
            }
        }
        .sheet(item: $pinStep, onDismiss: runAfterPin) { step in pinSheet(step) }
        .alert(T("Delete %@?", current?.name ?? ""), isPresented: $confirmDelete) {
            Button(T("Delete"), role: .destructive) { delete() }
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: T("This removes the profile, with its PIN and resume points, from this iPhone."))
        }
        .presentedCover("profile-editor")
        .accessibilityIdentifier("profile-editor")
        .task { await load() }
    }

    // MARK: PIN & locks (editor-view.tsx SecurityRow / TabsView)

    @ViewBuilder private var securitySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: hasPin ? "lock.fill" : "lock.open")
                    .foregroundStyle(hasPin ? BP.live : Color.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: T(hasPin ? "PIN on" : "PIN off"))
                    .accessibilityIdentifier("profile-pin-state")
            }
            Button(T(hasPin ? "Change PIN" : "Set a PIN")) {
                pinStep = hasPin && asksCurrentPin ? .verifyChange : .choose
            }
            .accessibilityIdentifier("profile-pin-set")
            if hasPin {
                Button(T("Remove PIN"), role: .destructive) {
                    if asksCurrentPin { pinStep = .verifyRemove } else { removePin() }
                }
                .accessibilityIdentifier("profile-pin-remove")
            }
        } header: {
            Text(verbatim: T("PIN & locks"))
        } footer: {
            Text(verbatim: T("PINs stay on this iPhone. They never sync."))
        }
        Section {
            if needsUnlock {
                Button(T("Enter PIN to change locks")) { pinStep = .verifyUnlock }
                    .accessibilityIdentifier("profile-unlock-locks")
                Text(verbatim: T("%lld tabs require this profile's PIN.", lockedCount))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(parental.lockable) { tab in
                    let on = draftLocks[tab.key] ?? false
                    Toggle(isOn: Binding(get: { draftLocks[tab.key] ?? false }, set: { draftLocks[tab.key] = $0 })) {
                        Label(tab.label, systemImage: on ? "lock.fill" : "lock.open")
                    }
                    .accessibilityIdentifier("lock-tab-\(tab.key)")
                }
            }
        } header: {
            Text(verbatim: T("Lock tabs"))
        } footer: {
            Text(verbatim: lockedCount == 0 ? T("No tabs selected")
                 : (hasPin ? T("%lld selected · locked tabs disappear until this profile's PIN is entered.", lockedCount)
                    : T("%lld selected · Locks only activate once a PIN is set.", lockedCount)))
        }
    }

    @ViewBuilder private func pinSheet(_ step: PinStep) -> some View {
        switch step {
        case .verifyChange, .verifyRemove, .verifyUnlock:
            if let profile = current {
                PhonePinPad(title: T("Enter %@'s PIN", profile.name),
                            subtitle: T("Enter the current PIN to continue."),
                            cooldownKey: profile.id,
                            verify: { profiles.verifyPin($0, for: profile) },
                            finish: { ok in
                                if ok {
                                    if step == .verifyUnlock { profiles.unlockParental(profile.id) } else { afterPin = step }
                                }
                                pinStep = nil
                            })
                    .presentationDetents([.large])
            }
        case .choose:
            PhoneNewPinSheet(title: T("Set a 4-digit PIN")) { pin in
                if let pin { applyPin(pin) }
                pinStep = nil
            }
            .presentationDetents([.large])
        }
    }

    /// The verify pad has closed: carry on with what it was for.
    private func runAfterPin() {
        guard let next = afterPin else { return }
        afterPin = nil
        switch next {
        case .verifyChange: pinStep = .choose
        case .verifyRemove: removePin()
        case .verifyUnlock, .choose: break
        }
    }

    private func applyPin(_ pin: String) {
        PhoneFeedback.shared.success()
        if let e = editing {
            profiles.setPin(pin, for: e.id)
        } else {
            draftPin = pin
        }
    }

    private func removePin() {
        PhoneFeedback.shared.warning()
        if let e = editing {
            profiles.setPin(nil, for: e.id)
        } else {
            draftPin = ""
        }
    }

    // MARK: Kid profile (synced from the TV)

    private static let curfews: [Int: String] = [30: "30 min", 60: "1 hour", 90: "1½ hr", 120: "2 hr", 180: "3 hr"]

    private static func curfewLabel(_ minutes: Int?) -> String {
        guard let minutes else { return T("No limit") }
        if let known = curfews[minutes] { return T(known) }
        return "\(minutes) min"
    }

    @ViewBuilder private func kidSection(_ kid: ProfilesStore.Profile.Kid) -> some View {
        Section {
            LabeledContent(T("Age level"), value: "\(kid.age)")
            LabeledContent(T("Daily watch time"), value: Self.curfewLabel(kid.curfewMinutes))
            LabeledContent(T("Parent PIN"), value: T(kid.parentPinHash != nil ? "PIN set" : "PIN off"))
        } header: {
            Text(verbatim: T("Kid profile"))
        } footer: {
            Text(verbatim: T("This profile was set up as a kid profile on the Apple TV. Harbor for iPhone keeps it working as it is; change its kid setup on the TV."))
        }
        .accessibilityIdentifier("profile-kid-info")
    }

    // MARK: Load, save, delete

    private func load() async {
        // Before any await: a name typed while the catalogue loaded must not be overwritten.
        if name.isEmpty { name = editing?.name ?? (Fixtures.active ? (Fixtures.newProfileName ?? "") : "") }
        if avatar == nil { avatar = editing?.avatar }
        if let c = editing?.color, color.isEmpty { color = c }
        await parental.loadLockable()
        if case .object(let o)? = editing?.lockedTabs {
            initialLocks = o.compactMapValues { $0.bool }
            draftLocks = initialLocks
        }
        groups = (try? await HarborEngine.shared.call("profilesRoom.avatars", [])) ?? []
        if let list: [String] = try? await HarborEngine.shared.call("profilesRoom.colors", []), !list.isEmpty { colors = list }
        if color.isEmpty {
            // Not inside `??`: its right-hand side is an autoclosure that cannot await.
            let picked: String? = try? await HarborEngine.shared.call("profilesRoom.pickColor", [profiles.profiles.map(\.color)])
            color = picked ?? colors.first(where: { c in !profiles.profiles.contains { $0.color == c } }) ?? colors[0]
        }
    }

    /// editor-view.tsx save: updateProfile (edit) or createProfile + patch { passwordHash, lockedTabs }.
    private func save() async {
        guard !saving else { return }
        saving = true
        var writeLocks = false
        var lockValue: AnyJSON? = nil
        let changed = draftLocks.filter { $0.value } != initialLocks.filter { $0.value }
        if showSecurity, !needsUnlock, changed,
           let v = try? await HarborEngine.shared.callJSON("parental.lockedTabsValue", [.object(draftLocks.mapValues { AnyJSON.bool($0) })]) {
            writeLocks = true
            lockValue = v
        }
        if let e = editing {
            profiles.update(e.id, name: name, avatar: .some(avatar), color: color)
            if writeLocks { profiles.setLockedTabs(lockValue, for: e.id) }
        } else {
            let p = profiles.create(name: name, avatar: avatar, color: color)
            if showSecurity, ProfilesStore.isValidPin(draftPin) {
                profiles.setPin(draftPin, for: p.id)
                profiles.markSessionUnlocked(p.id)
            }
            if writeLocks { profiles.setLockedTabs(lockValue, for: p.id) }
        }
        PhoneFeedback.shared.success()
        dismiss()
    }

    private func delete() {
        guard let e = editing, canDelete, !deleting else { return }
        deleting = true
        Task {
            await profiles.delete(e.id)
            dismiss()
        }
    }
}

/// The avatar catalogue the TV offers (65 faces in groups), drawn on the profile's colour. A pick is kept
/// and the page closes; "Use initials instead" in the editor clears it.
struct PhoneAvatarPicker: View {
    let groups: [PhoneProfileEditor.AvatarGroup]
    @Binding var avatar: String?
    let name: String
    let colorHex: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            ForEach(groups) { g in
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        ForEach(g.items) { item in
                            Button {
                                avatar = item.path
                                PhoneFeedback.shared.selection()
                                dismiss()
                            } label: {
                                ProfileFace(name: name, colorHex: colorHex.isEmpty ? ProfilesStore.colors[0] : colorHex, avatar: item.path, size: 52)
                                    .overlay(Circle().strokeBorder(BP.ink, lineWidth: avatar == item.path ? 3 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: item.name))
                            .accessibilityAddTraits(avatar == item.path ? .isSelected : [])
                            .accessibilityIdentifier("profile-avatar-\(item.id)")
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(verbatim: g.group)
                }
            }
            if groups.isEmpty {
                Text(verbatim: T("The avatars are not ready yet. Try again in a moment."))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Avatar"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("profile-avatar-picker")
    }
}
