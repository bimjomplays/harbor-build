import SwiftUI
import WebKit

/// bp-trailer.tsx on the phone: the YouTube clip plays inline in a sheet.
/// The TV has no web view and sends the viewer to the YouTube app or a QR code (TrailerView); a
/// phone can embed the player, so the clip plays right here and "Open in YouTube" stays as the
/// way out. Nothing plays until the viewer presses play, and the clip stops when the sheet goes.
struct PhoneTrailerSheet: View {
    let ytId: String
    let title: String
    var clipName: String?
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhoneYouTubePlayer(ytId: ytId)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusMedium, style: .continuous))
                        .accessibilityLabel(Text(verbatim: clipName.flatMap { $0.isEmpty ? nil : $0 } ?? T("Watch trailer")))
                        .accessibilityIdentifier("trailer-player")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: title)
                            .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                            .foregroundStyle(BP.ink)
                            .lines(2)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("trailer-title")
                        if let c = clipName, !c.isEmpty {
                            Text(verbatim: c)
                                .font(PhoneTheme.sans(15, .medium, relativeTo: .subheadline))
                                .foregroundStyle(BP.inkMuted)
                                .lines(1)
                        }
                    }
                    Button {
                        PhoneFeedback.shared.tap()
                        if let url = URL(string: "https://www.youtube.com/watch?v=\(ytId)") { openURL(url) }
                    } label: {
                        Label(T("Open in YouTube"), systemImage: "arrow.up.forward.app")
                            .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("trailer-youtube")
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(T("Watch trailer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done"), action: close).accessibilityIdentifier("trailer-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentedCover("dialog")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trailer-sheet")
    }
}

/// YouTube's embedded player in a WKWebView: plays inline (never jumps to full screen by itself),
/// waits for a tap (no autoplay), keeps no cookies, and sends any link out of the player (the
/// YouTube logo, "Watch on YouTube") to the system instead of navigating inside the sheet. The page
/// is torn down with the view, so no audio carries on after the sheet is dismissed.
struct PhoneYouTubePlayer: UIViewRepresentable {
    let ytId: String

    /// A YouTube id is letters, digits, "-" and "_": anything else never reaches the page.
    private var safeId: String {
        String(ytId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(Character.init))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        load(web, context: context)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loadedId != safeId { load(web, context: context) }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.pauseAllMediaPlayback(completionHandler: nil)
        web.closeAllMediaPresentations(completionHandler: nil)
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.loadHTMLString("", baseURL: nil)
    }

    private func load(_ web: WKWebView, context: Context) {
        let id = safeId
        context.coordinator.loadedId = id
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&rel=0&modestbranding=1&autoplay=0"
          title="YouTube" allow="encrypted-media; picture-in-picture; fullscreen" allowfullscreen
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
        // YouTube's embed wants a referrer naming the app (its API terms: https://<bundle id>);
        // the player can refuse a page with no origin at all.
        let origin = URL(string: "https://\(Bundle.main.bundleIdentifier ?? AppID.base)")
        web.loadHTMLString(html, baseURL: origin)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedId = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The player's own frame and its loads stay; a tap on a link leaves for the system.
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return .cancel
            }
            return .allow
        }

        /// target="_blank" links (the player's "Watch on YouTube") ask for a new window.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            return nil
        }
    }
}
