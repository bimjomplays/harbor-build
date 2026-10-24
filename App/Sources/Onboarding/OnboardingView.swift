import SwiftUI

/// Onboarding wizard (src/views/big-picture/onboarding), in bp-onboard-steps.ts order: language,
/// phone, TMDB, Stremio, layout, services, subtitles, taste, done. The copy column carries
/// each step's aside (the TMDB and Stremio showcases, the layout and subtitle previews, the done
/// flourish) under the headline, where bp-onboarding-frame.tsx mounts [data-bp-onboard-aside].
/// Stremio is the one account step; there is no Harbor account (the service is gone).
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var settings: SettingsBridge

    typealias Step = OnboardingModel.Step
    @StateObject private var model = OnboardingModel()
    /// bp-handoff-context.tsx: the host lives above the steps, not inside the phone screen, so the
    /// code on screen survives Back and Continue and a delivery that lands after the TV moved on
    /// still counts. Listening from the phone step to the end of setup, as
    /// upstream's provider does for the whole flow.
    @StateObject private var handoff = TvHandoff(mode: .setup(HandoffStep.allCases))
    /// advanceBpOnboardRing: once a step's answer is given the ring moves to its primary button.
    @FocusState private var ring: String?
    /// False while the intro wall is up (RootView disables the tree under it).
    @Environment(\.isEnabled) private var enabled

    private var wizard: some View {
        VStack(spacing: 0) {
            ProgressBar(fraction: Double(model.step.rawValue + 1) / Double(Step.allCases.count),
                        valueText: T("%lld of %lld", model.step.rawValue + 1, Step.allCases.count))
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(28))
            HStack(alignment: .top, spacing: BP.px(60)) {
                VStack(alignment: .leading, spacing: 0) {
                    copy
                    Spacer(minLength: BP.px(16))
                    aside
                }
                .frame(width: BP.px(380), alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                content.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(40)).padding(.bottom, BP.hintHeight)
        }
    }

    var body: some View {
        ZStack {
            // bp-onboarding-frame BpOnboardBackdrop: the drifting poster wall behind every step.
            OnboardBackdropView().ignoresSafeArea()
            wizard
                // The dialog is modal (aria-modal): nothing under it takes the ring.
                .disabled(model.leaveOpen)
                .accessibilityHidden(model.leaveOpen)
            if model.leaveOpen {
                OnboardLeaveDialog(onKeep: { model.closeLeave() },
                                   onLater: { model.leaveOpen = false; app.suspendOnboarding() },
                                   onNever: { model.leaveOpen = false; app.finishOnboarding() })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        // bp-onboarding.tsx pushBpBack: Back steps to the previous screen and never
        // reaches the shell while setup is up; there was no handler, so Menu on any step closed the
        // app. On the first screen it opens "Leave setup?" as upstream (Menu
        // there closed the app with no prompt), and with the dialog up it closes the dialog.
        .onExitCommand(perform: model.exitAction(enabled: enabled))
        .onChange(of: model.step) { _, s in
            syncHandoff(s)
            model.stepChanged(s)
        }
        // A resumed setup opens past the phone step (or on the recap) without a step change.
        .onAppear {
            // The focus ring and the phone hand-off live in this view; the model reads and moves them through the binding.
            let ring = $ring
            let host = handoff
            model.bind(read: { ring.wrappedValue }, write: { ring.wrappedValue = $0 }, handoffDone: { host.done })
            model.adoptStremioName(profiles: profiles)
            syncHandoff(model.step)
            model.loadFactsIfNeeded()
        }
        .onChange(of: handoff.done) { _, d in
            if d.contains(.stremio) { model.adoptPendingStremio() }
        }
        // The hand-off's apply named the profile active when the phone step first
        // opened. A first run's seed changes it: a phone Stremio sign-in then went
        // to a dropped profile's key and was lost. It follows the profile setup now edits.
        .onChange(of: profiles.activeId) { _, _ in
            guard handoff.onPayload != nil else { return }
            handoff.onPayload = HandoffApply.make(profileId: editingProfileId)
        }
        .onDisappear { handoff.stop() }
    }

    /// The profile this setup edits: bp-step-stremio's useAuth signs in the
    /// active profile. A setup resumed over profiles (after Who's watching) or replayed from
    /// Settings signs in the profile it runs for; first run has none yet, so the sign-in is parked
    /// (PendingStremio) for the first profile, as before.
    private var editingProfileId: String? {
        profiles.active?.id
    }

    private func syncHandoff(_ s: Step) {
        guard s.rawValue >= Step.phone.rawValue else {
            handoff.stop()
            return
        }
        if handoff.onPayload == nil {
            handoff.onPayload = HandoffApply.make(profileId: editingProfileId)
        }
        handoff.start()
    }

    @ViewBuilder private var copy: some View {
        let (eyebrow, headline, body) = text
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(T(eyebrow)).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
            Text(T(headline)).font(BP.display(36)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
            Text(T(body)).font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .id(model.step)
        .transition(.opacity)
    }

    /// bp-onboard-steps.ts BP_ONBOARD_STEPS copy.
    private var text: (String, String, String) {
        switch model.step {
        case .language: ("Language", "Choose your language", "Harbor speaks this everywhere. You can change it later in Settings.")
        case .phone: ("Your phone", "Finish setup on your phone", "The next two screens need typing. Scan this and your phone does it for you.")
        case .tmdb: ("Artwork and rows", "Connect TMDB", "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail.")
        case .stremio: ("Your library", "Bring in your library", "Your Continue Watching, your watchlist and your addons.")
        case .layout: ("Home", "How should the home screen read?", "Harbor leads with one big title. Classic leads with rows.")
        case .streaming: ("Your services", "Turn off what you do not have", "All of them start on. Take off the ones you do not pay for.")
        case .subtitles: ("Subtitles", "Which subtitle languages, in order?", "First match wins. Most people need only one.")
        case .taste: ("Taste", "What do you like?", "Pick up to five. It shapes what Harbor surfaces first.")
        case .done: ("Ready", "You are set up", "Saved on this device. Another Harbor install starts fresh.")
        }
    }

    /// The step's showcase or preview (BpOnboardAside), bottom of the copy column; bp-rise in.
    @ViewBuilder private var aside: some View {
        Group {
            switch model.step {
            case .tmdb: OnboardTmdbShowcase()
            case .stremio: OnboardStremioShowcase()
            case .layout: OnboardLayoutPreview(mode: settings.slice.homeMode)
            case .subtitles: OnboardSubtitlePreview(languages: settings.slice.preferredSubLangs)
            case .done:
                // Dealt once the viewer's own picks are known, so the deal plays on real art.
                if let f = model.facts { OnboardDoneFlourish(art: f.art) }
            default: EmptyView()
            }
        }
        .id(model.step)
        .transition(.opacity.combined(with: .offset(y: BP.px(14))))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .language:
            OnboardLanguageStep(ring: $ring) { model.advance() }
        case .phone:
            PhoneSetupStep(handoff: handoff,
                           tmdbConnected: !settings.slice.tmdbKey.isEmpty,
                           stremioName: model.stremioName,
                           advance: { model.advance() })
        case .tmdb:
            // The key check and the Stremio sign-in answer after a network
            // round trip, by when Back or the step's own skip button may have moved on: their late
            // done() advanced from wherever the viewer was, passing over a step they never saw (Use
            // Cinemeta instead mid-check jumped past Stremio). Only a press made on this screen
            // advances; the result itself is kept either way.
            TmdbKeyForm(done: { if model.step == .tmdb { model.advance() } }, skip: { model.advance() })
        case .stremio:
            // bp-step-stremio.tsx: once signed in (here, or by the phone while
            // this screen was up) the screen says so and offers Continue; the empty form stayed up.
            if let stremioName = model.stremioName {
                StepConfirmed(title: T("Signed in as %@", stremioName), detail: nil) { model.advance() }
            } else {
                StremioSignInForm(profileId: editingProfileId) { name in
                    model.stremioName = name
                    if model.step == .stremio { model.advance() }
                } skip: { model.advance() }
            }
        case .layout:
            VStack(alignment: .leading, spacing: BP.px(16)) {
                HStack(spacing: BP.px(16)) {
                    layoutCard("Harbor", "A hero up top, then Top 10, Trending, In Theaters and your service rows.", mode: "harbor")
                    layoutCard("Classic", "Continue Watching first, then your addon catalogs in install order.", mode: "classic")
                }
                Button("Continue") { model.advance() }
                    .buttonStyle(BPActionStyle(primary: true))
                    .focused($ring, equals: "primary")
            }
        case .streaming:
            StreamingServicesStep(hasKey: !settings.slice.tmdbKey.isEmpty) { model.advance() }
        case .subtitles:
            VStack(alignment: .leading, spacing: BP.px(14)) {
                SubtitleLanguageGrid()
                HStack(spacing: BP.px(12)) {
                    Button("Continue") { model.advance() }.buttonStyle(BPActionStyle(primary: true))
                    Button("Skip") { model.advance() }.buttonStyle(BPActionStyle())
                }
                // bp-step-subtitles.tsx: an empty list says so; it read "In order: ".
                let langs: [String] = settings.slice.preferredSubLangs
                BPNote(text: langs.isEmpty ? T("Nothing selected. Harbor will not load a subtitle on its own.") : T("In order: %@", langs.joined(separator: ", ")))
            }
        case .taste:
            TasteStep { model.advance() }
        case .done:
            // bp-step-done.tsx: the recap lines, then Start watching.
            VStack(alignment: .leading, spacing: BP.px(16)) {
                RecapRow(ok: !settings.slice.tmdbKey.isEmpty, text: settings.slice.tmdbKey.isEmpty ? "Running on Cinemeta. Add a TMDB key in Settings whenever you want." : "TMDB connected")
                if let f = model.facts {
                    RecapRow(ok: f.servicesOn > 0, text: T("%lld streaming services on", f.servicesOn))
                }
                RecapRow(ok: model.stremioName != nil, text: model.stremioName.map { T("Signed in as %@", $0) } ?? "Not signed in to Stremio. Your library stays local.")
                RecapRow(ok: !settings.slice.preferredSubLangs.isEmpty,
                         text: settings.slice.preferredSubLangs.isEmpty ? "No subtitle languages set" : T("Subtitles: %@", settings.slice.preferredSubLangs.joined(separator: ", ")))
                if let f = model.facts, f.tastePicks > 0 {
                    RecapRow(ok: true, text: T("%lld titles you like", f.tastePicks))
                }
                Button("Start watching") { app.finishOnboarding() }
                    .buttonStyle(BPActionStyle(primary: true))
                    .accessibilityIdentifier("onboarding-start")
                BPNote(text: "Everything here took effect straight away, and it is saved on this device.")
            }
        }
    }

    /// bp-step-layout.tsx: two choice cards, applied instantly; the ring then moves to Continue
    /// (advanceBpOnboardRing), so the preview beside the copy shows what was picked.
    private func layoutCard(_ title: String, _ blurb: String, mode: String) -> some View {
        Button {
            Task {
                try? await settings.patch(["homeMode": .string(mode)])
                ring = "primary"
            }
        } label: {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(T(title)).font(BP.display(22)).foregroundStyle(BP.ink)
                Text(T(blurb)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                if settings.slice.homeMode == mode { Text("Current").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase) }
            }
            .padding(BP.px(20))
            .frame(width: BP.px(280), height: BP.px(160), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(settings.slice.homeMode == mode ? BP.glass : BP.panel2))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
    }
}

struct ProgressBar: View {
    let fraction: Double
    /// bp-onboarding-frame.tsx aria-valuenow / aria-valuemax, read as "3 of 10".
    var valueText = ""
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(BP.edge)
                Capsule().fill(BP.ink).frame(width: g.size.width * fraction)
            }
        }
        .frame(height: BP.px(4))
        .animation(BP.easeSlow, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue(Text(verbatim: valueText))
    }
}

