import SwiftUI
import UIKit
import Combine

/// Big Picture design tokens. Upstream lays out on a 1140×641 CSS
/// canvas; tvOS lays out on 1920×1080 points, so every px value is scaled by `BP.k`.
///
/// Colours and faces read the active theme(`BPThemeState.current`, set by ThemeStore
/// from engine/themes.ts). They are computed, not stored, so every caller keeps its syntax; the
/// Harbor default theme resolves to exactly the constants this file always shipped.
enum BP {
    static let k: CGFloat = 1920.0 / 1140.0
    static func px(_ v: CGFloat) -> CGFloat { (v * k).rounded() }

    // Base theme "Harbor default" (cool-grey), theme.ts:124-143, or the active preset's tokens.
    static var canvas: Color { BPThemeState.current.canvas }
    static var surface: Color { BPThemeState.current.surface }
    static var elevated: Color { BPThemeState.current.elevated }
    static var raised: Color { BPThemeState.current.raised }
    static var ink: Color { BPThemeState.current.ink }
    static var inkMuted: Color { BPThemeState.current.inkMuted }
    static var inkSubtle: Color { BPThemeState.current.inkSubtle }
    static var accent: Color { BPThemeState.current.accent }
    static var danger: Color { BPThemeState.current.danger }
    /// bp-tokens.ts: --bp-live is a fixed green in every theme.
    static let live = Color(hex: 0x4ade80)

    // --bp-* derivations (bp-tokens.ts:1-18), resolved per theme.
    static var void_: Color { BPThemeState.current.void_ }
    static var panel: Color { BPThemeState.current.panel }
    static var panel2: Color { BPThemeState.current.panel2 }
    static var on: Color { BPThemeState.current.on }
    static var glass: Color { ink.opacity(0.07) }
    static var edge: Color { ink.opacity(0.11) }
    static var edge2: Color { ink.opacity(0.18) }
    static var focusStroke: Color { ink.opacity(0.86) }

    // Radii (bp-tokens.ts:37-40).
    static let rXS = px(8), rSM = px(10), rMD = px(16), rLG = px(24)

    // Layout (bp-tokens.ts:51-94), resolved at the 1140 canvas.
    static let gutter = px(85.5)
    static let barHeight = px(72)
    static let hintHeight = px(52)
    static let rowGap = px(20)
    static let trackGap = px(21)
    static let tabItem = px(44)

    // Motion (bp-tokens.ts:42-46, 127-150).
    static let focusLift: CGFloat = 1.03
    static let press: CGFloat = 0.965
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.19).delay(0.07)
    static let easeFast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)
    static let easeSlow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // Type (Switzer for UI, Sentient for hero-scale titles, Fraunces for the wordmark), or the
    // theme's font pair (lib/theme.ts FONT_PAIRS) where the app bundles it; the rest fall through
    // their CSS stacks to system-ui, which on tvOS is SF.
    static func sans(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        sans(px, weight, face: BPThemeState.current.sansFace)
    }
    static func display(_ px: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        display(px, weight, face: BPThemeState.current.displayFace)
    }
    /// A specific face, whatever the theme (the Typography tiles draw every pair in its own).
    static func sans(_ px: CGFloat, _ weight: Font.Weight, face: BPThemeTokens.SansFace) -> Font {
        if face == .system { return .system(size: Self.px(px), weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Switzer-Bold"
        case .semibold: name = "Switzer-Semibold"
        case .medium: name = "Switzer-Medium"
        default: name = "Switzer-Regular"
        }
        return .custom(name, size: Self.px(px))
    }
    static func display(_ px: CGFloat, _ weight: Font.Weight, face: BPThemeTokens.DisplayFace) -> Font {
        switch face {
        case .system: return .system(size: Self.px(px), weight: weight)
        // Only the Medium cut of Fraunces ships (it draws the wordmark).
        case .fraunces: return .custom("Fraunces-Medium", size: Self.px(px))
        case .sentient:
            let name = weight == .regular ? "Sentient-Regular" : (weight == .bold ? "Sentient-Bold" : "Sentient-Medium")
            return .custom(name, size: Self.px(px))
        }
    }
    static func wordmark(_ px: CGFloat) -> Font { .custom("Fraunces-Medium", size: Self.px(px)) }
}

/// One resolved theme: the colours and faces BP hands out, plus the preset's card/button styles.
struct BPThemeTokens {
    enum DisplayFace: String { case sentient, fraunces, system }
    enum SansFace: String { case switzer, system }

    var canvas, surface, elevated, raised, ink, inkMuted, inkSubtle, accent, danger: Color
    var void_, panel, panel2, on: Color
    var displayFace: DisplayFace = .sentient
    var sansFace: SansFace = .switzer
    /// lib/theme.ts ThemeButtonStyle / ThemeCardStyle ("flat" by default).
    var buttonStyle = "flat"
    var cardStyle = "flat"

    /// "Harbor default" exactly as Theme.swift has always drawn it.
    static let harbor = BPThemeTokens(
        canvas: Color(hex: 0x111213), surface: Color(hex: 0x191b1c), elevated: Color(hex: 0x252628), raised: Color(hex: 0x323335),
        ink: Color(hex: 0xf4f5f7), inkMuted: Color(hex: 0xa3a5a6), inkSubtle: Color(hex: 0x626365),
        accent: Color(hex: 0xf4a25c), danger: Color(hex: 0xc53637),
        void_: Color(hex: 0x0d0e0f), panel: Color(hex: 0x161819), panel2: Color(hex: 0x222325), on: Color(hex: 0x404142))
}

/// The theme every BP accessor reads. Written only by ThemeStore on the main actor; RootView
/// rebuilds its tree (ThemeStore.revision) whenever it changes, so views pick it up.
enum BPThemeState {
    static var current = BPThemeTokens.harbor
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
    /// Parses "#rrggbb" (profile colors come over the wire as CSS hex).
    init?(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
