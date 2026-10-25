import SwiftUI

/// The shell: the iOS 26 tab bar over five places, chips for the rooms
/// that share a tab (Live, Library), the profile button's account sheet, and a Resume strip above the
/// tab bar. Settings → Tabs decides which rooms show and in what order; a tab with none leaves the
/// bar. Home is the one screen the viewer arranges (PhoneHomeView).
/// `AppModel.room` stays the source of truth for where the viewer is, as on the TV, so a profile
/// switch (which resets it to Home) and a deep link read the same state.
struct PhoneShellView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var profiles: ProfilesStore
    @EnvironmentObject private var settings: SettingsBridge
    /// Per-profile tab locks and hidden anime (Profiles/ParentalGate.swift).
    @ObservedObject private var parental = ParentalGate.shared
    /// Deep links waiting to be shown (AppModel.showWaitingLink).
    @ObservedObject private var links = DeepLinkQueue.shared
    @ObservedObject private var curfew = CurfewState.shared

    /// The room last open in each tab, so a tab comes back where it was left.
    @State private var lastRoom: [PhoneTab: Room] = [:]
    @State private var accountOpen = false
    /// What the Resume strip offers: the newest unfinished title.
    @State private var resuming: ContinueItem?
    /// The picture floating in Picture in Picture, if any (the accessory's live state).
    @ObservedObject private var mini = PhoneMiniState.shared
    /// The floating picture asking for the player back (PhonePlay.returns).
    @ObservedObject private var play = PhonePlay.shared

    /// The rooms this profile may see (hidden by Settings, the sports choice or a parental lock).
    private var visible: [Room] {
        Room.shellTabs(sportsDeclined: settings.sportsDeclined, gate: parental, nav: settings.navLayout)
    }

    /// A tab's rooms that show, in the profile's order (Settings → Tabs): its chips.
    private func visibleRooms(in tab: PhoneTab) -> [Room] {
        visible.filter { tab.rooms.contains($0) }
    }

    /// The bar (Settings → Tabs): Home first, then Discover, Live and Library
    /// in the order of their first room that shows, each only while one of its rooms does. Search
    /// sits apart, last.
    private var barTabs: [PhoneTab] {
        let shown = visible
        let placed: [(tab: PhoneTab, at: Int)] = [PhoneTab.discover, .live, .library].compactMap { tab in
            shown.firstIndex(where: { tab.rooms.contains($0) }).map { (tab, $0) }
        }
        return [.home] + placed.sorted { $0.at < $1.at }.map { $0.tab }
    }

    /// The room a tab shows now. Unvisited, a tab opens on its own default (the first of
    /// `PhoneTab.rooms` that shows), not its first chip: the TV's room order puts Calendar before
    /// Library, and the Library tab opens on Library.
    private func room(in tab: PhoneTab) -> Room? {
        let rooms = visibleRooms(in: tab)
        if PhoneTab.of(app.room) == tab, rooms.contains(app.room) { return app.room }
        if let last = lastRoom[tab], rooms.contains(last) { return last }
        return tab.rooms.first(where: rooms.contains)
    }

    private var tabSelection: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab.of(app.room) },
            set: { tab in
                guard tab != PhoneTab.of(app.room) else { return }
                PhoneFeedback.shared.selection()
                app.room = room(in: tab) ?? tab.rooms[0]
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(barTabs, id: \.self) { tab in
                Tab(T(tab.title), systemImage: tab.icon, value: tab) { screen(tab) }
            }
            Tab(value: PhoneTab.search, role: .search) { screen(.search) }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Settings → Appearance "Titles under posters" (bp-tile.tsx showTitle = !hidePosterTitles).
        .environment(\.phoneHidePosterTitles, settings.slice.hidePosterTitles == true)
        .modifier(ResumeAccessory(accessory: PhoneAccessory.choose(resume: resuming, mini: mini.live), action: accessoryTapped))
        .onAppear { ParentalGate.shared.attach() }
        .onChange(of: app.room) { _, room in lastRoom[PhoneTab.of(room)] = room }
        // A room the viewer can no longer see (hidden in Settings, locked for this profile) must not stay
        // open; when it was its tab's last, the tab has left the bar too.
        .onChange(of: visible) { _, rooms in
            if !rooms.contains(app.room) { app.room = rooms.first ?? .home }
        }
        .task(id: profiles.activeId) { await loadResuming() }
        .task(id: links.waiting) { await showWaitingLinks() }
        // The picture's window wants the player back: the player's overlay sits under any sheet, so they go.
        .onChange(of: play.returns) { _, _ in
            accountOpen = false
            app.deepLinkMeta = nil
            app.deepLinkInstall = nil
            play.pending = nil
        }
        // The curfew lock sits over everything; what is open under it goes, as on the TV.
        .onChange(of: curfew.locked) { _, locked in
            guard locked else { return }
            accountOpen = false
            app.deepLinkMeta = nil
            app.deepLinkInstall = nil
        }
        .sheet(isPresented: $accountOpen) {
            PhoneAccountSheet { accountOpen = false }
        }
        // Each deep-link page reports that it came on screen (PhoneDetailSheet/PhoneDeepLinkInstall):
        // one that never does is put back in the queue instead of blocking every later link.
        .sheet(item: $app.deepLinkMeta) { meta in
            PhoneDetailSheet(meta: meta) { app.deepLinkMeta = nil }
        }
        // Play / Resume and the episode rows of a title page pushed in a tab, and the player they open (PhonePlay).
        .phonePlayHost(inCover: false)
        .sheet(item: $app.deepLinkInstall) { link in
            PhoneDeepLinkInstall(url: link.url) { app.deepLinkInstall = nil }
        }
        // The fixture picker goes through PhonePlay like any Play, so its pick opens the player.
        .task {
            guard let meta = await PhonePickerFixture.open() else { return }
            PhonePlay.shared.pending = PhonePlay.Request(meta: meta, video: nil, inCover: false,
                                                         autoPlay: PhoneLaunch.pickerAuto, applyPreference: false)
        }
        .accessibilityIdentifier("shell")
    }

    // MARK: Screens

    /// One tab's navigation stack: chips for its rooms, then the room's screen. A title opened in the
    /// tab pushes its page onto the tab's stack (PhoneTabStack).
    private func screen(_ tab: PhoneTab) -> some View {
        let rooms = visibleRooms(in: tab)
        let current = room(in: tab)
        return PhoneTabStack { nav in
            VStack(spacing: 0) {
                if rooms.count > 1 {
                    ChipRow {
                        ForEach(rooms) { r in
                            GlassChip(title: T(r.label), systemImage: r.icon, selected: r == current) {
                                guard r != app.room else { return }
                                PhoneFeedback.shared.selection()
                                app.room = r
                            }
                        }
                    }
                    .accessibilityIdentifier("chips-\(tab.title)")
                }
                content(for: current, nav: nav)
            }
            .background(PhoneBackground())
            .navigationTitle(T(tab.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { accountButton }
            }
            // Home draws its own floating buttons over art that runs to the top edge (PhoneHomeView).
            .toolbar(showsHomeFeed(current) ? .hidden : .automatic, for: .navigationBar)
        }
    }

    /// Whether the room is Home's feed (Movies, Shows and Anime are rows on it).
    private func showsHomeFeed(_ room: Room?) -> Bool {
        guard let room else { return false }
        switch room {
        case .home, .movies, .shows, .anime: return true
        default: return false
        }
    }

    @ViewBuilder private func content(for room: Room?, nav: PhoneNavigator) -> some View {
        if let room {
            switch room {
            case .home, .movies, .shows, .anime:
                // Movies, Shows and Anime have no screen of their own: their rows are added to Home.
                PhoneHomeView(app: app, open: { nav.open($0) }, play: { nav.open($0, autoPlay: true) }, resume: resume,
                              openAccount: { accountOpen = true })
            case .search:
                PhoneSearchView(views: app.views, open: { nav.open($0, hint: $1) })
            case .discover:
                PhoneDiscoverView(open: { nav.open($0) })
            case .calendar:
                PhoneCalendarView(open: { nav.open($0) })
            case .library:
                PhoneLibraryView(views: app.views, open: { nav.open($0) })
            case .collections:
                PhoneCollectionsView(views: app.views)
            default:
                PhoneSoonView(room: room)
            }
        } else {
            // Every room of this tab is hidden: the tab leaves the bar (barTabs); this shows only for the
            // moment before the selection moves off it.
            ScrollView {
                EmptyState(title: T("Hidden for this profile"),
                           message: T("A grown-up has turned this part of Harbor off."),
                           systemImage: "lock.fill")
                    .padding(.top, 60)
            }
        }
    }

    private var accountButton: some View {
        Button {
            PhoneFeedback.shared.tap()
            accountOpen = true
        } label: {
            if let profile = profiles.active {
                ProfileFace(name: profile.name, colorHex: profile.color, avatar: profile.avatar, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel(Text(verbatim: profiles.active?.name ?? T("Account")))
        .accessibilityIdentifier("account-button")
    }

    // MARK: Resume

    private func loadResuming() async {
        let items: [ContinueItem] = Fixtures.active && PhoneLaunch.noResume ? [] : (try? await app.browseSource.continueWatching(for: .home)) ?? []
        guard !Task.isCancelled else { return }
        resuming = items.first(where: { !$0.watched }) ?? items.first
    }

    /// The accessory's tap: bring the floating picture back while one floats, else resume the title.
    private func accessoryTapped() {
        if mini.live != nil { mini.bringBack?() } else { resumeTapped() }
    }

    /// The Resume strip: the title opens through the deep-link queue, so it waits for a clear shell like any link.
    private func resumeTapped() {
        guard let resuming else { return }
        resume(resuming)
    }

    /// The Resume strip and the Continue Watching rail (bp-cw-row bpCwResume): a card that names what
    /// it would play opens its title playing at once, from the saved spot; any other opens the title.
    private func resume(_ item: ContinueItem) {
        PhoneFeedback.shared.tap()
        switch item.press {
        case .detail: break
        case .resumeMovie: PhonePlay.shared.resumeTitle(id: item.id, hint: nil)
        case .resumeEpisode(let season, let episode):
            PhonePlay.shared.resumeTitle(id: item.id, hint: PhoneEpisodeHint(season: season, episode: episode))
        }
        DeepLinkQueue.shared.add(.title(type: item.type, id: item.id))
    }

    // MARK: Deep links

    /// Polls while a link waits or the one just shown has not come up (covers are not observable).
    private func showWaitingLinks() async {
        while !Task.isCancelled, app.hasWaitingLink(kidShell: false) {
            _ = app.showWaitingLink(kidShell: false, clear: linkClear)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Nothing is presented over the shell, and no film is playing (one floating in Picture in Picture
    /// leaves the shell free: that is browsing while it plays).
    private var linkClear: Bool {
        AppModel.shellReachable && (!PlaybackState.shared.active || mini.live != nil) && !PhonePresence.shared.coverUp
    }
}

/// The strip above the tab bar: Resume for the newest unfinished title, or the live state while a
/// picture floats in Picture in Picture (PhoneAccessory.choose). `tabViewBottomAccessory(isEnabled:content:)`
/// arrived in iOS 26.1; on 26.0 there is no strip and the Continue Watching rail on Home carries the title.
private struct ResumeAccessory: ViewModifier {
    let accessory: PhoneAccessory?
    let action: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: accessory != nil) {
                if let accessory {
                    Button(action: action) {
                        HStack(spacing: 10) {
                            Image(systemName: icon(accessory)).accessibilityHidden(true)
                            Text(verbatim: text(accessory))
                                .font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote))
                                .lines(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier(accessory))
                }
            }
        } else {
            content
        }
    }

    private func icon(_ a: PhoneAccessory) -> String {
        switch a {
        case .mini: return "pip"
        case .resume: return "play.fill"
        }
    }

    private func text(_ a: PhoneAccessory) -> String {
        switch a {
        case .mini(let t), .resume(let t): return t
        }
    }

    private func identifier(_ a: PhoneAccessory) -> String {
        switch a {
        case .mini: return "mini-accessory"
        case .resume: return "resume-accessory"
        }
    }
}