/// bp-step-parts.tsx BpStepConfirmed: a step already satisfied says so, with the primary Continue.
struct StepConfirmed: View {
    let title: String
    let detail: String?
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HStack(alignment: .top, spacing: BP.px(14)) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: BP.px(30))).foregroundStyle(BP.live).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(verbatim: title).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(T(detail)).font(BP.sans(15)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("Continue", action: next).buttonStyle(BPActionStyle(primary: true))
        }
        .frame(maxWidth: BP.px(560), alignment: .leading)
    }
}

/// bp-onboarding.tsx BpOnboardLeave: Back on the first screen. Keep setting up
/// holds the ring (data-bp-autofocus) and closes the dialog; Finish later leaves setup for this run
/// only (BpOnboardingGate.suspend, the next launch resumes in place); Do not show this again, on
/// its own row and never the default, marks Harbor onboarded (BpOnboardingGate.complete).
private struct OnboardLeaveDialog: View {
    let onKeep: () -> Void
    let onLater: () -> Void
    let onNever: () -> Void
    @FocusState private var keepFocused: Bool

    var body: some View {
        ZStack {
            BP.void_.opacity(0.84).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(28)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Leave setup?").font(BP.display(36)).foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Nothing you have already set is lost. Harbor picks this back up where you left it.")
                        .font(BP.sans(19)).foregroundStyle(BP.inkSubtle).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Neither pill is primary: the filled one on screen is always the one the ring is on.
                HStack(spacing: BP.px(12)) {
                    Button {
                        BPSound.shared.click()
                        onKeep()
                    } label: {
                        Text("Keep setting up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BPActionStyle())
                    .focused($keepFocused)
                    Button {
                        BPSound.shared.close()
                        onLater()
                    } label: {
                        Text("Finish later").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BPActionStyle())
                }
                .focusSection()
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        BPSound.shared.close()
                        onNever()
                    } label: {
                        Text("Do not show this again").foregroundStyle(BP.inkMuted)
                    }
                    .buttonStyle(BPActionStyle())
                    Spacer(minLength: 0)
                }
                .focusSection()
            }
            .padding(BP.px(44))
            .frame(width: BP.px(720))
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel2))
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { DispatchQueue.main.async { keepFocused = true } }
    }
}

