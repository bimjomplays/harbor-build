import SwiftUI

// the phone's Liquid Glass parts. Chrome (chips, bars, plates, toasts) is
// glass; content (posters, backdrops) never is.

/// A press that lands with a small scale-down and a light tap.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .motion(.easeOut(duration: 0.14), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { PhoneFeedback.shared.tap() }
            }
    }
}

extension View {
    /// A glass plate behind this view (cards, plates, panels).
    func phoneGlassPlate(radius: CGFloat = PhoneTheme.radiusMedium) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

/// One selectable chip: the Home / Movies / Shows / Anime strip, filters, quick actions.
struct GlassChip: View {
    let title: String
    var systemImage: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        let glass: Glass = selected ? Glass.regular.tint(BP.accent).interactive() : Glass.regular.interactive()
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.footnote.weight(.semibold))
                }
                Text(verbatim: title).font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
            }
            .foregroundStyle(selected ? BP.on : BP.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(glass, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("chip-\(title)")
    }
}

/// A horizontally scrolling strip of chips that blend as one glass group.
struct ChipRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { content }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.vertical, 4)
        }
    }
}

/// A rail or section title with an optional trailing action ("See all").
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionIdentifier = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title)
                .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                .foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(verbatim: actionTitle).font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                }
                .foregroundStyle(BP.accent)
                .accessibilityIdentifier(actionIdentifier.isEmpty ? "section-action-\(title)" : actionIdentifier)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }
}

/// Nothing to show yet, or a screen a later release fills: an icon, a line, an optional button.
struct EmptyState: View {
    let title: String
    var message: String? = nil
    var systemImage = "sailboat.fill"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(BP.inkMuted)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                .foregroundStyle(BP.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(verbatim: message)
                    .font(PhoneTheme.sans(16, .regular, relativeTo: .callout))
                    .foregroundStyle(BP.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glass)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-state")
    }
}

/// A read that failed, with the way to try it again.
struct ErrorPlate: View {
    let title: String
    var message: String? = nil
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(BP.danger)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(PhoneTheme.sans(18, .semibold, relativeTo: .headline))
                .foregroundStyle(BP.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(verbatim: message)
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(T("Try again"), action: retry).buttonStyle(.glassProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .phoneGlassPlate()
        .padding(.horizontal, PhoneTheme.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-plate")
    }
}

/// A slow sweep of light over a placeholder while its content loads (still under Reduce Motion).
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, BP.ink.opacity(0.13), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                guard !PhoneMotion.reduced else { return }
                withMotion(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// A grey block standing in for a poster, a line of text or a hero.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = PhoneTheme.radiusSmall

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(BP.ink.opacity(0.07))
            .frame(width: width, height: height)
            .shimmer()
            .accessibilityHidden(true)
    }
}

/// The app's one short message ("Link copied", "Couldn't open that"): a glass capsule that drops in
/// from the top and goes by itself.
@MainActor
final class PhoneToaster: ObservableObject {
    static let shared = PhoneToaster()
    @Published private(set) var message: String?
    private var hide: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

private struct ToastHost: ViewModifier {
    @ObservedObject private var toaster = PhoneToaster.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = toaster.message {
                    Text(verbatim: message)
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .slideOrFade(.top)
                        .accessibilityIdentifier("toast")
                }
            }
            .motion(.snappy, value: toaster.message)
    }
}

extension View {
    /// Shows `PhoneToaster` messages over this view.
    func toastHost() -> some View { modifier(ToastHost()) }
}
