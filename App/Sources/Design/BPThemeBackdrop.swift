import SwiftUI


/// theme-backdrop.tsx inside the Big Picture page: --bp-void, or the theme's own gradient
/// (Stremio's indigo, Aurora's sky, Velvet's theatre), an http wallpaper under its scrim, and
/// Aurora's bokeh. Harbor default has none of these, so it stays the plain void.
struct BPThemeBackdrop: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        ZStack {
            BP.void_
            if let bg = theme.state?.background {
                if !bg.layers.isEmpty {
                    GeometryReader { g in
                        ZStack {
                            ForEach(Array(bg.layers.enumerated().reversed()), id: \.offset) { _, layer in
                                BPGradientLayer(layer: layer, size: g.size)
                            }
                        }
                    }
                } else if let url = bg.imageUrl {
                    RemoteImage(url: url)
                }
                if bg.scrim {
                    Color.black.opacity(0.45)
                    BP.canvas.opacity(bg.dim)
                }
            }
            if theme.state?.bokeh == true { BPBokehView() }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// One CSS gradient layer. Linear follows the CSS angle and gradient-line length; radial draws
/// the ellipse at its centre and lets the last stop cover everything outside it, as CSS does.
struct BPGradientLayer: View {
    let layer: ThemeStore.Layer
    let size: CGSize

    private var stops: [Gradient.Stop] {
        layer.stops.map { Gradient.Stop(color: ThemeStore.color($0.color), location: CGFloat(min(1, max(0, $0.at)))) }
    }

    var body: some View {
        let w: CGFloat = max(size.width, 1), h: CGFloat = max(size.height, 1)
        if layer.kind == "linear" {
            let a: CGFloat = CGFloat(layer.angle ?? 180) * .pi / 180
            let dx: CGFloat = sin(a), dy: CGFloat = -cos(a)
            let len: CGFloat = abs(w * dx) + abs(h * dy)
            let start = UnitPoint(x: (w / 2 - dx * len / 2) / w, y: (h / 2 - dy * len / 2) / h)
            let end = UnitPoint(x: (w / 2 + dx * len / 2) / w, y: (h / 2 + dy * len / 2) / h)
            LinearGradient(stops: stops, startPoint: start, endPoint: end)
        } else {
            let rx: CGFloat = CGFloat(layer.rx ?? 0.5) * w, ry: CGFloat = CGFloat(layer.ry ?? 0.5) * h
            ZStack {
                (layer.stops.last.map { ThemeStore.color($0.color) } ?? .clear)
                Rectangle()
                    .fill(EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: max(rx * 2, 1), height: max(ry * 2, 1))
                    .position(x: CGFloat(layer.cx ?? 0.5) * w, y: CGFloat(layer.cy ?? 0.5) * h)
            }
            .frame(width: w, height: h)
        }
    }
}

/// components/aurora-bokeh.tsx: seven soft orbs drifting slowly behind the Aurora theme.
struct BPBokehView: View {
    private struct Orb { var x, y, size, blur: CGFloat; var opacity, duration: Double; var color: Color }
    private static let palette: [Color] = [
        Color(.sRGB, red: 124 / 255, green: 214 / 255, blue: 1, opacity: 0.55),
        Color(.sRGB, red: 174 / 255, green: 140 / 255, blue: 1, opacity: 0.45),
        Color(.sRGB, red: 94 / 255, green: 165 / 255, blue: 247 / 255, opacity: 0.50),
        Color(.sRGB, red: 1, green: 180 / 255, blue: 220 / 255, opacity: 0.35),
        Color(.sRGB, red: 110 / 255, green: 1, blue: 210 / 255, opacity: 0.35),
    ]
    private static func seeded(_ i: Double) -> Double { let s = sin(i * 99.83) * 43758.5453; return s - s.rounded(.down) }
    private static let orbs: [Orb] = (0..<7).map { i in
        let r1 = seeded(Double(i * 3 + 1)), r2 = seeded(Double(i * 3 + 2)), r3 = seeded(Double(i * 3 + 3))
        return Orb(x: CGFloat(r1), y: CGFloat(r2), size: CGFloat(180 + r1 * 220), blur: CGFloat(24 + r3 * 28),
                   opacity: 0.4 + r2 * 0.35, duration: 28 + r3 * 24, color: palette[i % palette.count])
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<Self.orbs.count, id: \.self) { i in
                    let o = Self.orbs[i]
                    Circle()
                        .fill(RadialGradient(colors: [o.color, .clear], center: .center, startRadius: 0, endRadius: BP.px(o.size) * 0.65))
                        .frame(width: BP.px(o.size), height: BP.px(o.size))
                        .blur(radius: BP.px(o.blur))
                        .opacity(o.opacity)
                        .scaleEffect(drift ? 1.1 : 0.95)
                        .offset(y: drift ? -BP.px(40) : BP.px(20))
                        .position(x: o.x * g.size.width, y: o.y * g.size.height)
                        .animation(reduceMotion ? nil : Animation.easeInOut(duration: o.duration).repeatForever(autoreverses: true), value: drift)
                }
            }
        }
        .onAppear { if !reduceMotion { drift = true } }
    }
}
