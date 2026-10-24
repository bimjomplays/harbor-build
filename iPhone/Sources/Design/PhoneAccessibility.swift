import SwiftUI
import UIKit

// The one place the phone's accessibility rules live, so a
// screen asks instead of re-deciding. Reduce Motion: movement (slides, springs, zooms, parallax) is
// swapped for nothing, or for a plain fade. Dynamic Type: rails grow, grids drop a column.

/// Whether the viewer asked for less motion (Settings → Accessibility → Motion), or a UI test did
/// with `--phone-reduce-motion` (a simulator has no switch a launch argument can flip).
enum PhoneMotion {
    nonisolated static var reduced: Bool {
        if PhoneLaunch.reduceMotion { return true }
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIAccessibility.isReduceMotionEnabled }
    }
}

/// `withAnimation` that does not move anything under Reduce Motion: the state still changes, at once.
func withMotion<R>(_ animation: Animation? = .default, _ body: () throws -> R) rethrows -> R {
    try withAnimation(PhoneMotion.reduced ? nil : animation, body)
}

extension View {
    /// `.animation(_:value:)` that stands still under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.animation(PhoneMotion.reduced ? nil : animation, value: value)
    }

    /// A transition that slides in `edge` normally and only fades under Reduce Motion.
    func slideOrFade(_ edge: Edge) -> some View {
        transition(PhoneMotion.reduced ? .opacity : .move(edge: edge).combined(with: .opacity))
    }
}

extension DynamicTypeSize {
    /// How much a rail's tiles grow: the art and the text under it stay in proportion, up to about a
    /// third wider at the largest accessibility size (more would leave one tile on screen).
    var railScale: CGFloat {
        switch self {
        case .xxxLarge: return 1.1
        case .accessibility1: return 1.2
        case .accessibility2: return 1.28
        case .accessibility3, .accessibility4, .accessibility5: return 1.35
        default: return 1
        }
    }

    /// Text lines a one-line tile caption may take: one normally, three at accessibility sizes.
    var captionLines: Int { isAccessibilitySize ? 3 : 1 }
}

extension EnvironmentValues {
    /// The factor the enclosing rail applies to its tiles' widths (`Rail`); 1 outside a rail, so a
    /// grid that sizes its own cells is untouched.
    @Entry var phoneRailScale: CGFloat = 1
}

/// Sets `phoneRailScale` from the Dynamic Type size: put it on a rail's scroll content.
private struct RailScaled: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.environment(\.phoneRailScale, typeSize.railScale)
    }
}

extension View {
    /// Tiles inside this view grow with Dynamic Type (see `DynamicTypeSize.railScale`).
    func phoneRailScaled() -> some View { modifier(RailScaled()) }
}

/// A fixed icon size that follows Dynamic Type (`@ScaledMetric`), for an icon that was a bare
/// `.font(.system(size:))` and so stayed the same at every text size.
struct ScaledIcon: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .body) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    func scaledIcon(_ size: CGFloat, weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledIcon(size: size, weight: weight, relativeTo: style))
    }
}

/// `.lineLimit(n)` until the text size is an accessibility one, then no limit: a title or a caption
/// that was cut to one line at the default size is read in full when it is set this large.
private struct AdaptiveLines: ViewModifier {
    let limit: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.lineLimit(typeSize.isAccessibilitySize ? nil : limit)
    }
}

extension View {
    func lines(_ limit: Int) -> some View { modifier(AdaptiveLines(limit: limit)) }
}
