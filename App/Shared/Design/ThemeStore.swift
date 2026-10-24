import SwiftUI

/// themes (lib/theme.ts presets, views/settings/theme-panel.tsx), resolved by the engine
/// (engine/themes.ts `themes.state`) into sRGB tokens, font faces and backgrounds. Applying one
/// writes `settings.theme` the way upstream's ThemeTab does, so it syncs with the profile.
/// No custom CSS/JS/HTML layers: tvOS has no web view to run them in.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    struct Palette: Decodable, Equatable {
        var canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger: [Double]
        var void_, panel, panel2, on: [Double]
        enum CodingKeys: String, CodingKey {
            case canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger, panel, panel2, on
            case void_ = "void"
        }
    }
    struct Faces: Decodable, Equatable { var display: String; var sans: String }
    struct Stop: Decodable, Equatable { var color: [Double]; var at: Double }
    /// "linear" carries `angle` (CSS degrees); "radial" carries the ellipse radii and centre as
    /// fractions of the screen (`ellipse rx ry at cx cy`).
    struct Layer: Decodable, Equatable {
        var kind: String
        var angle: Double?
        var rx: Double?, ry: Double?, cx: Double?, cy: Double?
        var stops: [Stop]
    }
    struct Background: Decodable, Equatable { var layers: [Layer]; var imageUrl: String?; var dim: Double; var scrim: Bool }
    struct Preset: Decodable, Identifiable, Equatable {
        var id: String; var name: String; var blurb: String; var category: String
        var swatch: [[Double]]; var canvasLight: Bool
    }
    struct FontPair: Decodable, Identifiable, Equatable { var id: String; var name: String; var blurb: String; var faces: Faces }
    struct Snapshot: Decodable, Equatable {
        var active: String
        var fontPair: String
        var pickedFontPair: String
        var presetOwnsFont: Bool
        var faces: Faces
        var palette: Palette
        var light: Bool
        var layout: String
        var cardStyle: String
        var buttonStyle: String
        var bokeh: Bool
        var background: Background
        var presets: [Preset]
        var hasCustom: Bool
        var fontPairs: [FontPair]
    }

    @Published private(set) var state: Snapshot?
    /// Bumped whenever what the theme paints changes; RootView keys its tree on it so every view
    /// re-reads the BP tokens.
    @Published private(set) var revision = 0

    private var unsubscribe: (() -> Void)?
    /// Set while onboarding runs: a theme pulled in by the Harbor sign-in waits until the wizard
    /// is done, because repainting rebuilds the tree and would restart it at the first step.
    var holding = false {
        didSet { releasePending() }
    }
    /// Set while a film, channel or Multiview plays (RootView follows PlaybackState): a theme a
    /// profile-sync pull brings mid-playback waits, because the rebuild would tear the player down.
    var holdingForPlayback = false {
        didSet { releasePending() }
    }
    /// Set while a fullScreenCover is up (RootView follows CoverPresence): a
    /// theme a profile-sync pull brings while a Detail page, Settings, Addons or another cover is
    /// open waits the same way, because the rebuild drops that cover's `@State` with nothing to
    /// show for it (no Back, no dismiss) — see the notes on "sync-pulled theme or language
    /// drops a non-player cover".
    var holdingForCover = false {
        didSet { releasePending() }
    }
    private var held: Bool { holding || holdingForPlayback || holdingForCover }
    private var pending: Snapshot?
    /// Counts the changes this device makes (a pick, a font pair): a `load` that began before one holds
    /// a state read from before it, and must not put that back over the pick. A settings event from the
    /// engine (a Titles-under-posters patch fires one) starts such a load right as the next pick lands.
    private var changes = 0

    private func releasePending() {
        if !held, let p = pending { pending = nil; adopt(p) }
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    func load() async {
        if unsubscribe == nil {
            // A profile-sync pull can bring a theme chosen on another device.
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, _ in
                guard type == "harbor:settings-updated" else { return }
                Task { await self?.load() }
            }
        }
        let p = profile
        let seen = changes
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.state", [p.id, p.linked]), seen == changes { adopt(s) }
    }

    /// theme-panel.tsx ThemeTab onSelect.
    func select(_ id: String) async {
        let p = profile
        changes += 1
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.apply", [id, p.id, p.linked]) { changes += 1; adopt(s) }
    }

    /// theme-panel.tsx TypographyTab onPickPair.
    func setFontPair(_ id: String) async {
        let p = profile
        changes += 1
        if let s: Snapshot = try? await HarborEngine.shared.call("themes.setFontPair", [id, p.id, p.linked]) { changes += 1; adopt(s) }
    }

    private func adopt(_ s: Snapshot) {
        if held { pending = s; return }
        let old = state
        state = s
        let looksSame = old.map {
            $0.active == s.active && $0.palette == s.palette && $0.faces == s.faces && $0.background == s.background
                && $0.bokeh == s.bokeh && $0.buttonStyle == s.buttonStyle && $0.cardStyle == s.cardStyle && $0.light == s.light
        } ?? false
        if looksSame { return }
        BPThemeState.current = Self.tokens(for: s)
        // The first load at boot only replaces the default when the profile has another theme.
        if old != nil || s.active != "cool-grey" || s.faces != Faces(display: "sentient", sans: "switzer") { revision += 1 }
    }

    static func tokens(for s: Snapshot) -> BPThemeTokens {
        // Harbor default keeps the exact shipped constants; every other theme uses the engine's.
        var t = s.active == "cool-grey" ? BPThemeTokens.harbor : BPThemeTokens(
            canvas: color(s.palette.canvas), surface: color(s.palette.surface), elevated: color(s.palette.elevated),
            raised: color(s.palette.raised), ink: color(s.palette.ink), inkMuted: color(s.palette.inkMuted),
            inkSubtle: color(s.palette.inkSubtle), accent: color(s.palette.accent), danger: color(s.palette.danger),
            void_: color(s.palette.void_), panel: color(s.palette.panel), panel2: color(s.palette.panel2), on: color(s.palette.on))
        t.displayFace = BPThemeTokens.DisplayFace(rawValue: s.faces.display) ?? .sentient
        t.sansFace = BPThemeTokens.SansFace(rawValue: s.faces.sans) ?? .switzer
        t.buttonStyle = s.buttonStyle
        t.cardStyle = s.cardStyle
        return t
    }

    nonisolated static func color(_ c: [Double]) -> Color {
        guard c.count >= 3 else { return .clear }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c.count >= 4 ? c[3] : 1)
    }
}