struct RecapRow: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: BP.px(10)) {
            // Decorative: the text on every row already says whether that item is done.
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? BP.live : BP.inkSubtle)
                .accessibilityHidden(true)
            Text(T(text)).font(BP.sans(15)).foregroundStyle(BP.ink)
        }
    }
}

/// Stremio email + password (bp-step-stremio.tsx). Signs in to api.strem.io and stores the
/// authKey for a profile; `profileId == nil` parks it until the first profile exists.
struct StremioSignInForm: View {
    let profileId: String?
    let done: (String) -> Void
    let skip: (() -> Void)?
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            BPField(label: "Email", placeholder: "you@example.com", text: $email, keyboard: .emailAddress)
            BPField(label: "Password", placeholder: "Your Stremio password", text: $password, secure: true)
            HStack(spacing: BP.px(12)) {
                Button(busy ? "Signing in…" : "Sign in") { Task { await signIn() } }
                    .buttonStyle(BPActionStyle(primary: true, busy: busy)).disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                if let skip { Button("Not now", action: skip).buttonStyle(BPActionStyle()) }
            }
            // bp-step-stremio.tsx: the failure takes the note's place (text={error ?? …}, alert).
            BPNote(text: error ?? "Skip this and Harbor still works. Your library just stays local.", tone: error == nil ? BP.inkMuted : BP.danger)
        }
        .frame(maxWidth: BP.px(520))
    }

    private func signIn() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        // bp-step-stremio.tsx submit: setError(null) first, so a retry does not keep the last failure.
        error = nil
        do {
            let r = try await StremioAPI.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            let session = ProfilesStore.StremioSession(authKey: r.authKey, user: r.user)
            if let profileId { profiles.setStremioSession(session, for: profileId) }
            else { PendingStremio.session = session }
            done(r.user.fullname ?? r.user.email)
        } catch {
            self.error = error.localizedDescription.isEmpty ? "Sign-in failed" : error.localizedDescription
        }
    }
}


