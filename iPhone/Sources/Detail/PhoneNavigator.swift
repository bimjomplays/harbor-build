import SwiftUI

/// The episode a title page opens on (an AI search episode pick): the page lands on its season,
/// scrolls to it and marks it (views/detail.tsx episodeHint, DetailView's `episodeHint` on the TV).
struct PhoneEpisodeHint: Hashable {
    var season: Int
    var episode: Int
}

/// A title page to push: the title, the episode it opens on, and the poster it zooms out of.
/// Each push is its own page (a title reached again from its own More Like This is a new page),
/// so equality is the push, not the title.
struct PhoneDetailTarget: Hashable {
    let meta: Meta
    var hint: PhoneEpisodeHint?
    /// The tapped tile's `matchedTransitionSource` id, when a tile opened the page.
    var zoomKey: String?
    /// The page plays as soon as it knows what Play starts (a Continue Watching resume, a hero's Play).
    var autoPlay: Bool
    private let push = UUID()

    @MainActor init(meta: Meta, hint: PhoneEpisodeHint? = nil, zoomKey: String? = nil, autoPlay: Bool = false) {
        self.meta = PhoneDetailFixtures.prepare(meta)
        self.hint = hint
        self.zoomKey = zoomKey
        self.autoPlay = autoPlay
    }

    static func == (a: PhoneDetailTarget, b: PhoneDetailTarget) -> Bool { a.push == b.push }
    func hash(into hasher: inout Hasher) { hasher.combine(push) }
}

/// One navigation stack's path (: each tab owns a `NavigationStack`; Detail,
/// person, collection, service and addon pages push). Screens reach it through the environment.
@MainActor
final class PhoneNavigator: ObservableObject {
    @Published var path = NavigationPath()
    /// The tile pressed just now, so the page it opens can zoom out of it.
    private var armed: (key: String, at: Date)?

    /// A tile's press, just before its action runs.
    func arm(_ key: String) { armed = (key, Date()) }

    /// Pushes the title page. A tile pressed in the last moment is where it zooms from.
    /// `autoPlay`: the page plays at once (the hero's Play).
    func open(_ meta: Meta, hint: PhoneEpisodeHint? = nil, autoPlay: Bool = false) {
        var key: String?
        if let armed, Date().timeIntervalSince(armed.at) < 0.6 { key = armed.key }
        armed = nil
        path.append(PhoneRoute.title(PhoneDetailTarget(meta: meta, hint: hint, zoomKey: key, autoPlay: autoPlay)))
    }

    func push<Value: Hashable>(_ value: Value) {
        armed = nil
        path.append(value)
    }
}

/// The zoom transition's namespace and the press that arms it, for tiles inside a `PhoneTabStack`.
struct PhoneZoom {
    let namespace: Namespace.ID
    let arm: (String) -> Void
}

extension EnvironmentValues {
    @Entry var phoneZoom: PhoneZoom? = nil
}

/// A tab's (or the deep-link sheet's) navigation stack: the path every push goes through, the pages
/// a `PhoneRoute` opens, and the zoom from a tapped poster into its title page.
struct PhoneTabStack<Root: View>: View {
    @StateObject private var nav = PhoneNavigator()
    @Namespace private var zoomSpace
    private let root: (PhoneNavigator) -> Root

    init(@ViewBuilder root: @escaping (PhoneNavigator) -> Root) {
        self.root = root
    }

    var body: some View {
        let navigator = nav
        NavigationStack(path: $nav.path) {
            root(nav)
                .navigationDestination(for: PhoneRoute.self) { route in
                    PhoneRoutePage(route: route, open: { nav.open($0) })
                        .modifier(PhoneZoomDestination(key: route.zoomKey, namespace: zoomSpace))
                }
        }
        .environmentObject(nav)
        .environment(\.phoneZoom, PhoneZoom(namespace: zoomSpace, arm: { key in navigator.arm(key) }))
    }
}

/// The pushed page zooms out of the tile that opened it (iOS 18+ `.zoom`); any other push slides.
private struct PhoneZoomDestination: ViewModifier {
    let key: String?
    let namespace: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        // Reduce Motion: the plain push, not the page growing out of its tile.
        if let key, !PhoneMotion.reduced {
            content.navigationTransition(.zoom(sourceID: key, in: namespace))
        } else {
            content
        }
    }
}

/// A tile's art as the source of the zoom into its title page. Without a stack around it (a sheet,
/// the kids shell) it is the plain art.
struct PhoneZoomSource: ViewModifier {
    let key: String
    @Environment(\.phoneZoom) private var zoom

    @ViewBuilder func body(content: Content) -> some View {
        if let zoom {
            content.matchedTransitionSource(id: key, in: zoom.namespace)
        } else {
            content
        }
    }
}
