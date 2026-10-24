import SwiftUI
import SafariServices

/// The account sheet's pages that push (the addon pages push again inside them).
enum PhoneAccountRoute: Hashable {
    case addons
}

/// An addon's own page, pushed from the Addons screen or from another addon's page.
enum PhoneAddonRoute: Hashable {
    case detail(id: String)
}

/// What the Addons screens put up over themselves.
enum PhoneAddonsSheet: Identifiable {
    /// Add from URL, a setup page (configure / manage), or a scan straight away.
    case install(AddonsModel.ConfigureTarget, scan: Bool)
    case reorder
    case ageGate

    var id: String {
        switch self {
        case .install(let target, _): return "install-\(target.id)"
        case .reorder: return "reorder"
        case .ageGate: return "age-gate"
        }
    }
}

/// the design Addons (views/addons.tsx on the TV), reached from the account sheet:
/// Installed (swipe to remove or turn off, Reorder), Discover (spotlight, the community rail,
/// categories) and Browse (stremio-addons.net by category and mode, search). The shared
/// AddonsModel does the work, so an install, a removal or a new order reaches the Stremio account
/// exactly as it does from the TV.
struct PhoneAddonsView: View {
    @StateObject private var model: AddonsModel
    @ObservedObject private var settings = SettingsBridge.shared
    @EnvironmentObject private var nav: PhoneNavigator
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sheet: PhoneAddonsSheet?

    init() {
        _model = StateObject(wrappedValue: Self.makeModel())
    }

    private static func makeModel() -> AddonsModel {
        PhoneAddonsFixtures.installIfNeeded()
        let model = AddonsModel()
        // The phone opens on what is installed: that is what the account sheet's Addons is for.
        model.tab = .installed
        return model
    }