/// bp-onboarding-frame.tsx useBpOnboardFocus for a `focus: "decision"` screen
/// whose choices load after it opens (Your services, Taste): the ring waits on the primary while
/// they load, then moves onto the first choice once it mounts, for up to LATE_MOUNT_MS (6 s) and
/// only while nothing else has moved it. The ring stayed on Continue under the grid, so the first
/// OK passed over the step the viewer had only just reached.
@MainActor
enum OnboardDecisionSeed {
    /// The step's Continue.
    static let primary = "primary"
    /// bp-onboarding-frame.tsx LATE_MOUNT_MS.
    private static let lateMount: TimeInterval = 6

    /// The step's Skip: tagged so a ring the viewer moved there is not read as "nowhere".
    static let skip = "skip"

    /// `left`: the ring has been in the step and gone out of it (Continue or Skip pressed, Back,
    /// the Leave setup dialog). A step on its way out is still drawn while the next
    /// fades in, and its ring reads nil there: without this a load that finished after Continue
    /// could pull the ring back onto the step the viewer had just left.
    static func place(_ target: String?, opened: Date, ring: FocusState<String?>.Binding, left: () -> Bool) async {
        guard let target, !Task.isCancelled, !left(), Date().timeIntervalSince(opened) < lateMount else { return }
        let before: String? = ring.wrappedValue
        guard before == nil || before == primary else { return }
        // The grid mounts on this pass: focus its first cell once it is there.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, !left() else { return }
        let now: String? = ring.wrappedValue
        guard now == nil || now == primary else { return }
        ring.wrappedValue = target
    }
}

