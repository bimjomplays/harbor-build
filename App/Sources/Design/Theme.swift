import SwiftUI
import UIKit
import Combine


/// The page background: void with the brand-tinted wash upstream paints in the top corner.
struct BPAmbientBackground: View {
    /// bp-mosaic "ambient" variant behind screens with no art of their own; off when the viewer
    /// turned the animated backdrop off (settings.bigPictureMosaic).
    var mosaic = true
    /// RootView's (and the PiP browse layer's) instance: the fallback under screens that draw
    /// no background of their own, so any other instance showing in its window outranks it.
    var root = false
    /// SH-1 (bp-ambient.tsx TITLE_ART_ROUTES includes "collection" and "library", same as "home"):
    /// the tile the room currently has focused, wired through its cards' own onFocus. Its own
    /// backdrop (else poster) cross-fades in over the mosaic, the way Home's hero already does via
    /// SpotlightView/BPTitleArt for the routes that use it; nil, or a tile with neither field,
    /// leaves the mosaic showing.
    var focused: Meta? = nil
    @ObservedObject private var pool = AmbientPool.shared
    /// Only one mosaic in the app runs: see AmbientCoverage.
    @ObservedObject private var coverage = AmbientCoverage.shared
    /// Observed, not read in passing: Settings → Picture → Animated backdrop (or the quick
    /// panel's row) turned off left the mosaic drifting behind the Settings page, because nothing
    /// this view watches changed until the next cover or room switch.
    @ObservedObject private var settings = SettingsBridge.shared
    @State private var id = UUID()

    private var hasFocusedArt: Bool {
        !(focused?.background ?? "").isEmpty || !(focused?.poster ?? "").isEmpty
    }

    var body: some View {
        // `mosaic` can change while the instance stays up (RootView's follows the stage and the
        // room), so the fade keys on both.
        let on = mosaic && coverage.live == id
        let animated = settings.slice.bigPictureMosaic ?? true
        let artOn = on && animated && hasFocusedArt
        ZStack {
            // --bp-void, or the theme's own backdrop; plain void on Harbor default.
            BPThemeBackdrop()
            // The focused tile's own art outranks the poster mosaic (upstream never shows both);
            // a room with no focused tile, or a tile with no art, falls back to the mosaic exactly
            // as before.
            if artOn {
                BPTitleArt(meta: focused, drift: true)
                    .opacity(0.18)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
            } else if on, animated, pool.posters.count >= 12 {
                BPMosaicView(posters: pool.posters).opacity(0.13).transition(.opacity)
            }
            RadialGradient(colors: [BP.accent.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 1300)
            LinearGradient(colors: [BP.canvas.opacity(0.9), .clear], startPoint: .bottom, endPoint: .center)
        }
        // bp-ambient-layers BP_TITLE_ART_FADE_MS (440 ms): the art layer's own show/hide toggle;
        // BPTitleArt cross-fades what is drawn inside it on its own 480 ms timer.
        .animation(.easeInOut(duration: 0.44), value: artOn)
        .animation(BP.easeSlow, value: on)
        .background(AmbientProbe(id: id))
        .ignoresSafeArea()
        .task { await pool.load() }
        .onAppear { coverage.appeared(id, rank: root ? .root : .screen) }
        .onDisappear { coverage.disappeared(id) }
    }

    /// bp-shell.tsx:418-423 mounts no BpAmbient on search, live, sports or sports-event ("Live TV
    /// gets the flat canvas and no ambient at all"), so a shell's root instance draws no mosaic in
    /// those rooms. A sports event opens as a cover, which stands the root down by itself.
    static func shellDrawsMosaic(in room: Room) -> Bool {
        switch room {
        case .search, .live, .sports: return false
        // RoomView and DiscoverView paint SpotlightView's opaque backdrop over the whole screen, so a
        // root mosaic there drifted unseen (upstream's BpAmbient shows the title art there, never
        // the "ambient" mosaic variant). Discover only showed it for the moment before its spotlight.
        case .home, .movies, .shows, .anime, .discover: return false
        default: return true
        }
    }
}

/// A page's own stage mosaic (bp-mosaic variant "stage", painted at 32 %): Home's services and
/// addons bands (bp-ambient-layers) and Search (bp-search). It registers with AmbientCoverage
/// above every BPAmbientBackground, so the ambient mosaic under it (RootView's, or the screen's)
/// stands down while it is up: upstream never has two mosaics on screen. It keeps that rank while
/// it draws nothing (the caller passes [] below its own floor), because its caller paints an
/// opaque page over the ambient one anyway.
struct BPStageMosaic: View {
    /// The posters to draw, or [] for none yet.
    let posters: [String]
    /// A new key swaps the columns with a fade (bp-ambient MOSAIC_SWAP_MS: a new band cell).
    var key = ""
    @ObservedObject private var coverage = AmbientCoverage.shared
    @State private var id = UUID()

