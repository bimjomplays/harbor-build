import SwiftUI

/// "Who's watching?": the profile faces in a grid. A profile with a PIN asks for it in a sheet; the
/// profile already in use just closes the chooser. Local profiles only (the roster is the engine's).
struct PhoneWhoView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var pinFor: ProfilesStore.Profile?
    /// Touch and hold on a face opens its editor.
    @State private var editing: ProfilesStore.Profile?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text(T("Who's watching?"))
                        .font(PhoneTheme.display(32, .semibold, relativeTo: .largeTitle))
                        .foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(T("Pick a profile to continue."))
                        .font(PhoneTheme.sans(16, .regular, relativeTo: .callout))
                        .foregroundStyle(BP.inkMuted)
                }
                .padding(.top, 48)
                if profiles.profiles.isEmpty {
                    EmptyState(title: T("No profiles yet"), message: T("Finish setup to make the first one."),
                               systemImage: "person.crop.circle.badge.plus")
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(profiles.profiles) { profile in tile(profile) }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                    if profiles.profiles.contains(where: canEdit) {
                        Text(T("Touch and hold a profile to edit it."))
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkSubtle)
                    }
                }
                if app.canCloseWho {
                    Button(T("Cancel")) { app.closeWho() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("who-cancel")
                }
            }
            .padding(.bottom, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $pinFor) { profile in
            PhonePinPad(title: T("Enter %@'s PIN", profile.name),
                        subtitle: T("Profile is locked. Enter the 4-digit PIN to continue."),
                        cooldownKey: profile.id,
                        verify: { profiles.verifyPin($0, for: profile) },
                        finish: { ok in
                            pinFor = nil
                            if ok { commit(profile.id, unlocked: true) }
                        })
                .presentationDetents([.large])
        }
        .sheet(item: $editing) { profile in
            PhoneProfileEditor(editing: profile, dismiss: { editing = nil })
                .environmentObject(profiles)
        }
        // A profile the roster sync removed takes its PIN pad and its editor with it.
        .onChange(of: profiles.profiles) { _, list in
            if let p = pinFor, !list.contains(where: { $0.id == p.id }) { pinFor = nil }
            if let p = editing, !list.contains(where: { $0.id == p.id }) { editing = nil }
        }
        .accessibilityIdentifier("who-is-watching")
    }

    private func tile(_ profile: ProfilesStore.Profile) -> some View {
        Button {
            PhoneFeedback.shared.selection()
            choose(profile)
        } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileFace(name: profile.name, colorHex: profile.color, avatar: profile.avatar, size: 96)
                    if profile.passwordHash != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(BP.ink)
                            .padding(7)
                            .glassEffect(.regular, in: .circle)
                    }
                }
                Text(verbatim: profile.name)
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                if profile.kid != nil {
                    Text(T("Kids"))
                        .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                        .foregroundStyle(BP.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            if canEdit(profile) {
                Button { editing = profile } label: { Label(T("Edit profile"), systemImage: "pencil") }
                    .accessibilityIdentifier("who-edit-\(profile.id)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: profile.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(T("Edit profile"))) { if canEdit(profile) { editing = profile } }
        .accessibilityIdentifier("profile-\(profile.name)")
    }

    /// picker-modal.tsx `canEditThis`: the primary profile edits any profile, another edits only itself.
    /// Nobody in use yet (the launch chooser) edits nothing: the PIN and locks are the primary's to change.
    private func canEdit(_ profile: ProfilesStore.Profile) -> Bool {
        profiles.active?.isPrimary == true || profile.id == profiles.activeId
    }

    /// The active profile just closes the chooser (no PIN, no switch); another asks for its PIN when
    /// it has one.
    private func choose(_ profile: ProfilesStore.Profile) {
        if profile.id == profiles.activeId {
            app.closeWho()
            return
        }
        if profile.passwordHash != nil {
            pinFor = profile
        } else {
            commit(profile.id, unlocked: false)
        }
    }

    /// A profile that left the roster meanwhile is not selected (the shell would open on an active
    /// id with no profile behind it). A setup waiting under the chooser continues for the picked
    /// profile (AppModel.pickedOnWho), else the shell opens.
    private func commit(_ id: String, unlocked: Bool) {
        guard profiles.profiles.contains(where: { $0.id == id }) else { return }
        profiles.select(id, unlocked: unlocked)
        app.pickedOnWho()
    }
}

/// A 4-digit keypad: three tries, then a 30 s cool-down per profile, and a shake on a miss. `verify`
/// decides what the right PIN is (the profile's own, or a kid's parent PIN).
struct PhonePinPad: View {
    let title: String
    let subtitle: String
    let cooldownKey: String
    let verify: (String) -> Bool
    let finish: (Bool) -> Void

    @State private var entry = ""
    @State private var shakeX: CGFloat = 0
    @State private var cooldownUntil: Date?
    @State private var now = Date()

    private static var tries: [String: Int] = [:]
    private static var cooldowns: [String: Date] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondsLeft: Int {
        guard let cooldownUntil else { return 0 }
        return max(0, clampedInt(cooldownUntil.timeIntervalSince(now).rounded(.up)))
    }

    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    var body: some View {
        VStack(spacing: 22) {
            Text(verbatim: title)
                .font(PhoneTheme.display(26, .semibold, relativeTo: .title2))
                .foregroundStyle(BP.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 36)
            Text(verbatim: secondsLeft > 0 ? T("Too many tries. Try again in %llds.", secondsLeft) : subtitle)
                .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                .foregroundStyle(BP.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < entry.count ? BP.ink : BP.ink.opacity(0.25)).frame(width: 14, height: 14)
                }
            }
            .offset(x: shakeX)
            // The dots are decoration; a count of four stands in.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(T("PIN")))
            .accessibilityValue(Text(verbatim: "\(entry.count) / 4"))
            .accessibilityIdentifier("pin-dots")
            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 14), count: 3), spacing: 14) {
                    ForEach(keys, id: \.self) { key in keyButton(key) }
                }
            }
            Button(T("Cancel")) { finish(false) }
                .buttonStyle(.glass)
                .accessibilityIdentifier("pin-cancel")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneBackground())
        .onAppear { cooldownUntil = Self.cooldowns[cooldownKey] }
        .onReceive(timer) { now = $0 }
        .presentedCover("pin")
        .accessibilityIdentifier("pin-pad")
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 76, height: 76)
        } else {
            Button { tap(key) } label: {
                Group {
                    if key == "⌫" {
                        Image(systemName: "delete.left").font(.title3)
                    } else {
                        Text(verbatim: key).font(PhoneTheme.sans(28, .medium, relativeTo: .title))
                    }
                }
                .foregroundStyle(BP.ink)
                .frame(width: 76, height: 76)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(secondsLeft > 0)
            .accessibilityLabel(Text(verbatim: key == "⌫" ? T("Delete") : key))
            .accessibilityIdentifier("pin-key-\(key)")
        }
    }

    private func tap(_ key: String) {
        PhoneFeedback.shared.tap()
        if key == "⌫" {
            if !entry.isEmpty { entry.removeLast() }
            return
        }
        guard entry.count < 4 else { return }
        entry += key
        if entry.count == 4 { check() }
    }

    private func check() {
        if verify(entry) {
            Self.tries[cooldownKey] = 0
            PhoneFeedback.shared.success()
            finish(true)
            return
        }
        entry = ""
        PhoneFeedback.shared.failure()
        shake()
        let misses: Int = (Self.tries[cooldownKey] ?? 0) + 1
        Self.tries[cooldownKey] = misses
        if misses >= 3 {
            Self.tries[cooldownKey] = 0
            let until = Date().addingTimeInterval(30)
            Self.cooldowns[cooldownKey] = until
            cooldownUntil = until
            now = Date()
        }
    }

    /// The wrong-PIN shake; under Reduce Motion the pad stays put (the haptic and the message say it).
    private func shake() {
        guard !PhoneMotion.reduced else { return }
        Task {
            let steps: [CGFloat] = [-10, 10, -8, 8, -4, 4, 0]
            for dx in steps {
                withMotion(.linear(duration: 0.045)) { shakeX = dx }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }
}

/// Time's up: a kid's day allowance is spent. Only the parent PIN (or switching profile) lifts it;
/// it is never dismissed by a sheet or a link. Over everything in the root, so a sheet is closed
/// first (PhoneShellView does that when the lock comes up).
struct CurfewCoverView: View {
    /// Called when a launch-argument preview (not a real lock) is unlocked.
    let previewDismiss: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var curfew = CurfewState.shared
    @State private var askingPin = false

    private var kidProfile: ProfilesStore.Profile? { curfew.profile ?? profiles.active }
    private var parentPinHash: String? { kidProfile?.kid?.parentPinHash }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0b3a5c), Color(hex: 0x0a7d9c)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image("HarborMark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text(T("Time's up!"))
                    .font(PhoneTheme.display(44, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(Color.white)
                    .accessibilityAddTraits(.isHeader)
                Text(T("The ship is sailing away. Thanks for watching with Harbor, it's time to listen to your grown-ups."))
                    .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(T(parentPinHash != nil ? "A grown-up can enter the parent PIN to keep watching." : "Ask a grown-up to switch profiles."))
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if parentPinHash != nil {
                        Button(T("Enter parent PIN")) { askingPin = true }
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("curfew-parent-pin")
                    }
                    Button(T("Switch profile")) { app.stage = .whoIsWatching; previewDismiss() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("curfew-switch")
                }
                .padding(.top, 8)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("curfew-cover")
        .sheet(isPresented: $askingPin) {
            PhonePinPad(title: T("Parent PIN"),
                        subtitle: T("Enter the 4-digit parent PIN to continue."),
                        cooldownKey: "parent-\(kidProfile?.id ?? "")",
                        verify: { entry in parentPinHash.map { ProfilesStore.hashPin(entry) == $0 } ?? false },
                        finish: { ok in
                            askingPin = false
                            if ok {
                                curfew.unlock()
                                previewDismiss()
                            }
                        })
                .presentationDetents([.large])
        }
    }
}