/// onboarding/steps/bp-step-streaming.tsx: every service as a chip, on/off, through the BP settings
/// catalog's "service" control (settingsRoom.commit toggles settings.streaming).
struct StreamingServicesStep: View {
    let hasKey: Bool
    let done: () -> Void
    @State private var items: [BPSettingsModel.MultiItem] = []
    @State private var loaded = false
    /// bp-onboarding-frame useBpOnboardFocus: see OnboardDecisionSeed.
    @FocusState private var ring: String?
    /// The ring went out of this step: the seed stays out (OnboardDecisionSeed.place).
    @State private var ringLeft = false

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if items.isEmpty {
                if loaded { BPNote(text: "No services to choose from on this profile.") } else { ProgressView().tint(BP.inkMuted) }
            } else {
                // Six 253 pt cells (1 568 pt) overran the 891 pt step column (1 632 less the
                // 640 pt aside and the 101 pt gap) and ran off the screen. bp-step-streaming PER_ROW = 4.
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(127)), spacing: BP.px(6)), count: 4), spacing: BP.px(6)) {
                    ForEach(items) { i in
                        Button { Task { await toggle(i) } } label: {
                            HStack(spacing: BP.px(6)) {
                                if let tint = i.tint { Circle().fill(Color(css: tint) ?? BP.ink).frame(width: BP.px(8), height: BP.px(8)) }
                                Text(i.label).font(BP.sans(13, i.on ? .bold : .semibold)).lineLimit(1)
                                if !i.on { Text("Off").font(BP.sans(9, .bold)).foregroundStyle(BP.inkSubtle) }
                            }
                            .foregroundStyle(i.on ? BP.ink : BP.inkSubtle)
                            .padding(.horizontal, BP.px(12)).frame(width: BP.px(127), height: BP.px(46))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(i.on ? BP.panel2 : BP.panel))
                            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(i.on ? BP.edge2 : BP.edge, lineWidth: 1))
                            .opacity(i.on ? 1 : 0.55)
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .focused($ring, equals: "s:\(i.value)")
                        // bp-step-streaming.tsx aria-pressed={enabled}.
                        .bpSelected(i.on)
                    }
                }
                .focusSection()
            }
            BPNote(text: hasKey ? T("%lld on", items.filter(\.on).count) : "These rows need a TMDB key before they show anything.")
            HStack(spacing: BP.px(12)) {
                Button("Continue") { ringLeft = true; done() }.buttonStyle(BPActionStyle(primary: true))
                    .focused($ring, equals: OnboardDecisionSeed.primary)
                Button("Skip") { ringLeft = true; done() }.buttonStyle(BPActionStyle())
                    .focused($ring, equals: OnboardDecisionSeed.skip)
            }
        }
        .task {
            let opened = Date()
            await load()
            let first: String? = items.first.map { "s:\($0.value)" }
            await OnboardDecisionSeed.place(first, opened: opened, ring: $ring, left: { ringLeft })
        }
        .onChange(of: ring) { old, now in
            if old != nil && now == nil { ringLeft = true }
        }
    }

    private var profile: (id: String, linked: Bool) { let p = ProfilesStore.shared.active; return (p?.id ?? "default", p?.linked ?? true) }

    private func load() async {
        let p = profile
        let controls: [BPSettingsModel.Control] = (try? await HarborEngine.shared.call("settingsRoom.controls", ["services", p.id, p.linked])) ?? []
        items = controls.first { $0.id == "service" }?.items ?? []
        loaded = true
    }

    private func toggle(_ i: BPSettingsModel.MultiItem) async {
        let p = profile
        _ = try? await HarborEngine.shared.callJSON("settingsRoom.commit", [.string("service"), .string(i.value), .string(p.id), .bool(p.linked)])
        await load()
    }
}