    var body: some View {
        let on = coverage.live == id && posters.count >= 12 && (SettingsBridge.shared.slice.bigPictureMosaic ?? true)
        ZStack {
            Color.clear
            if on {
                BPMosaicView(posters: posters, stage: true).opacity(0.32).id(key).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: on)
        .background(AmbientProbe(id: id))
        .allowsHitTesting(false)
        .onAppear { coverage.appeared(id, rank: .stage) }
        .onDisappear { coverage.disappeared(id) }
    }
}

/// Which BPAmbientBackground draws its mosaic. Upstream mounts one ambient layer,
/// in bp-shell outside the routed page, so one mosaic at most is ever on screen. Here the
/// background is drawn by RootView and again by ~20 screens and covers, each opaque, and every
/// one ran its 48 masked, drifting posters behind whatever covered it: the screen over RootView,
/// a fullScreenCover over the screen, the player, the screensaver. Now only the instance the
/// viewer can see runs one: in the topmost window, not under a presented cover (an alert aside),
/// a page's stage mosaic (BPStageMosaic: Home's bands, Search) over a screen's own background
/// over the root fallback, and the newest of those. None runs under the
/// screensaver or curfew lock, or while the app is in the background. Covers are not
/// observable, so presentations are polled twice a second, as PreviewGate does; the mosaic
/// leaves the tree when covered (fading back in when uncovered), so it neither animates nor draws.
@MainActor
final class AmbientCoverage: ObservableObject {
    static let shared = AmbientCoverage()
    /// The instance whose mosaic runs, if any.
    @Published private(set) var live: UUID?
    /// Within one window: a page's stage mosaic over a screen's own background over the root fallback.
    enum Rank: Int { case root = 0, screen = 1, stage = 2 }
    private struct Entry { var rank: Rank; var order: Int }
    private final class WeakView { weak var view: UIView?; init(_ v: UIView) { view = v } }
    private var entries: [UUID: Entry] = [:]
    private var probes: [UUID: WeakView] = [:]
    private var order = 0
    private var bag = Set<AnyCancellable>()

    private init() {
        // @Published fires before the value lands: read it on the next main-queue turn.
        ScreensaverModel.shared.$active.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        CurfewState.shared.$locked.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &bag)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    func appeared(_ id: UUID, rank: Rank) {
        order += 1
        entries[id] = Entry(rank: rank, order: order)
        refresh()
    }

    func disappeared(_ id: UUID) {
        entries[id] = nil
        refresh()
    }

    fileprivate func attach(_ id: UUID, _ view: UIView) {
        probes[id] = WeakView(view)
        // didMoveToWindow can land inside a SwiftUI update: publish on the next main-queue turn.
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func refresh() {
        probes = probes.filter { $0.value.view != nil }
        var pick: UUID?
        var best: (CGFloat, Int, Int) = (-.greatestFiniteMagnitude, -1, -1)
        let blocked = ScreensaverModel.shared.active || CurfewState.shared.locked
            || UIApplication.shared.applicationState == .background
        if !blocked {
            for (id, e) in entries {
                guard let v = probes[id]?.view, let w = v.window, !w.isHidden, !Self.presentedOver(v) else { continue }
                let key: (CGFloat, Int, Int) = (w.windowLevel.rawValue, e.rank.rawValue, e.order)
                if key > best {
                    best = key
                    pick = id
                }
            }
        }
        if live != pick { live = pick }
    }

    /// Something is presented over the view controller hosting `view` (a fullScreenCover, a sheet,
    /// the player's cover). An alert or confirmation dialog leaves the screen showing around it.
    private static func presentedOver(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        var owner: UIViewController?
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                owner = vc
                break
            }
            responder = next
        }
        guard var host = owner else { return false }
        while let parent = host.parent { host = parent }
        guard let presented = host.presentedViewController else { return false }
        if presented is UIAlertController { return false }
        return !presented.isBeingDismissed
    }
}

/// Tells AmbientCoverage where one BPAmbientBackground sits (its window and view controller).
private struct AmbientProbe: UIViewRepresentable {
    let id: UUID

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.id = id
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var id: UUID?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let id { AmbientCoverage.shared.attach(id, self) }
        }
    }
}

