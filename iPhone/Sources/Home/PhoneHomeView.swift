import SwiftUI

/// Home's layout mode just picked ("harbor" or "classic"), until the settings slice answers (and under
/// fixtures, where it never does). The loader's Auto hero reads it through `PhoneHomeView.dependencies`.
@MainActor
final class PhoneHomeMode: ObservableObject {
    static let shared = PhoneHomeMode()
    @Published var override: String?

    var current: String { override ?? SettingsBridge.shared.slice.homeMode }
}

/// The Home tab, the one screen the viewer arranges: the active profile's
/// HomeLayout (Home/HomeLayout.swift) says what shows, top to bottom. By default that is the hero,
/// Continue Watching and every row the Home page builds; rows from Movies, Shows, Anime, AniList,
/// MyAnimeList and the addons' catalogs are added from "Edit Home" (PhoneHomeEditor). Rows draw as the
/// room feed always drew them: Top 10 cells, the service / addon / collection bands, posters and wide tiles.
struct PhoneHomeView: View {
    let open: (Meta) -> Void
    /// The hero's Play: the title page, playing at once.
    let play: (Meta) -> Void
    let resume: (ContinueItem) -> Void
    /// The profile button: opens the account sheet.
    let openAccount: () -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: SettingsBridge
    @EnvironmentObject private var profiles: ProfilesStore
    @ObservedObject private var parental = ParentalGate.shared
    @ObservedObject private var titleActions = PhoneTitleActions.shared
    @ObservedObject private var mode = PhoneHomeMode.shared
    @StateObject private var loader: HomeLayoutLoader

    /// The tab's stack: a row header or a band tile pushes its page there.
    @EnvironmentObject private var nav: PhoneNavigator
    @State private var editing = false
    /// The profile the loader last loaded for: coming back to the tab refreshes in place.
    @State private var loadedProfile: String?
    /// The status bar's height and the screen's, for the hero that runs under the bar (PhoneScreen).
    @State private var topInset: CGFloat = PhoneScreen.topInset
    @State private var screenHeight: CGFloat = PhoneScreen.height
    /// How far the feed is pulled down past its top (the hero grows to fill it), and whether it has
    /// scrolled off the hero (the status bar then gets a scrim of its own).
    @State private var overscroll: CGFloat = 0
    @State private var pastHero = false
    /// What the scroll view puts above its content (the status bar's height unless the screen's top edge is
    /// ignored, as below: then 0). Read, not assumed, so the hero lands on the top of the screen either way.
    @State private var scrollInset: CGFloat = 0
    /// `scrollInset` is read once, at rest: a refresh holds the content down with an inset of its own.
    @State private var insetMeasured = false
    @State private var refreshing = false

    init(app: AppModel, open: @escaping (Meta) -> Void, play: @escaping (Meta) -> Void, resume: @escaping (ContinueItem) -> Void,
         openAccount: @escaping () -> Void) {
        self.open = open
        self.openAccount = openAccount
        self.play = play
        self.resume = resume
        _loader = StateObject(wrappedValue: HomeLayoutLoader(Self.dependencies(app: app)))
    }

    @MainActor static func dependencies(app: AppModel) -> HomeLayoutLoader.Dependencies {
        var deps = HomeLayoutLoader.Dependencies.live(app: app)
        deps.classicHome = { PhoneHomeMode.shared.current == "classic" }
        return deps
    }

    /// Home's layout mode: "harbor" or "classic" (settings.homeMode). Classic leads with Continue Watching
    /// and the addon catalogs and has no automatic hero, as the engine builds it.
    private var homeMode: String { mode.override ?? settings.slice.homeMode }

    private var heroHeight: CGFloat { PhoneHero.height(forScreen: screenHeight) }

    var body: some View {
        ZStack(alignment: .top) {
            feed
            topScrim
            topButtons
        }
        // The feed starts at the screen's top edge, under the status bar and the Dynamic Island.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: profiles.activeId) { await start() }
        // A pass read Continue Watching afresh: the cards removed from it are gone from the source too.
        .onChange(of: loader.passes) { _, _ in titleActions.resetDismissed() }
        .onChange(of: settings.slice.homeMode) { _, saved in
            if mode.override == saved { mode.override = nil }
            loader.reassemble()
        }
        .sheet(isPresented: $editing, onDismiss: { loader.endAllSources() }) {
            PhoneHomeEditor(loader: loader) { editing = false }
        }
    }

