import SwiftUI


struct CurfewLockView: View {
    @ObservedObject var state: CurfewState
    @EnvironmentObject private var app: AppModel
    @State private var pin = false

    var body: some View {
        ZStack {
            // curfew-guard.tsx: the sky-to-sea gradient with white copy. The lock
            // drew the theme's ink on a fixed dark purple, so under a light theme (MinUI, Kawaii,
            // which a kid profile can carry) "Time's up!" was dark on dark and could not be read.
            KidsSeaBackdrop(bubbles: [8, 22, 38, 56, 70, 84, 93], bubbleStep: 3)
            if pin, let p = state.profile, let hash = p.kid?.parentPinHash {
                PinPadView(profile: p, finish: { ok in if ok { state.unlock() }; pin = false }, hashOverride: hash, title: "Parent PIN")
            } else {
                VStack(spacing: BP.px(18)) {
                    // curfew-guard.tsx: the Harbor mark (h-24, white), "Time's
                    // up!", then the sailing-away line every kid gets, then the PIN hint or "Ask a
                    // grown-up". The TV drew an octopus emoji and skipped the middle line.
                    Image("HarborMark").resizable().renderingMode(.template).scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: BP.px(96), height: BP.px(96))
                        .accessibilityHidden(true)
                    Text("Time's up!").font(BP.display(48)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                    Text(T("The ship is sailing away. Thanks for watching with Harbor, it's time to listen to your grown-ups."))
                        .font(BP.sans(18, .medium)).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center).frame(maxWidth: BP.px(460)).fixedSize(horizontal: false, vertical: true)
                    Text(T(state.profile?.kid?.parentPinHash != nil ? "A grown-up can enter the parent PIN to keep watching." : "Ask a grown-up to switch profiles."))
                        .font(BP.sans(14)).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: BP.px(12)) {
                        if state.profile?.kid?.parentPinHash != nil { Button("Enter parent PIN") { pin = true }.buttonStyle(BPActionStyle(primary: true)) }
                        Button("Switch profile") { app.stage = .whoIsWatching }.buttonStyle(BPActionStyle())
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}
