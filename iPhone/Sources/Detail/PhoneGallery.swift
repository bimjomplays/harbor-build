import SwiftUI

/// detailRoom.gallery: TMDB's backdrops, posters and logos for a title (GalleryRow on the TV).
struct PhoneGallery: Decodable, Equatable {
    var backdrops: [String]
    var posters: [String]
    var logos: [String]

    var isEmpty: Bool { backdrops.isEmpty && posters.isEmpty && logos.isEmpty }
}

/// bp-gallery-row.tsx on the phone: a rail of backdrops, posters and logos; a tap opens the full-screen
/// lightbox on that picture, through PhoneLightboxPresenter.
struct PhoneGalleryRail: View {
    let meta: Meta
    @State private var gallery: PhoneGallery?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        // A VStack, not a Group: an empty Group has no view to run the task on, so it never loads.
        VStack(spacing: 0) {
            if let g = gallery, !g.isEmpty {
                Rail(T("Gallery"), identifier: "gallery") {
                    ForEach(Array(g.backdrops.enumerated()), id: \.offset) { i, url in
                        tile(url, kind: "backdrop", index: i, number: i + 1, width: 232, images: g.backdrops)
                    }
                    ForEach(Array(g.posters.enumerated()), id: \.offset) { i, url in
                        tile(url, kind: "poster", index: i, number: g.backdrops.count + i + 1, width: 87, images: g.posters)
                    }
                    ForEach(Array(g.logos.enumerated()), id: \.offset) { i, url in
                        tile(url, kind: "logo", index: i, number: g.backdrops.count + g.posters.count + i + 1, width: 180,
                             images: g.logos, fit: true)
                    }
                }
            }
        }
        .task(id: meta.id) {
            if let fixture = PhoneDetailFixtures.gallery() {
                gallery = fixture
                return
            }
            let p = ProfilesStore.shared.active
            // The task runs again when the page comes back on screen: a failed re-read keeps the rail.
            let g: PhoneGallery? = try? await HarborEngine.shared.call("detailRoom.gallery", [meta, p?.id ?? "default", p?.linked ?? true])
            if let g { gallery = g }
        }
    }

    private func tile(_ url: String, kind: String, index: Int, number: Int, width: CGFloat, images: [String],
                      fit: Bool = false) -> some View {
        let id = "\(kind)-\(index)"
        return Button {
            PhoneFeedback.shared.tap()
            PhoneLightboxPresenter.present(images: images, start: index, layoutDirection: layoutDirection)
        } label: {
            PhoneGalleryArt(url: url, number: number, fit: fit)
                .frame(width: width, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        // bp-gallery-row.tsx aria-label={`${title} ${i + 1}`}: the art alone has no name.
        .accessibilityLabel(Text(verbatim: "\(T("Gallery")) \(number)"))
        .accessibilityIdentifier("gallery-\(id)")
    }
}

/// A gallery picture; a `fixture:` url (PhoneDetailFixtures) draws a numbered plate instead.
struct PhoneGalleryArt: View {
    let url: String
    let number: Int
    var fit = false

    var body: some View {
        if url.hasPrefix("fixture:") {
            ZStack {
                LinearGradient(colors: [BP.accent.opacity(0.55), BP.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: "\(number)")
                    .font(PhoneTheme.display(34, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(BP.ink.opacity(0.8))
            }
        } else {
            PhoneImage(url: url, contentMode: fit ? .fit : .fill, plate: !fit)
        }
    }
}

/// Puts the lightbox over everything from UIKit: a SwiftUI fullScreenCover presented from inside the
/// detail sheet took the Close press but never went away, whether it cleared the rail's binding or
/// called `dismiss` (runs 39191886601 and 39200916761; the recording shows the press land). A
/// hosting controller presented over the topmost one, and dismissed by itself, owes nothing to the
/// views under it.
@MainActor
enum PhoneLightboxPresenter {
    static func present(images: [String], start: Int, layoutDirection: LayoutDirection) {
        guard !images.isEmpty, let top = topController() else { return }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(
            PhoneLightbox(images: images, start: start) { [weak host] in host?.dismiss(animated: true) }
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, layoutDirection)
                .preferredColorScheme(.dark)
        )
        host.view.backgroundColor = .black
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        // The lightbox hides the status bar and the home indicator: the presented controller decides.
        host.modalPresentationCapturesStatusBarAppearance = true
        top.present(host, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// The full-screen viewer: swipe between the pictures, pinch or double-tap to zoom, drag a zoomed
/// picture around, Close to leave. The count sits in a glass capsule at the top.
struct PhoneLightbox: View {
    let images: [String]
    let close: () -> Void
    @State private var index: Int
    @State private var zoomed = false
    /// Close was pressed: read by the UI test when the viewer stays up (Close's accessibility value).
    @State private var closing = false

    init(images: [String], start: Int, close: @escaping () -> Void) {
        self.images = images
        self.close = close
        _index = State(initialValue: images.indices.contains(start) ? start : 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(images.indices, id: \.self) { i in
                    PhoneZoomablePicture(url: images[i], number: i + 1, zoomed: i == index ? $zoomed : .constant(false))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onChange(of: index) { _, _ in
                zoomed = false
                PhoneFeedback.shared.selection()
            }
            topBar
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .presentedCover("lightbox")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery-lightbox")
    }

    private var topBar: some View {
        HStack {
            // The picker's Close: a glass circle button.
            Button {
                PhoneFeedback.shared.tap()
                closing = true
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(verbatim: T("Close")))
            .accessibilityValue(Text(verbatim: closing ? "closing" : ""))
            .accessibilityIdentifier("lightbox-close")
            Spacer()
            Text(verbatim: "\(index + 1) / \(images.count)")
                .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .accessibilityIdentifier("lightbox-count")
        }
        .padding(.horizontal, PhoneTheme.margin)
        .padding(.top, 8)
        .opacity(zoomed ? 0 : 1)
        .motion(.easeOut(duration: 0.2), value: zoomed)
    }
}

/// One picture of the lightbox: a pinch zooms it (1× to 4×), a double tap toggles 2.5× at the spot
/// tapped, and a drag pans it once it is zoomed (the pager has the drag otherwise).
private struct PhoneZoomablePicture: View {
    let url: String
    let number: Int
    @Binding var zoomed: Bool
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    /// The picture's room, for the zoom action (it has no tap point).
    @State private var lastSize: CGSize = CGSize(width: 390, height: 700)

    private static let maxScale: CGFloat = 4

    /// A fixture plate has no picture to give it a shape: a backdrop's or a poster's.
    private var fixtureRatio: CGFloat? {
        guard url.hasPrefix("fixture:") else { return nil }
        return url.contains("poster") ? 2.0 / 3.0 : 16.0 / 9.0
    }

    var body: some View {
        GeometryReader { geo in
            PhoneGalleryArt(url: url, number: number, fit: true)
                .aspectRatio(fixtureRatio, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                // The pinch first; a one-finger drag only pans a zoomed picture, so the pager keeps
                // the swipe between pictures at 1×.
                .gesture(magnify(geo.size))
                .gesture(pan(geo.size), including: scale > 1.01 ? .all : .subviews)
                .onTapGesture(count: 2) { location in toggleZoom(at: location, in: geo.size) }
                .onAppear { lastSize = geo.size }
                .onChange(of: geo.size) { _, size in lastSize = size }
        }
        .onChange(of: zoomed) { _, now in
            if !now, scale != 1 { reset() }
        }
        .accessibilityElement(children: .ignore)
        // BpGalleryLightbox: "Image {n}"; the count capsule reads the position.
        .accessibilityLabel(Text(verbatim: T("Image %lld", number)))
        .accessibilityAddTraits(.isImage)
        // The pinch and the double tap, for a reader who can do neither.
        .accessibilityAction(named: Text(verbatim: scale > 1.01 ? T("Zoom out") : T("Zoom in"))) {
            toggleZoom(at: CGPoint(x: lastSize.width / 2, y: lastSize.height / 2), in: lastSize)
        }
    }

    private func magnify(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(Self.maxScale, max(0.8, pinchBase * value.magnification))
                zoomed = scale > 1.01
            }
            .onEnded { _ in
                if scale <= 1.01 {
                    reset()
                } else {
                    pinchBase = scale
                    withMotion(.spring(duration: 0.3)) { offset = clamped(offset, size) }
                    panBase = offset
                }
            }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: panBase.width + value.translation.width, height: panBase.height + value.translation.height)
            }
            .onEnded { _ in
                withMotion(.spring(duration: 0.3)) { offset = clamped(offset, size) }
                panBase = offset
            }
    }

    private func toggleZoom(at point: CGPoint, in size: CGSize) {
        PhoneFeedback.shared.tap()
        if scale > 1.01 {
            reset()
            return
        }
        let target: CGFloat = 2.5
        // Keep the tapped spot under the finger.
        let dx = (size.width / 2 - point.x) * (target - 1)
        let dy = (size.height / 2 - point.y) * (target - 1)
        withMotion(.spring(duration: 0.3)) {
            scale = target
            offset = clamped(CGSize(width: dx, height: dy), size, scale: target)
        }
        pinchBase = target
        panBase = offset
        zoomed = true
    }

    private func reset() {
        withMotion(.spring(duration: 0.3)) {
            scale = 1
            offset = .zero
        }
        pinchBase = 1
        panBase = .zero
        zoomed = false
    }

    /// No further than the zoomed picture's edges.
    private func clamped(_ o: CGSize, _ size: CGSize, scale s: CGFloat? = nil) -> CGSize {
        let k = s ?? scale
        let maxX = max(0, size.width * (k - 1) / 2)
        let maxY = max(0, size.height * (k - 1) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }
}