/// The poster pool the mosaic draws from (bp-ambient `pool`): the hero feed, fetched once.
@MainActor
final class AmbientPool: ObservableObject {
    static let shared = AmbientPool()
    @Published private(set) var posters: [String] = []
    private var loading = false
    func load() async {
        guard posters.isEmpty, !loading else { return }
        loading = true; defer { loading = false }
        // RootView's background asks for the pool from its first frame, during
        // the boot splash: `HarborEngine.shared` on the main actor built the ~4.4 MB bundle right
        // there (or waited out AppModel.boot's off-main build), freezing the splash and every press
        // for seconds, the very thing the lifecycle pass moved off the main thread. Build or wait
        // for it off the main thread first.
        if HarborEngine.loaded == nil {
            let built: Bool = await Task.detached(priority: .userInitiated) { (try? HarborEngine.sharedOrThrow()) != nil }.value
            guard built else { return }
        }
        struct M: Decodable { var poster: String? }
        let metas: [M] = (try? await HarborEngine.shared.call("feed.hero", ["trending"])) ?? []
        var seen: Set<String> = []
        posters = metas.compactMap(\.poster).filter { seen.insert($0).inserted }
    }
}

/// bp-mosaic.tsx: six columns of posters, rotated −14° and scaled 1.55, each column drifting
/// slowly (alternating directions) under a radial mask.
struct BPMosaicView: View {
    let posters: [String]
    /// bp-mosaic `variant="stage"`: the band mosaic behind Home's services/addons bands (wider,
    /// denser mask; the caller paints it at 32 %). The default is the "ambient" variant.
    var stage = false
    /// bp-decor-motion (useReducedMotion follows the setting live): the columns hold still under
    /// Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Toggling Reduce Motion rebuilds the columns, so a drift already running stops (or one
        // switched back on starts): a running repeatForever animation cannot be called off in place.
        BPMosaicColumns(posters: posters, stage: stage, drift: !reduceMotion).id(reduceMotion)
    }
}

private struct BPMosaicColumns: View {
    let posters: [String]
    let stage: Bool
    let drift: Bool
    private static let columns = 6, perColumn = 4
    @State private var phase = false

    var body: some View {
        GeometryReader { g in
            let colW = g.size.width * 0.11
            let gap = g.size.width * 0.016
            let tileH = colW * 1.5
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<Self.columns, id: \.self) { c in
                    let col = (0..<Self.perColumn).map { posters[(c * Self.perColumn + $0) % posters.count] }
                    VStack(spacing: gap) {
                        ForEach(Array((col + col).enumerated()), id: \.offset) { _, url in
                            RemoteImage(url: url).frame(width: colW, height: tileH).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .offset(y: (phase ? -1 : 0) * (tileH + gap) * CGFloat(Self.perColumn) * (c % 2 == 0 ? 1 : -1))
                    .animation(.linear(duration: Double(74 + c * 9)).repeatForever(autoreverses: false), value: phase)
                }
            }
            .rotationEffect(.degrees(-14))
            .scaleEffect(1.55)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .mask(stage
                  ? RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.72), location: 0.58), .init(color: .clear, location: 0.92)],
                                   center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: g.size.width * 0.8)
                  : RadialGradient(colors: [.black, .black.opacity(0.55), .clear], center: .init(x: 0.5, y: 0.4), startRadius: 0, endRadius: g.size.width * 0.75))
        }
        .allowsHitTesting(false)
        .onAppear { if drift { phase = true } }
    }
}
