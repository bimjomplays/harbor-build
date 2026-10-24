import SwiftUI

/// First-run setup on the phone: language, TMDB key (optional), Stremio sign-in (optional), done.
/// The TV's wizard has nine steps because a remote cannot type; the phone keeps the three that
/// matter and leaves the rest to Settings. The step is remembered, so a relaunch (or the rebuild a
/// language change makes) comes back to it.
struct PhoneOnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var settings: SettingsBridge

    enum Step: Int, CaseIterable { case language, tmdb, stremio, done }

    @State private var step: Step = PhoneOnboardingView.resumeStep()
    /// The Stremio account signed in during setup, for the recap.
    @State private var stremioName: String?

    private static func resumeStep() -> Step {
        guard !Fixtures.active, let raw = Prefs.get(Int.self, for: OnboardingResume.key), let saved = Step(rawValue: raw) else { return .language }
        return saved
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.horizontal, PhoneTheme.margin)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            footer
        }
        .onChange(of: step) { _, now in
            try? Prefs.set(now.rawValue, for: OnboardingResume.key)
        }
        .onAppear {
            if stremioName == nil, let profile = profiles.active ?? profiles.profiles.first,
               let session = profiles.stremioSession(for: profile.id) {
                stremioName = session.user.fullname ?? session.user.email
            }
            if stremioName == nil, let session = PendingStremio.session {
                stremioName = session.user.fullname ?? session.user.email
            }
        }
        // `.contain` keeps the buttons and fields their own identifiers: a bare identifier on a plain
        // container is stamped on its children, so onboarding-continue was not found by the UI test.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? BP.accent : BP.ink.opacity(0.18))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(T("%lld of %lld", step.rawValue + 1, Step.allCases.count)))
    }

    private var header: some View {
        let copy = text
        return VStack(alignment: .leading, spacing: 10) {
            Text(T(copy.0))
                .font(PhoneTheme.sans(13, .semibold, relativeTo: .caption))
                .foregroundStyle(BP.accent)
                .textCase(.uppercase)
                .tracking(1)
            Text(T(copy.1))
                .font(PhoneTheme.display(32, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(BP.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(T(copy.2))
                .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                .foregroundStyle(BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(step)
    }

    /// Eyebrow, headline, body.
    private var text: (String, String, String) {
        switch step {
        case .language: return ("Language", "Choose your language", "Harbor speaks this everywhere. You can change it later in Settings.")
        case .tmdb: return ("Artwork and rows", "Connect TMDB", "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail.")
        case .stremio: return ("Your library", "Bring in your library", "Your Continue Watching, your watchlist and your addons.")
        case .done: return ("All set", "Ready when you are", "Here is what Harbor will start with.")
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .language:
            PhoneLanguageList()
        case .tmdb:
            PhoneTmdbForm(done: { go(.stremio) }, skip: { go(.stremio) })
        case .stremio:
            PhoneStremioForm(signedInName: stremioName, done: { name in stremioName = name; go(.done) }, skip: { go(.done) })
        case .done:
            recap
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .language {
                Button(T("Finish later")) { app.suspendOnboarding() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding-later")
            } else if let previous = Step(rawValue: step.rawValue - 1) {
                Button(T("Back")) { go(previous) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding-back")
            }
            Spacer(minLength: 0)
            switch step {
            case .language:
                Button(T("Continue")) { go(.tmdb) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("onboarding-continue")
            case .done:
                Button(T("Start watching")) {
                    PhoneFeedback.shared.success()
                    app.finishOnboarding()
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("onboarding-start")
            case .tmdb, .stremio:
                EmptyView()
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.vertical, 12)
    }

    private func go(_ next: Step) {
        PhoneFeedback.shared.selection()
        withMotion(.easeInOut(duration: 0.2)) { step = next }
    }

    private var recap: some View {
        VStack(alignment: .leading, spacing: 0) {
            recapRow("Language", PhoneLanguageList.name(for: L10n.normalize(settings.slice.uiLanguage)))
            recapRow("TMDB", settings.slice.tmdbKey.isEmpty ? T("Not connected, Harbor runs on Cinemeta") : T("Connected"))
            recapRow("Stremio", stremioName ?? T("Not signed in"))
        }
        .phoneGlassPlate()
        .accessibilityIdentifier("onboarding-recap")
    }

    private func recapRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(T(label)).font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline)).foregroundStyle(BP.inkMuted)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(BP.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

/// The sixteen languages Harbor ships, each in its own name. Picking one saves settings.uiLanguage,
/// and the root rebuilds in it.
struct PhoneLanguageList: View {
    @EnvironmentObject private var settings: SettingsBridge

    private static let names: [(String, String)] = [
        ("en", "English"), ("ar", "العربية"), ("de", "Deutsch"), ("es", "Español"),
        ("fr", "Français"), ("hi", "हिन्दी"), ("id", "Bahasa Indonesia"), ("it", "Italiano"),
        ("ja", "日本語"), ("ko", "한국어"), ("pl", "Polski"), ("pt", "Português"),
        ("ru", "Русский"), ("tr", "Türkçe"), ("vi", "Tiếng Việt"), ("zh", "中文"),
    ]

    static func name(for code: String) -> String {
        names.first(where: { $0.0 == code })?.1 ?? "English"
    }

    var body: some View {
        let current: String = L10n.normalize(settings.slice.uiLanguage)
        VStack(spacing: 0) {
            ForEach(Self.names, id: \.0) { entry in
                Button {
                    PhoneFeedback.shared.selection()
                    let code = entry.0
                    Task { try? await settings.patch(["uiLanguage": .string(code)]) }
                } label: {
                    HStack {
                        Text(verbatim: entry.1)
                            .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                            .foregroundStyle(BP.ink)
                        Spacer()
                        if entry.0 == current {
                            Image(systemName: "checkmark").foregroundStyle(BP.accent).accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(entry.0 == current ? [.isSelected] : [])
                .accessibilityIdentifier("language-\(entry.0)")
                if entry.0 != Self.names.last?.0 { Divider().padding(.leading, 16) }
            }
        }
        .phoneGlassPlate()
    }
}

/// Connect TMDB: the key is checked against TMDB (engine onboarding.checkTmdbKey) and saved only once
/// TMDB accepts it. A refusal and an unreachable TMDB say different things, and only the second
/// offers "Save it anyway".
struct PhoneTmdbForm: View {
    let done: () -> Void
    let skip: () -> Void
    @EnvironmentObject private var settings: SettingsBridge
    @State private var key = ""
    /// "idle" | "checking" | "rejected" | "unreachable".
    @State private var check = "idle"
    @State private var saveError: String?

    private static let maxLength = 64
    private static let keyLength = 32

    private var draft: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { check == "checking" }
    private var alert: Bool { check == "rejected" || check == "unreachable" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !settings.slice.tmdbKey.isEmpty && key.isEmpty {
                Text(T("TMDB connected"))
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(BP.ink)
            }
            TextField(T("TMDB API key, v3 auth"), text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                .padding(14)
                .phoneGlassPlate(radius: PhoneTheme.radiusSmall)
                .accessibilityIdentifier("tmdb-key")
            Text(verbatim: noteText)
                .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                .foregroundStyle(alert ? BP.danger : BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let saveError {
                Text(verbatim: saveError).font(PhoneTheme.sans(14, .regular, relativeTo: .footnote)).foregroundStyle(BP.danger)
            }
            HStack(spacing: 12) {
                Button(busy ? T("Checking…") : T("Verify key")) { Task { await verify() } }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || draft.isEmpty)
                    .accessibilityIdentifier("tmdb-verify")
                if check == "unreachable" && !draft.isEmpty {
                    Button(T("Save it anyway")) { Task { await save() } }.buttonStyle(.glass)
                }
            }
            HStack(spacing: 12) {
                if !settings.slice.tmdbKey.isEmpty {
                    Button(T("Keep the key I have"), action: done).buttonStyle(.glass)
                } else {
                    Button(T("Use Cinemeta instead"), action: skip)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("tmdb-skip")
                }
            }
            Text(T("Free, two minutes. Get one at themoviedb.org/settings/api."))
                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                .foregroundStyle(BP.inkSubtle)
        }
        .onChange(of: key) { _, now in
            // Typing clears the last answer; the draft stops at 64 characters.
            if now.count > Self.maxLength { key = String(now.prefix(Self.maxLength)) }
            if check != "checking" { check = "idle" }
            saveError = nil
        }
    }

    private var noteText: String {
        if check == "rejected" { return T("TMDB did not accept that key. Check you copied the v3 key, not the read access token.") }
        if check == "unreachable" { return T("Could not reach TMDB from this phone. You can save the key without checking it.") }
        let n: Int = key.count
        if n > Self.keyLength { return T("%lld characters", n) }
        if n > 0 { return T("%lld of %lld characters", n, Self.keyLength) }
        return T("Skip this and Harbor runs on Cinemeta. You just see fewer rows.")
    }

    private func verify() async {
        let candidate: String = draft
        guard !candidate.isEmpty, !busy else { return }
        check = "checking"
        saveError = nil
        let raw: String? = try? await HarborEngine.shared.call("onboarding.checkTmdbKey", [candidate])
        let answer: String = raw ?? "unreachable"
        // Typed on while TMDB answered: that answer is for another key.
        guard candidate == draft else { check = "idle"; return }
        if answer == "ok" {
            check = "idle"
            await save()
        } else {
            check = answer == "rejected" ? "rejected" : "unreachable"
        }
    }

    private func save() async {
        let value: String = draft
        guard !value.isEmpty else { return }
        do {
            try await settings.patch(["tmdbKey": .string(value)])
            check = "idle"
            PhoneFeedback.shared.success()
            done()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Sign in to Stremio (email and password, straight to api.strem.io). A sign-in made before any
/// profile exists is parked (PendingStremio) for the first profile.
struct PhoneStremioForm: View {
    let signedInName: String?
    let done: (String) -> Void
    let skip: () -> Void
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let signedInName {
                Label(T("Signed in as %@", signedInName), systemImage: "checkmark.circle.fill")
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(BP.ink)
                Button(T("Continue")) { done(signedInName) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("stremio-continue")
            } else {
                TextField(T("Email"), text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                    .padding(14)
                    .phoneGlassPlate(radius: PhoneTheme.radiusSmall)
                    .accessibilityIdentifier("stremio-email")
                SecureField(T("Password"), text: $password)
                    .textContentType(.password)
                    .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                    .padding(14)
                    .phoneGlassPlate(radius: PhoneTheme.radiusSmall)
                    .accessibilityIdentifier("stremio-password")
                if let failure {
                    Text(verbatim: failure).font(PhoneTheme.sans(14, .regular, relativeTo: .footnote)).foregroundStyle(BP.danger)
                }
                HStack(spacing: 12) {
                    Button(busy ? T("Signing in…") : T("Sign in")) { Task { await signIn() } }
                        .buttonStyle(.glassProminent)
                        .disabled(busy || email.isEmpty || password.isEmpty)
                        .accessibilityIdentifier("stremio-sign-in")
                    Button(T("Skip for now"), action: skip)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("stremio-skip")
                }
            }
        }
    }

    private func signIn() async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let result = try await StremioAPI.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            let session = ProfilesStore.StremioSession(authKey: result.authKey, user: result.user)
            if let target = profiles.active ?? profiles.profiles.first {
                profiles.setStremioSession(session, for: target.id)
            } else {
                PendingStremio.session = session
            }
            PhoneFeedback.shared.success()
            done(result.user.fullname ?? result.user.email)
        } catch {
            failure = error.localizedDescription
            PhoneFeedback.shared.failure()
        }
    }
}