    /// Whether the feed opens with the hero: its art then starts at the very top of the screen. The
    /// loading skeleton stands in for it.
    private var feedHasHero: Bool {
        switch loader.phase {
        case .loading: return true
        case .failed: return false
        case .loaded(let content): return !content.hero.isEmpty
        }
    }

    private var feed: some View {
        let threshold: CGFloat = heroHeight * 0.6
        let inset: CGFloat = scrollInset
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch loader.phase {
                case .loading:
                    skeleton
                case .failed(let message):
                    ErrorPlate(title: T("Couldn't load this"), message: message) {
                        Task { await loader.load(quiet: false) }
                    }
                    .padding(.top, 24)
                    footer
                case .loaded(let content):
                    if content.isEmpty {
                        EmptyState(title: T("Nothing here yet"),
                                   message: loader.layout.isDefault
                                       ? T("Add an addon or connect TMDB and this fills in.")
                                       : T("Nothing on your Home has titles right now. Add a row, or reset Home to the standard rows."),
                                   systemImage: "house.fill",
                                   actionTitle: T("Edit Home"),
                                   action: openEditor)
                            .padding(.top, 24)
                    } else {
                        loadedContent(content)
                    }
                    footer
                }
            }
            // The content starts `scrollInset` down. With a hero, lift it by that much so its art starts at
            // the screen's top edge; without one, start it below the status bar and the buttons that float
            // over the top.
            .padding(.top, feedHasHero ? -scrollInset : topInset + Self.buttonsRoom - scrollInset)
            .padding(.bottom, 24)
        }
        .refreshable {
            refreshing = true
            await loader.load(quiet: true)
            refreshing = false
        }
        // Only changes of these values re-draw the feed, not every frame of a scroll.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, (-(geometry.contentOffset.y + inset)).rounded())
        } action: { _, pulled in
            overscroll = pulled
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + inset > threshold
        } action: { _, past in
            withMotion(.easeOut(duration: 0.2)) { pastHero = past }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentInsets.top.rounded()
        } action: { _, top in
            guard !insetMeasured, !refreshing else { return }
            insetMeasured = true
            scrollInset = top
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            topInset = PhoneScreen.topInset
            screenHeight = PhoneScreen.height
        }
        .accessibilityIdentifier("feed-home")
    }

    /// Below the hero the status bar sits over rows: a canvas scrim keeps the clock readable.
    private var topScrim: some View {
        LinearGradient(colors: [BP.canvas.opacity(0.92), BP.canvas.opacity(0.7), BP.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: topInset + 28)
            .opacity(pastHero ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// Filter (Edit Home) top left and the profile top right, glass circles floating over the art.
    private var topButtons: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                Button(action: openEditor) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BP.ink)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(Color.black.opacity(0.2)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: T("Edit Home")))
                .accessibilityIdentifier("home-edit")
                Spacer(minLength: 0)
                Button {
                    PhoneFeedback.shared.tap()
                    openAccount()
                } label: {
                    Group {
                        if let profile = profiles.active {
                            ProfileFace(name: profile.name, colorHex: profile.color, avatar: profile.avatar, size: 32)
                        } else {
                            Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(BP.ink)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(Color.black.opacity(0.2)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: profiles.active?.name ?? T("Account")))
                .accessibilityIdentifier("account-button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topInset + 6)
    }

    /// The buttons' height plus their gaps: the room a feed without a hero leaves under the status bar.
    private static let buttonsRoom: CGFloat = 60

    /// The first appearance loads; a profile switch moves the loader to that profile's layout; coming
    /// back to the tab (or from a pushed page) refreshes what is on screen without the skeleton.
    private func start() async {
        let deps = Self.dependencies(app: app)
        if loadedProfile == deps.profileId {
            await loader.load(quiet: true)
            return
        }
        loadedProfile = deps.profileId
        if loader.profileId == deps.profileId && loader.passes == 0 {
            await loader.load(quiet: false)
        } else {
            await loader.use(deps)
        }
    }

    private func openEditor() {
        PhoneFeedback.shared.tap()
        editing = true
    }

    // MARK: Content

    @ViewBuilder private func loadedContent(_ content: HomeContent) -> some View {
        let lead: [Meta] = PhoneHomeDemo.heroArt(content.hero.uniquedById())
        if !lead.isEmpty {
            PhoneHero(items: lead, kickers: Self.kickers(for: lead, in: content), height: heroHeight, stretch: overscroll,
                      open: open, play: play)
                // A new hero source starts the pager over at its first title.
                .id(lead.map(\.id).joined(separator: "|"))
        }
        ForEach(content.items) { item in
            switch item.kind {
            case .resuming(let list):
                resumingRail(item, list: list)
            case .row(let row):
                rowRail(item, row: row)
            }
        }
    }

    /// "#1 in Top 10 Today": a hero title that sits in a numbered row of Home says where. Nothing for a
    /// title that ranks nowhere.
    @MainActor static func kickers(for lead: [Meta], in content: HomeContent) -> [String: String] {
        var out: [String: String] = [:]
        for row in content.rows where row.shape == .rank {
            for (index, meta) in row.metas.enumerated() where index < 10 && out[meta.id] == nil && lead.contains(where: { $0.id == meta.id }) {
                out[meta.id] = T("#%lld in %@", index + 1, row.title)
            }
        }
        return PhoneHomeDemo.kickers(out, lead: lead)
    }

    @ViewBuilder private func resumingRail(_ item: HomeContent.Item, list: [ContinueItem]) -> some View {
        let visible: [ContinueItem] = list.filter { !titleActions.dismissed.contains($0.id) }
        if !visible.isEmpty {
            Rail(item.title) {
                ForEach(visible) { entry in
                    BackdropTile(title: entry.name,
                                 subtitle: PhoneResume.subtitle(entry),
                                 imageURL: entry.background ?? entry.poster,
                                 progress: entry.progress,
                                 identifier: "resume-\(entry.id)") { resume(entry) }
                        .phoneContextMenu(for: Meta(continue: entry), fromContinueWatching: true, open: open)
                }
            }
        }
    }

    /// The loader already de-duplicated the row, cut it to its limit and picked its tile shape.
    @ViewBuilder private func rowRail(_ item: HomeContent.Item, row: BrowseRow) -> some View {
        let lead: (title: String, run: () -> Void)? = rowLead(item, row: row)
        Rail(item.title, seeAllTitle: lead?.title, seeAll: lead?.run) {
            ForEach(Array(row.metas.enumerated()), id: \.element.id) { index, meta in
                tile(meta, shape: row.shape, rank: index + 1)
            }
        }
    }

    @ViewBuilder private func tile(_ meta: Meta, shape: TileShape, rank: Int) -> some View {
        switch shape {
        case .rank:
            RankTile(meta: meta, rank: rank) { open(meta) }
                .phoneContextMenu(for: meta, open: open, play: play)
        case .wide:
            BackdropTile(title: meta.name, imageURL: meta.background ?? meta.poster,
                         identifier: "tile-\(meta.id)") { open(meta) }
                .phoneContextMenu(for: meta, open: open, play: play)
        case .brand:
            BrandTile(meta: meta) { pick(meta) }
        case .collection:
            CollectionTile(meta: meta) { pick(meta) }
        case .poster:
            PosterTile(meta: meta) { pick(meta) }
                .phoneContextMenu(for: meta, open: open, play: play)
        }
    }

    /// A band tile goes to its page; a title to the title page.
    private func pick(_ meta: Meta) {
        if let destination = PhoneRoute(band: meta) {
            PhoneFeedback.shared.tap()
            nav.push(destination)
        } else {
            open(meta)
        }
    }

    /// The row header's button, as the TV's row leads read: Collections goes to the Collections room
    /// ("View all"); services and addons have none here yet (the TV's "Manage" opens Settings, which
    /// the phone keeps in the account sheet); an engine row says "See all" and opens its catalog page;
    /// an addon catalog opens that addon's page. The tracker lists page through no catalog, so have none.
    private func rowLead(_ item: HomeContent.Item, row: BrowseRow) -> (title: String, run: () -> Void)? {
        switch item.source {
        case .engineRow(let room, let key):
            switch key {
            case "addons", "services":
                return nil
            case "collections":
                guard !parental.hides(Room.collections) else { return nil }
                return (T("View all"), { app.room = .collections })
            default:
                let target = PhoneCatalogTarget(room: room.room, key: key, title: item.title, metas: row.metas)
                return (T("See all"), {
                    PhoneFeedback.shared.tap()
                    nav.push(PhoneRoute.catalog(target))
                })
            }
        case .addonCatalog(let base, _):
            guard let addon = loader.snapshot.addons.first(where: { $0.base == base }) else { return nil }
            return (T("See all"), {
                PhoneFeedback.shared.tap()
                nav.push(PhoneRoute.addon(base: addon.base, name: addon.name, logo: nil))
            })
        default:
            return nil
        }
    }

    // MARK: Footer

    /// "Edit Home", then Harbor or Classic: the same choice the first-run layout step offers, kept on
    /// Home where it shows.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: openEditor) {
                Label(T("Edit Home"), systemImage: "slider.horizontal.3")
                    .font(PhoneTheme.sans(16, .semibold, relativeTo: .callout))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("home-edit-footer")

            VStack(alignment: .leading, spacing: 8) {
                Text(T("Home layout"))
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                Picker(T("Home layout"), selection: modeBinding) {
                    Text(T("Harbor")).tag("harbor")
                    Text(T("Classic")).tag("classic")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("home-layout")
                Text(T(homeMode == "classic"
                       ? "Continue Watching first, then your addon catalogs in install order."
                       : "A hero up top, then Top 10, Trending, In Theaters and your service rows."))
                    .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                    .foregroundStyle(BP.inkSubtle)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 8)
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { homeMode },
            set: { picked in
                guard picked != homeMode else { return }
                PhoneFeedback.shared.selection()
                mode.override = picked
                // The hero follows at once; the Home page the engine builds for the mode follows the read.
                loader.reassemble()
                Task {
                    try? await settings.patch(["homeMode": .string(picked)])
                    await loader.load(quiet: true)
                }
            }
        )
    }

    // MARK: Loading

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonBlock(height: heroHeight, radius: 0)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 160, height: 22)
                        .padding(.horizontal, PhoneTheme.margin)
                    HStack(spacing: PhoneTheme.railGap) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonBlock(width: PhoneTheme.posterWidth, height: PhoneTheme.posterWidth * 1.5)
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                }
            }
        }
        .accessibilityIdentifier("feed-loading")
    }
}

/// What `--phone-hero-demo` changes on Home's hero (PhoneLaunch.heroDemo): only under fixtures.
@MainActor
enum PhoneHomeDemo {
    /// The lead's first title with real-looking copy and public art (Cinemeta's image host).
    static func heroArt(_ lead: [Meta]) -> [Meta] {
        guard Fixtures.active, PhoneLaunch.heroDemo, var first = lead.first else { return lead }
        first.name = "Cyberpunk: Edgerunners"
        first.releaseInfo = "2022"
        first.imdbRating = "8.3"
        first.genres = ["Animation", "Sci-Fi"]
        let host = "https://images.metahub.space"
        let imdb = "tt" + "12590266"
        first.background = "\(host)/background/large/\(imdb)/img"
        first.logo = "\(host)/logo/large/\(imdb)/img"
        return [first] + lead.dropFirst()
    }

    /// The first title ranks first somewhere.
    static func kickers(_ real: [String: String], lead: [Meta]) -> [String: String] {
        guard Fixtures.active, PhoneLaunch.heroDemo, let first = lead.first else { return real }
        var out = real
        out[first.id] = "#1 in Shows Today"
        return out
    }
}
