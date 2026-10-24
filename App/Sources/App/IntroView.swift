import SwiftUI


/// bp-intro.tsx: eight columns of posters drifting up and down at their own speeds behind a
/// radial vignette, with the mark and spinner where the boot splash drew them, so the hand-off
/// from BootSplashView is a removal, not a cross-fade. Leaving scales it up, blurs and fades.
struct IntroView: View {
    @ObservedObject var model: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bedIn = false

    private static let speeds: [Double] = [46, 62, 52, 70, 56, 66, 50, 60]
    private static let delays: [Double] = [-8, -22, -4, -31, -14, -26, -11, -18]
    private static let up: [Bool] = [true, false, true, false, true, false, true, false]

    var body: some View {
        let leaving = model.phase == .leaving
        ZStack {
            BP.void_
            GeometryReader { g in
                let gutter = BP.px(11)
                let cell = (g.size.width - CGFloat(IntroModel.columns + 1) * gutter) / CGFloat(IntroModel.columns)
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(0..<IntroModel.columns, id: \.self) { col in
                        column(col, cell: cell, gutter: gutter, height: g.size.height)
                    }
                }
                .padding(.horizontal, gutter)
            }
            // bp-intro-bed: the wall settles in from 1.08 to its 50% bed.
            .opacity(bedIn ? 0.5 : 0)
            .scaleEffect(bedIn || reduceMotion ? 1 : 1.08)
            RadialGradient(stops: [
                .init(color: BP.void_.opacity(0.62), location: 0),
                .init(color: BP.void_.opacity(0.88), location: 0.52),
                .init(color: BP.void_, location: 1),
            ], center: .center, startRadius: 0, endRadius: 1100)
            // Same mark, size and spacing as BootSplashView (the settled pose, never re-assembled).
            VStack(spacing: BP.px(28)) {
                HarborMark(size: BP.px(120))
                ProgressView().tint(BP.inkMuted)
            }
        }
        .ignoresSafeArea()
        .scaleEffect(leaving && !reduceMotion ? 1.06 : 1)
        .blur(radius: leaving && !reduceMotion ? 10 : 0)
        .opacity(leaving ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1.4)) { bedIn = true }
        }
    }

    @ViewBuilder private func column(_ idx: Int, cell: CGFloat, gutter: CGFloat, height: CGFloat) -> some View {
        let n = IntroModel.perColumn
        let slice: [String?] = (0..<n).map { i in
            model.posters.isEmpty ? nil : model.posters[(idx * n + i) % model.posters.count]
        }
        let tile = cell * 1.5
        let half = (tile + gutter) * CGFloat(n)
        let stack = VStack(spacing: gutter) {
            ForEach(Array((slice + slice).enumerated()), id: \.offset) { _, url in
                Group {
                    if let url { RemoteImage(url: url) } else { BP.panel2 }
                }
                .frame(width: cell, height: tile)
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            }
        }
        if reduceMotion {
            stack.frame(width: cell, height: height, alignment: .top).clipped()
        } else {
            // splash-scroll-up/down: the doubled slice slides one half-length per period; a negative
            // delay starts the column part-way through, as the CSS animation-delay does.
            TimelineView(.animation) { ctx in
                let period = Self.speeds[idx]
                let t = (ctx.date.timeIntervalSinceReferenceDate - Self.delays[idx]).truncatingRemainder(dividingBy: period) / period
                let y = Self.up[idx] ? -CGFloat(t) * half : -half + CGFloat(t) * half
                stack.offset(y: y)
            }
            .frame(width: cell, height: height, alignment: .top)
            .clipped()
        }
    }
}
