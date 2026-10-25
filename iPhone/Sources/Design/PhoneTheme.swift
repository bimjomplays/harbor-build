import SwiftUI

/// Phone layout tokens and type. Colours are the shared `BP` tokens, so
/// a theme the engine resolves (ThemeStore) paints the phone exactly as it paints the TV; sizes are
/// phone points, and the type scales with Dynamic Type (`relativeTo:`), which the TV's px-based
/// `BP.sans` / `BP.display` do not.
enum PhoneTheme {
    static let margin: CGFloat = 16
    static let radiusSmall: CGFloat = 12
    static let radiusMedium: CGFloat = 18
    static let radiusLarge: CGFloat = 26
    static let posterWidth: CGFloat = 116
    static let backdropWidth: CGFloat = 232
    static let railGap: CGFloat = 12

    /// The theme's UI face (Switzer by default) at a Dynamic-Type-relative size.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        if BPThemeState.current.sansFace == .system { return .system(style, design: .default, weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Switzer-Bold"
        case .semibold: name = "Switzer-Semibold"
        case .medium: name = "Switzer-Medium"
        default: name = "Switzer-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// The theme's display face (Sentient by default) for titles and hero copy.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .title) -> Font {
        switch BPThemeState.current.displayFace {
        case .system: return .system(style, design: .serif, weight: weight)
        // Only the Medium cut of Fraunces ships.
        case .fraunces: return .custom("Fraunces-Medium", size: size, relativeTo: style)
        case .sentient:
            let name: String = weight == .regular ? "Sentient-Regular" : (weight == .bold ? "Sentient-Bold" : "Sentient-Medium")
            return .custom(name, size: size, relativeTo: style)
        }
    }
}

/// The canvas under every phone screen: the theme's canvas with a faint accent glow at the top, so
/// the glass above it has something to refract.
struct PhoneBackground: View {
    var body: some View {
        ZStack {
            BP.canvas
            RadialGradient(colors: [BP.accent.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// The sail mark from the app icon (the template image in iPhone/Assets.xcassets).
struct PhoneMark: View {
    var size: CGFloat = 96
    var body: some View {
        Image("HarborMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(BP.ink)
            .frame(width: size, height: size)
            // Decoration: the wordmark or a label next to it says Harbor.
            .accessibilityHidden(true)
    }
}

/// "Harb(o)r" wordmark in Fraunces with the tilted o (the TV's HarborWordmark).
struct PhoneWordmark: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "Harb")
            Text(verbatim: "o").rotationEffect(.degrees(7), anchor: UnitPoint(x: 0.5, y: 0.65))
            Text(verbatim: "r")
        }
        .font(.custom("Fraunces-Medium", size: size, relativeTo: .title))
        .foregroundStyle(BP.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Harbor"))
    }
}

/// UI-test and screenshot hooks, read from the launch arguments. They exist only here (the shared
/// Fixtures stay as the TV has them): a phone launch without them behaves normally.
enum PhoneLaunch {
    private static var args: [String] { ProcessInfo.processInfo.arguments }

    /// `--phone-curfew`: the curfew cover is up over a kid's shell as if the day's allowance were
    /// spent (the real lock needs a film to have played, and the phone has no player yet).
    static var curfewPreview: Bool { args.contains("--phone-curfew") }

    /// `--phone-reduce-motion`: the app behaves as if Reduce Motion were on (PhoneMotion), so the UI tests
    /// can check it on a simulator, which has no launch-argument switch for the system setting.
    static var reduceMotion: Bool { args.contains("--phone-reduce-motion") }

    /// `--phone-open <url>`: a harbor:// link handled once the app is up, as if another app opened it.
    static var openURL: URL? {
        guard let i = args.firstIndex(of: "--phone-open"), i + 1 < args.count else { return nil }
        return URL(string: args[i + 1])
    }

    /// `--phone-picker` (with `--fixtures detail --fixture-streams`): the shell opens the play picker
    /// on a fixture film, so the picker can be tested and screenshotted on its own.
    static var picker: Bool { args.contains("--phone-picker") }
    /// `--phone-picker-subtitles`: that picker asks for subtitles after a pick (subtitlePreselect on).
    static var pickerSubtitles: Bool { args.contains("--phone-picker-subtitles") }
    /// `--phone-picker-auto`: that picker opens on the auto step (instant play).
    static var pickerAuto: Bool { args.contains("--phone-picker-auto") }
    /// `--phone-external-players` (with `--fixtures`): Infuse, VLC and VidHub count as installed, so the
    /// Player setting and "Open in…" can be tested on a simulator, which has none of them.
    static var externalPlayers: Bool { args.contains("--phone-external-players") }

    /// `--phone-hero-demo` (with `--fixtures`): the first hero title is dressed as a real one (name, art, logo,
    /// facts, a "#1" kicker) so the Home hero can be screenshotted as it looks with art. The fixtures
    /// themselves carry none, and no screenshot should wait on the network for it.
    static var heroDemo: Bool { args.contains("--phone-hero-demo") }

    /// `--phone-player-demo` (with `--fixtures`): the player's stand-in engine shows a real backdrop as its
    /// picture and carries a film's worth of audio and subtitle tracks, so the player can be screenshotted
    /// as it looks over a picture (PlayerShotTests). The volume starts at 40 %.
    static var playerDemo: Bool { args.contains("--phone-player-demo") }

    /// `--phone-no-resume` (with `--fixtures`): Continue Watching comes back empty for the tab bar's
    /// Resume accessory, so its hidden state can be tested (the fixture feed always has two titles).
    static var noResume: Bool { args.contains("--phone-no-resume") }

    /// `--phone-library-fail` (with `--fixtures`): the Library's read fails, so its error plate shows.
    static var libraryFail: Bool { args.contains("--phone-library-fail") }

    /// `--phone-collections`: the viewer's collections are replaced by three fixture ones in a known
    /// order (PhoneCollectionsStore.fixture), so the Collections UI test starts from the same grid.
    static var collectionsFixture: Bool { args.contains("--phone-collections") }

    /// The app is hosting the unit tests (HarborPhoneTests): it stays on the splash and does not boot
    /// the engine, so the tests run against their own fakes and leave nothing behind for the UI tests.
    /// A UI-tested launch has neither the variable nor XCTest loaded (the runner is its own process).
    static var hostsUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil && NSClassFromString("XCTestCase") != nil
    }
}
