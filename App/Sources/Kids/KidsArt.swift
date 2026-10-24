import SwiftUI
import UIKit


/// A bundled kids image, aspect-fit; nothing when the art is missing (a build without assets).
struct KidsArt: View {
    let image: UIImage?
    var contentMode: ContentMode = .fit

    init(_ path: String, contentMode: ContentMode = .fit) {
        self.image = KidsTheme.art(path)
        self.contentMode = contentMode
    }

    init(doodle name: String) {
        self.image = KidsTheme.doodle(name)
    }

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// A kids card button: white ring always, lifts forward with a sunny ring and a deeper shadow on
/// focus (upstream's `ring-2 ring-white` + `hover:-translate-y-1.5 hover:shadow-[…]`).
struct KidsCardStyle: ButtonStyle {
    var radius: CGFloat = BP.px(22)
    var ring: CGFloat = BP.px(2)
    var onFocus: (() -> Void)? = nil
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader(onFocus: onFocus) { focused in
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(focused ? KidsTheme.sunny : .white, lineWidth: focused ? ring + 3 : ring))
                .shadow(color: KidsTheme.shadow.opacity(focused ? 0.55 : 0.4), radius: focused ? 24 : 14, y: focused ? 20 : 12)
                .scaleEffect(focused ? (configuration.isPressed ? 1.04 : 1.07) : 1)
                .offset(y: focused ? -BP.px(6) : 0)
                .animation(BP.ease, value: focused)
                .animation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.09), value: configuration.isPressed)
        }
    }
}

/// A rounded kids pill (Back, Shuffle, filters, season chips): its own fill, a ring on focus.
struct KidsPillStyle: ButtonStyle {
    var fill: Color = .white.opacity(0.9)
    var focusedFill: Color? = nil
    var ink: Color = KidsTheme.sea
    var height: CGFloat = BP.px(46)
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(KidsTheme.font(16, .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, BP.px(22))
                .frame(minHeight: height)
                .background(Capsule().fill(focused ? (focusedFill ?? fill) : fill))
                .overlay(Capsule().stroke(focused ? KidsTheme.sunny : .white.opacity(0.4), lineWidth: focused ? 5 : 3))
                .shadow(color: KidsTheme.shadow.opacity(focused ? 0.5 : 0.25), radius: focused ? 18 : 10, y: focused ? 12 : 6)
                .scaleEffect(focused ? (configuration.isPressed ? 1.0 : 1.05) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
