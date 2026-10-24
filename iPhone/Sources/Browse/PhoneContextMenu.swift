import SwiftUI

/// The long-press menu on a poster or card: play (where the screen can start a title), details, watchlist,
/// mark watched (films), add to collection (films and shows), share. A Continue Watching card also offers
/// "Remove from Continue Watching". These are the TV quick panel's title actions that make sense on a
/// phone; Details opens the title page, where Rate lives too.
private struct PhoneContextMenu: ViewModifier {
    let meta: Meta
    let fromContinueWatching: Bool
    let open: (Meta) -> Void
    /// Starts the title (its page, playing at once); nil where the screen has no Play.
    let play: ((Meta) -> Void)?

    @ObservedObject private var marks = CardMarksStore.shared
    @ObservedObject private var actions = PhoneTitleActions.shared
    /// "Add to collection" → "New collection": the name prompt (PhoneNewCollectionPrompt).
    @State private var naming = false

    func body(content: Content) -> some View {
        let mark: CardMarks? = marks.byId[meta.id]
        let saved = actions.isSaved(meta, marks: mark)
        let watched = actions.isWatched(meta, marks: mark)
        content.contextMenu {
            if let play {
                Button {
                    PhoneFeedback.shared.tap()
                    play(meta)
                } label: {
                    Label(T("Play"), systemImage: "play.fill")
                }
            }
            Button {
                PhoneFeedback.shared.tap()
                open(meta)
            } label: {
                Label(T("Details"), systemImage: "info.circle")
            }
            Button {
                PhoneFeedback.shared.tap()
                let current = saved
                let title = meta
                Task { await PhoneTitleActions.shared.toggleSaved(title, current: current) }
            } label: {
                Label(saved ? T("Remove from Watchlist") : T("Add to Watchlist"),
                      systemImage: saved ? "bookmark.slash" : "bookmark")
            }
            if actions.canMarkWatched(meta) {
                Button {
                    PhoneFeedback.shared.tap()
                    let current = watched
                    let title = meta
                    Task { await PhoneTitleActions.shared.toggleWatched(title, current: current) }
                } label: {
                    Label(watched ? T("Mark as Unwatched") : T("Mark as Watched"),
                          systemImage: watched ? "eye.slash" : "checkmark.circle")
                }
            }
            if PhoneCollectionsStore.collectable(meta) {
                PhoneAddToCollectionMenu(meta: meta) { naming = true }
            }
            // As the title page's Share: the IMDb page when the id is one, else the name.
            if meta.id.hasPrefix("tt"), let url = URL(string: "https://www.imdb.com/title/\(meta.id)/") {
                ShareLink(item: url, subject: Text(verbatim: meta.name)) { Label(T("Share"), systemImage: "square.and.arrow.up") }
            } else {
                ShareLink(item: meta.name) { Label(T("Share"), systemImage: "square.and.arrow.up") }
            }
            if fromContinueWatching {
                Button(role: .destructive) {
                    PhoneFeedback.shared.tap()
                    let id = meta.id
                    Task { await PhoneTitleActions.shared.removeFromContinue(id) }
                } label: {
                    Label(T("Remove from Continue Watching"), systemImage: "xmark.circle")
                }
            }
        }
        .modifier(PhoneNewCollectionPrompt(meta: meta, isPresented: $naming))
        .onAppear { PhoneCollectionsStore.shared.ensureLoaded() }
    }
}

extension View {
    /// Long-press menu for a title tile (see `PhoneContextMenu`).
    func phoneContextMenu(for meta: Meta, fromContinueWatching: Bool = false, open: @escaping (Meta) -> Void,
                          play: ((Meta) -> Void)? = nil) -> some View {
        modifier(PhoneContextMenu(meta: meta, fromContinueWatching: fromContinueWatching, open: open, play: play))
    }
}
