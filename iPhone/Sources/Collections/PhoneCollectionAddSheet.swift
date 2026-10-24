import SwiftUI

/// "Add titles" on the viewer's own collection (community-editor's search on the TV): a search over
/// films and shows (collectionsRoom.searchTitles: TMDB with a key, Cinemeta without); a row adds its
/// title or, ticked, takes it out again. With no query it lists what the collection holds.
struct PhoneCollectionAddSheet: View {
    let ref: String
    let close: () -> Void

    @ObservedObject private var store = PhoneCollectionsStore.shared
    @State private var query = ""
    @State private var results: [Meta] = []
    @State private var searching = false

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    Section {
                        ForEach(store.card(ref)?.items ?? []) { item in
                            row(item.meta)
                        }
                    } header: {
                        Text(verbatim: T("In this collection"))
                    }
                } else if searching && results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(verbatim: T("Searching..."))
                    }
                    .foregroundStyle(BP.inkMuted)
                } else if results.isEmpty && searchText.count >= 2 {
                    Text(verbatim: T("No matches"))
                        .foregroundStyle(BP.inkMuted)
                } else {
                    ForEach(results) { meta in row(meta) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PhoneBackground())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(verbatim: T("Search movies, shows, and manga to add")))
            .navigationTitle(store.card(ref)?.name ?? T("Add titles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done"), action: close)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("collection-add-done")
                }
            }
            .task(id: searchText) { await search(searchText) }
        }
        .tint(BP.accent)
        .presentedCover("collection-add")
        .accessibilityIdentifier("collection-add-sheet")
    }

    private func row(_ meta: Meta) -> some View {
        let added = store.contains(meta.id, in: ref)
        return Button {
            PhoneFeedback.shared.selection()
            Task { await store.toggle(meta, in: ref) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BP.panel)
                    PhoneImage(url: meta.poster)
                }
                .frame(width: 36, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: meta.name)
                        .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                    if let year = meta.releaseInfo, !year.isEmpty {
                        Text(verbatim: year)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkMuted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(added ? BP.accent : BP.inkMuted)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(added ? [.isSelected] : [])
        .accessibilityIdentifier("collection-add-\(meta.id)")
    }

    /// community-editor: a query of two letters or more, after a short pause in the typing.
    private func search(_ q: String) async {
        guard q.count >= 2 else {
            results = []
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let p = ProfilesStore.shared.active
        let got: LossyArray<Meta>? = try? await HarborEngine.shared.call("collectionsRoom.searchTitles", [q, p?.id ?? "default", p?.linked ?? true])
        guard !Task.isCancelled else { return }
        results = (got?.wrappedValue ?? []).filter(PhoneCollectionsStore.collectable)
    }
}