    var body: some View {
        content
            .background(PhoneBackground())
            .safeAreaInset(edge: .top, spacing: 0) { tabPicker }
            .navigationTitle(T("Addons"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: Text(T("Search addons")))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { addMenu }
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .navigationDestination(for: PhoneAddonRoute.self) { route in
                switch route {
                case .detail(let id): PhoneAddonDetailPage(addonId: id, model: model)
                }
            }
            .sheet(item: $sheet) { sheetView($0) }
            .task { await model.start() }
            // addons.tsx debounces the search box before it reads.
            .task(id: model.query) {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await model.queryChanged()
            }
            .phoneAddonToasts(model)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addons-screen")
    }

    // MARK: chrome

    private var tabPicker: some View {
        Picker(T("Addons"), selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            Text(T("Installed")).tag(AddonsModel.Tab.installed)
            Text(T("Discover")).tag(AddonsModel.Tab.discover)
            Text(T("Browse")).tag(AddonsModel.Tab.browse)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.vertical, 8)
        .accessibilityIdentifier("addons-tabs")
    }

    private var addMenu: some View {
        Menu {
            Button { sheet = .install(Self.urlTarget, scan: false) } label: { Label(T("Add from URL"), systemImage: "link") }
                .accessibilityIdentifier("addons-add-url")
            Button { sheet = .install(Self.urlTarget, scan: true) } label: { Label(T("Scan QR code"), systemImage: "qrcode.viewfinder") }
                .accessibilityIdentifier("addons-scan")
        } label: {
            Label(T("Add addon"), systemImage: "plus")
        }
        .accessibilityIdentifier("addons-add")
    }

    private var moreMenu: some View {
        Menu {
            Button { sheet = .reorder } label: { Label(T("Reorder"), systemImage: "arrow.up.arrow.down") }
                .disabled(model.installed.count < 2)
            // addons.tsx Adult chip: on only after the age check, off at once.
            Toggle(isOn: Binding(get: { settings.slice.showAdultAddons ?? false }, set: { on in
                if on { sheet = .ageGate } else { Task { await model.setAdult(false) } }
            })) {
                Label(T("Adult addons"), systemImage: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("addons-adult")
        } label: {
            Label(T("More"), systemImage: "ellipsis")
        }
        .accessibilityIdentifier("addons-more")
    }

    static var urlTarget: AddonsModel.ConfigureTarget {
        AddonsModel.ConfigureTarget(mode: .url, name: T("Addon"), logo: nil, configureUrl: nil, manageId: nil)
    }

    @ViewBuilder private func sheetView(_ which: PhoneAddonsSheet) -> some View {
        switch which {
        case .install(let target, let scan):
            PhoneAddonInstallSheet(target: target, model: model, startScan: scan) { sheet = nil }
        case .reorder:
            PhoneAddonReorderSheet(model: model) { sheet = nil }
        case .ageGate:
            PhoneAgeGate(onPass: { Task { await model.setAdult(true) } }) { sheet = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .installed: installedList
        case .discover: discoverPane
        case .browse: browsePane
        }
    }

    // MARK: Installed (installed-pane.tsx)

    private var installedList: some View {
        List {
            Section {
                if !model.catalogLoaded && model.installed.isEmpty {
                    ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if model.filteredInstalled.isEmpty {
                    Text(verbatim: model.query.isEmpty ? T("No addons installed yet. Add one from a link or find one in Discover.")
                                                       : T("No installed addon matches your search."))
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                        .accessibilityIdentifier("addons-installed-empty")
                } else {
                    ForEach(model.filteredInstalled) { card in installedRow(card) }
                }
            } header: {
                HStack {
                    Text(verbatim: T("%lld installed", model.installedCount))
                    Spacer()
                    Button { sheet = .reorder } label: { Label(T("Reorder"), systemImage: "arrow.up.arrow.down") }
                        .font(PhoneTheme.sans(14, .semibold, relativeTo: .footnote))
                        .disabled(model.installed.count < 2)
                        .accessibilityIdentifier("addons-reorder")
                }
                .textCase(nil)
            } footer: {
                Text(verbatim: T("Swipe left to remove an addon, right to turn it off. Harbor asks addons for streams in this order."))
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadCatalog(fresh: true) }
        .accessibilityIdentifier("addons-installed")
    }

    private func installedRow(_ card: AddonsModel.Card) -> some View {
        Button { open(card) } label: {
            HStack(spacing: 12) {
                PhoneAddonLogo(url: card.logo, name: card.name, side: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: card.name)
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                        .lines(1)
                    Text(verbatim: card.description.isEmpty ? card.subtitle : card.description)
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(BP.inkMuted)
                        .lines(2)
                }
                Spacer(minLength: 8)
                if model.busy.contains(card.key) {
                    ProgressView().tint(BP.inkMuted)
                } else if !card.enabled {
                    Text(T("Off"))
                        .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                        .foregroundStyle(BP.inkMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(BP.ink.opacity(0.08)))
                }
            }
            .opacity(card.enabled ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear.background(.ultraThinMaterial))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { remove(card) } label: { Label(T("Remove"), systemImage: "trash") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { toggle(card) } label: {
                Label(card.enabled ? T("Turn off") : T("Turn on"), systemImage: card.enabled ? "poweroff" : "power")
            }
            .tint(card.enabled ? .gray : BP.accent)
        }
        .contextMenu {
            Button { open(card) } label: { Label(T("Open"), systemImage: "info.circle") }
            if card.configurable && !card.configureUrl.isEmpty {
                Button { sheet = .install(manageTarget(card), scan: false) } label: { Label(T("Reconfigure"), systemImage: "slider.horizontal.3") }
            }
            Button { toggle(card) } label: {
                Label(card.enabled ? T("Turn off") : T("Turn on"), systemImage: card.enabled ? "poweroff" : "power")
            }
            Button(role: .destructive) { remove(card) } label: { Label(T("Remove"), systemImage: "trash") }
        }
        .accessibilityIdentifier("addon-row-\(card.name)")
    }

    private func manageTarget(_ card: AddonsModel.Card) -> AddonsModel.ConfigureTarget {
        AddonsModel.ConfigureTarget(mode: .manage, name: card.name, logo: card.logo, configureUrl: card.configureUrl, manageId: card.addonId)
    }

    private func open(_ card: AddonsModel.Card) {
        nav.push(PhoneAddonRoute.detail(id: card.addonId))
    }

    private func remove(_ card: AddonsModel.Card) {
        Task { await model.uninstall(card) }
    }

    private func toggle(_ card: AddonsModel.Card) {
        PhoneFeedback.shared.selection()
        Task { await model.setEnabled(card, !card.enabled) }
    }

    private func install(_ card: AddonsModel.Card) {
        Task {
            if let setup = await model.install(card) { sheet = .install(setup, scan: false) }
        }
    }

    // MARK: Discover (discover-pane.tsx)

    private var discoverPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                spotlight
                rail
                categoryGrid
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.loadDiscover() }
        .accessibilityIdentifier("addons-discover")
    }

    @ViewBuilder private var spotlight: some View {
        if let s = model.spotlight {
            let c = s.addon
            Button { open(c) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Label(s.trending ? T("Trending on %@", "stremio-addons.net") : T("Top rated on %@", "stremio-addons.net"),
                          systemImage: "chart.line.uptrend.xyaxis")
                        .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                    HStack(spacing: 14) {
                        PhoneAddonLogo(url: c.logo, name: c.name, side: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: c.name)
                                .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                                .foregroundStyle(BP.ink)
                                .lines(2)
                            if c.stars > 0 {
                                Label(clampedInt(c.stars).formatted(), systemImage: "star.fill")
                                    .font(PhoneTheme.sans(13, .bold, relativeTo: .footnote))
                                    .foregroundStyle(BP.accent)
                            }
                        }
                    }
                    Text(verbatim: c.description)
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                        .lines(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .phoneGlassPlate(radius: PhoneTheme.radiusLarge)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .overlay(alignment: .topTrailing) { installButton(c).padding(14) }
            .padding(.horizontal, PhoneTheme.margin)
            .accessibilityIdentifier("addons-spotlight")
        } else if model.spotlightFailed {
            ErrorPlate(title: T("Couldn't reach stremio-addons.net"), retry: { Task { await model.loadDiscover() } })
        } else {
            SkeletonBlock(width: nil, height: 180, radius: PhoneTheme.radiusLarge).padding(.horizontal, PhoneTheme.margin)
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Community picks"))
            ChipRow {
                ForEach(AddonsModel.RailMode.allCases, id: \.self) { m in
                    GlassChip(title: T(Self.railLabel(m)), selected: model.railMode == m) {
                        Task { await model.setRailMode(m) }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PhoneTheme.railGap) {
                    if let cards = model.rail {
                        if cards.isEmpty {
                            Text(T("Nothing new to add here right now."))
                                .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                                .foregroundStyle(BP.inkMuted)
                        }
                        ForEach(cards) { c in railCard(c) }
                    } else {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBlock(width: 260, height: 132, radius: PhoneTheme.radiusMedium) }
                    }
                }
                .padding(.horizontal, PhoneTheme.margin)
            }
        }
    }

    private func railCard(_ c: AddonsModel.Card) -> some View {
        Button { open(c) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    PhoneAddonLogo(url: c.logo, name: c.name, side: 40)
                    Text(verbatim: c.name)
                        .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                        .foregroundStyle(BP.ink)
                        .lines(1)
                }
                Text(verbatim: c.description)
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .lines(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 260, height: 132, alignment: .topLeading)
            .phoneGlassPlate()
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier("addon-card-\(c.name)")
    }

    private static func railLabel(_ m: AddonsModel.RailMode) -> String {
        switch m {
        case .trending: return "Trending"
        case .stars: return "Top rated"
        case .createdAt: return "Just added"
        }
    }

    private struct CategoryTile: Identifiable {
        var cat: String; var title: String; var blurb: String; var colors: [Color]; var icon: String
        var id: String { cat }
    }

    /// category-grid.tsx, as the TV draws it.
    private static let categoryTiles: [CategoryTile] = [
        CategoryTile(cat: "http+streams", title: "Streaming", blurb: "Where your video comes from", colors: [Color(hex: 0xf59e0b), Color(hex: 0xea580c)], icon: "play.rectangle"),
        CategoryTile(cat: "metadata", title: "Catalogs", blurb: "Posters, ratings, lists", colors: [Color(hex: 0x3b82f6), Color(hex: 0x4f46e5)], icon: "square.grid.2x2"),
        CategoryTile(cat: "subtitles", title: "Subtitles", blurb: "Captions in your language", colors: [Color(hex: 0x8b5cf6), Color(hex: 0xc026d3)], icon: "captions.bubble"),
        CategoryTile(cat: "anime", title: "Anime", blurb: "Kitsu, MAL, season-aware", colors: [Color(hex: 0xf43f5e), Color(hex: 0xdb2777)], icon: "sparkles"),
        CategoryTile(cat: "torrents", title: "Torrents", blurb: "P2P sources, debrid-ready", colors: [Color(hex: 0x10b981), Color(hex: 0x0d9488)], icon: "arrow.down.circle"),
        CategoryTile(cat: "live+tv", title: "Live TV", blurb: "OTA channels + IPTV", colors: [Color(hex: 0x06b6d4), Color(hex: 0x0284c7)], icon: "antenna.radiowaves.left.and.right"),
    ]

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Browse by category"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(Self.categoryTiles) { tile in
                    Button { model.goToCategory(tile.cat) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: tile.icon).font(.title2.weight(.semibold)).accessibilityHidden(true)
                            Spacer(minLength: 0)
                            Text(T(tile.title)).font(PhoneTheme.sans(17, .bold, relativeTo: .headline))
                            Text(T(tile.blurb)).font(PhoneTheme.sans(12, .medium, relativeTo: .caption)).opacity(0.85).lines(2)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                        .background(LinearGradient(colors: tile.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: .rect(cornerRadius: PhoneTheme.radiusMedium))
                        .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityIdentifier("addon-category-\(tile.cat)")
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    // MARK: Browse (browse-pane.tsx / community-browse-list.tsx)

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var browsePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ChipRow {
                    GlassChip(title: T("All"), selected: model.category == nil || searching) { model.setCategory(nil) }
                    ForEach(model.categories.filter { (settings.slice.showAdultAddons ?? false) || $0.slug != "nsfw" }) { c in
                        GlassChip(title: c.name, selected: model.category == c.slug && !searching) { model.setCategory(c.slug) }
                    }
                }
                ChipRow {
                    ForEach(AddonsModel.BrowseMode.allCases, id: \.self) { m in
                        GlassChip(title: T(Self.modeLabel(m).label), systemImage: Self.modeLabel(m).icon, selected: model.mode == m) {
                            model.setMode(m)
                        }
                    }
                }
                LazyVStack(spacing: 10) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, c in
                        communityRow(c)
                            .onAppear { if i >= model.items.count - 6 { Task { await model.loadMoreBrowse() } } }
                    }
                }
                .padding(.horizontal, PhoneTheme.margin)
                browseFooter
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("addons-browse")
    }

    @ViewBuilder private var browseFooter: some View {
        Group {
            if model.browseLoading {
                ProgressView().tint(BP.inkMuted)
            } else if model.items.isEmpty {
                if model.browseEmpty == "velocity" {
                    EmptyState(title: T("No velocity data yet"),
                               message: T("Trending tracks star growth across your Harbor visits. Open the addons page again tomorrow and the top risers will appear here."),
                               systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    EmptyState(title: T("No addons match these filters right now."), systemImage: "puzzlepiece.extension")
                }
            } else if !model.hasMore {
                Text(T("You've reached the end · %lld addons", model.items.count))
                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(BP.inkSubtle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private static func modeLabel(_ m: AddonsModel.BrowseMode) -> (label: String, icon: String) {
        switch m {
        case .top: return ("Top rated", "star")
        case .rising: return ("Top rising", "chart.line.uptrend.xyaxis")
        case .new: return ("Just added", "sparkles")
        }
    }

    private func communityRow(_ c: AddonsModel.Card) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { open(c) } label: {
                HStack(alignment: .top, spacing: 12) {
                    PhoneAddonLogo(url: c.logo, name: c.name, side: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: c.name)
                            .font(PhoneTheme.sans(16, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.ink)
                            .lines(1)
                        HStack(spacing: 8) {
                            if c.stars > 0 {
                                Label(clampedInt(c.stars).formatted(), systemImage: "star.fill").foregroundStyle(BP.accent)
                            }
                            if let rising = c.rising, rising > 0 {
                                Text(verbatim: Self.risingText(rising, window: c.risingWindow)).foregroundStyle(BP.live)
                            }
                            if !c.subtitle.isEmpty { Text(verbatim: c.subtitle).foregroundStyle(BP.inkSubtle).lines(1) }
                        }
                        .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                        Text(verbatim: c.description)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                            .lines(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            installButton(c)
        }
        .padding(12)
        .phoneGlassPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addon-card-\(c.name)")
    }

    @ViewBuilder private func installButton(_ c: AddonsModel.Card) -> some View {
        if c.installed {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(BP.accent)
                .accessibilityLabel(Text(T("Installed")))
        } else {
            Button { install(c) } label: {
                if model.busy.contains(c.key) { ProgressView() } else { Text(T("Install")) }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.busy.contains(c.key))
            .accessibilityIdentifier("addon-install-\(c.name)")
        }
    }

    /// community-browse-list.tsx: "+N / 24h" for the official list, "+N / 5d" for recorded velocity.
    private static func risingText(_ delta: Double, window: Double?) -> String {
        let days = clampedInt(window ?? 1)
        return "+\(clampedInt(delta)) / " + (days <= 1 ? "24h" : "\(days)d")
    }
}

/// An addon's logo on a rounded plate, or its initial when it has none (AddonLogoView on the TV).
struct PhoneAddonLogo: View {
    let url: String?
    let name: String
    var side: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).fill(BP.panel2)
            if let url, !url.isEmpty {
                PhoneImage(url: url, contentMode: .fit, plate: false).padding(side * 0.1)
            } else {
                Text(verbatim: String(name.prefix(1)).uppercased())
                    .font(PhoneTheme.display(side * 0.42, .semibold))
                    .foregroundStyle(BP.inkMuted)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A web page in Safari over the app (an addon's stremio-addons.net page, its rating page).
struct PhoneSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct PhoneExternalLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct PhoneAddonToasts: ViewModifier {
    @ObservedObject var model: AddonsModel

    func body(content: Content) -> some View {
        content.onChange(of: model.toast) { _, toast in
            guard let toast else { return }
            PhoneToaster.shared.show(toast.name.map { "\($0) · \(toast.text)" } ?? toast.text)
            if toast.ok { PhoneFeedback.shared.success() } else { PhoneFeedback.shared.failure() }
        }
    }
}

extension View {
    /// The model's install / remove / reorder messages as the app's toast.
    func phoneAddonToasts(_ model: AddonsModel) -> some View { modifier(PhoneAddonToasts(model: model)) }
}
