import SwiftUI

/// The root flow: splash while the engine boots, first-run setup, Who's
/// watching, then the shell (the iOS 26 tab bar, or the kids shell for a kid profile). The curfew
/// cover sits above all of it. Same rebuild rule as the TV's RootView: a theme or language change
/// re-renders the whole tree, and playback or an open sheet holds it until they have closed.
struct PhoneRootView: View {
    @StateObject private var app = AppModel()
    /// The phone has no intro wall, but AppModel.shellReachable waits for
    /// `IntroModel.wallShowing` to be false; creating a disabled instance is what clears it.
    @StateObject private var intro = IntroModel(enabled: false)
    @ObservedObject private var theme = ThemeStore.shared
    /// The active profile decides which shell a `.shell` stage shows (kid → Kids).
    @ObservedObject private var profiles = ProfilesStore.shared
    /// settings.uiLanguage drives every string on screen (App/Shared/App/L10n.swift), not the system language.
    @ObservedObject private var settings = SettingsBridge.shared
    @ObservedObject private var curfew = CurfewState.shared
    /// A film is up: a theme or language that profile sync pulls in meanwhile waits for it to end.
    @ObservedObject private var playback = PlaybackState.shared
    /// A sheet is up over the shell: held the same way (a rebuild would drop it).
    @ObservedObject private var presence = PhonePresence.shared
    /// The language the tree was built in, kept while playback or an open sheet holds it (nil = follow settings).
    @State private var heldLanguage: String?
    /// The theme revision the tree was built in, kept while a sheet is up (nil = follow ThemeStore).
    /// The sheet holds the tree, not ThemeStore: a theme picked in Settings → Appearance repaints
    /// that panel at once and the rest of the app when the sheet closes.
    @State private var heldRevision: Int?
    /// `--phone-curfew`: the cover is up as if the allowance were spent (see PhoneLaunch).
    @State private var curfewPreview = PhoneLaunch.curfewPreview

    private var language: String { heldLanguage ?? L10n.normalize(settings.slice.uiLanguage) }

    var body: some View {
        ZStack {
            PhoneBackground()
            Group {
                switch app.stage {
                case .boot: PhoneSplashView()
                case .onboarding: PhoneOnboardingView()
                case .whoIsWatching: PhoneWhoView()
                case .shell:
                    if profiles.active?.kid != nil { PhoneKidsShell() } else { PhoneShellView() }
                }
            }
            // The player for a pick made from the shell: over it, under the curfew lock.
            if app.stage == .shell {
                PhonePlayerOverlay().zIndex(10)
            }
            if app.stage == .shell, curfew.locked || curfewPreview {
                CurfewCoverView(previewDismiss: { curfewPreview = false })
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .motion(.easeInOut(duration: 0.25), value: app.stage)
        // A theme change re-renders every view against the new BP tokens; a language change does the
        // same, so T() copy and engine-built rows are read again in it.
        .id("\(heldRevision ?? theme.revision)|\(language)")
        .environment(\.locale, Locale(identifier: language))
        .environment(\.layoutDirection, L10n.rtlLanguages.contains(language) ? .rightToLeft : .leftToRight)
        .toastHost()
        .onAppear {
            Platform.hooks = PhoneHooks()
            Platform.feedback = PhoneFeedback.shared
        }
        .onChange(of: app.stage) { _, stage in
            if stage == .shell { curfew.start() }
            // Setup holds the theme: repainting rebuilds the tree and would restart it at the first step.
            theme.holding = stage == .onboarding
        }
        .onChange(of: playback.active) { _, _ in syncHold() }
        .onChange(of: presence.coverUp) { _, _ in syncHold() }
        .environmentObject(app)
        .environmentObject(app.profiles)
        .environmentObject(SettingsBridge.shared)
        .task {
            guard !PhoneLaunch.hostsUnitTests else { return }
            await app.boot()
            if let url = PhoneLaunch.openURL { app.handle(url: url) }
        }
        // Links wait in DeepLinkQueue until the shell on screen is clear (AppModel.handle).
        // An external player coming back (x-success / x-error) is not a deep link.
        .onOpenURL { url in
            if !PhoneExternalPlay.shared.handleCallback(url) { app.handle(url: url) }
        }
        .preferredColorScheme(theme.state?.light == true ? .light : .dark)
    }

    /// Keeps the tree's theme and language steady through playback or an open sheet: either one
    /// holds `heldRevision` and `heldLanguage` until both have cleared, and playback also holds
    /// ThemeStore itself. Read afresh here (not from the value onChange hands over) so one clearing
    /// while the other still holds keeps the freeze.
    private func syncHold() {
        let held = playback.active || presence.coverUp
        heldLanguage = held ? (heldLanguage ?? language) : nil
        heldRevision = held ? (heldRevision ?? theme.revision) : nil
        theme.holdingForPlayback = playback.active
    }
}

/// The boot splash: the mark rising in over 1.2 s, then a spinner, while the engine starts.
struct PhoneSplashView: View {
    @State private var shown = false

    var body: some View {
        VStack(spacing: 24) {
            PhoneMark(size: 112)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || PhoneMotion.reduced ? 1 : 0.92)
            ProgressView().tint(BP.inkMuted).opacity(shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withMotion(.timingCurve(0.22, 1, 0.36, 1, duration: 1.2)) { shown = true } }
        .accessibilityIdentifier("boot-splash")
    }
}