/// onboarding/steps/bp-step-taste.tsx: a poster grid, up to five picks, written on select through
/// the feed vote store (onboarding.vote) so Skip never throws them away.
struct TasteStep: View {
    let done: () -> Void
    @State private var items: [Meta] = []
    @State private var picked: Set<String> = []
    @State private var loaded = false
    @State private var bump: String?
    /// bp-onboarding-frame useBpOnboardFocus: see OnboardDecisionSeed.
    @FocusState private var ring: String?
    /// The ring went out of this step: the seed stays out (OnboardDecisionSeed.place).
    @State private var ringLeft = false
    private static let max = 5
    /// Six 253 pt posters (1 603 pt) overran the 891 pt step column, and the scroller
    /// centred and clipped them. bp-step-taste keeps PER_ROW = 6 at the column's width: 6 × px(76)
    /// + gaps = 853 pt, with headroom inside the scroller for the focus ring (887 pt).
    private static let columns = Array(repeating: GridItem(.fixed(BP.px(76)), spacing: BP.px(10)), count: 6)

    private var onScreen: Int { items.filter { picked.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            if !loaded { BPNote(text: "Finding titles…") }
            else if items.isEmpty { BPNote(text: "Couldn't load titles right now. You can pick favourites later from any detail page.") }
            else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Self.columns, spacing: BP.px(14)) {
                        ForEach(items) { m in
                            let on = picked.contains(m.id)
                            Button { Task { await toggle(m) } } label: {
                                ZStack(alignment: .topTrailing) {
                                    RemoteImage(url: m.poster).frame(width: BP.px(76), height: BP.px(114))
                                        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(on ? BP.accent : .clear, lineWidth: 3))
                                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: BP.px(22))).foregroundStyle(BP.accent).padding(BP.px(6)).accessibilityHidden(true) }
                                }
                                .offset(y: bump == m.id ? -6 : 0)
                            }
                            .buttonStyle(BPTileStyle(radius: BP.rXS))
                            .focused($ring, equals: "t:\(m.id)")
                            // A poster with no caption: the title, selected once it is picked.
                            .accessibilityLabel(Text(verbatim: m.name))
                            .bpSelected(on)
                        }
                    }
                    .padding(.vertical, BP.px(10)).padding(.horizontal, BP.px(10))
                }
                .frame(height: BP.px(500))
                .focusSection()
            }
            BPNote(text: onScreen >= Self.max ? "That is five. Deselect one to swap it out." : T("%lld of %lld picked", onScreen, Self.max))
            HStack(spacing: BP.px(12)) {
                Button("Continue") { ringLeft = true; done() }.buttonStyle(BPActionStyle(primary: true))
                    .focused($ring, equals: OnboardDecisionSeed.primary)
                Button("Skip") { ringLeft = true; done() }.buttonStyle(BPActionStyle())
                    .focused($ring, equals: OnboardDecisionSeed.skip)
            }
        }
        .task {
            let opened = Date()
            let p = ProfilesStore.shared.active
            items = (try? await HarborEngine.shared.call("onboarding.tasteTitles", [p?.id ?? "default", p?.linked ?? true])) ?? []
            picked = Set((try? await HarborEngine.shared.call("onboarding.upvoted", []) as [String]) ?? [])
            loaded = true
            let first: String? = items.first.map { "t:\($0.id)" }
            await OnboardDecisionSeed.place(first, opened: opened, ring: $ring, left: { ringLeft })
        }
        .onChange(of: ring) { old, now in
            if old != nil && now == nil { ringLeft = true }
        }
    }

    private func toggle(_ m: Meta) async {
        let on = picked.contains(m.id)
        if !on, onScreen >= Self.max {
            // At the cap an unpicked tile refuses visibly (the nudge), never silently.
            withAnimation(.easeOut(duration: 0.19)) { bump = m.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { bump = nil } }
            return
        }
        // A failed vote keeps the picks on screen: `?? []` cleared every tick
        // while the picks were still saved in the vote store.
        let ids: [String]? = try? await HarborEngine.shared.call("onboarding.vote", [m.id, !on, m.name, m.type])
        if let ids { picked = Set(ids) }
    }
}
