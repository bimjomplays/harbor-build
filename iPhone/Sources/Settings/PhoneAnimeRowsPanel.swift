import SwiftUI

/// Settings → Anime rows, the TV's AnimeRowsPanel (lib/anime-customization): "Tune anime" (genres
/// for Top Picks, origins and already-watched titles left out), then the Anime room's groups to
/// reorder (Reorder, then drag), hide (swipe) or rename (tap). The Anime rows on Home and the room
/// apply the result on their next build.
struct PhoneAnimeRowsPanel: View {
    struct Row: Decodable, Identifiable, Equatable { var key: String; var name: String; var originalName: String; var hidden: Bool; var id: String { key } }
    /// engine actions.animeTune: components/anime-genre-picker.tsx (labels come translated).
    struct Tune: Decodable {
        struct Genre: Decodable, Identifiable { var id: Int; var label: String; var on: Bool }
        struct Origin: Decodable, Identifiable { var code: String; var label: String; var on: Bool; var id: String { code } }
        var genres: [Genre]; var origins: [Origin]; var hideWatched: Bool
    }

    @State private var tune: Tune?
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var editMode: EditMode = .inactive
    @State private var renaming: Row?
    @State private var newName = ""
    /// A layout synced from another device, or picks tuned elsewhere, while the page is open.
    @StateObject private var watch = SettingsFieldWatch { f in f.hasPrefix("anime") }

    private let genreColumns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        Form {
            if let tune { tuneSections(tune) }
            Section {
                if rows.isEmpty {
                    Text(verbatim: T(loaded ? "Open the Anime room once; its rows appear here to reorder, hide or rename." : "Loading…"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { r in rowCell(r) }
                    .onMove(perform: move)
            } header: {
                Text(verbatim: T("Rows"))
            }
            if !rows.isEmpty {
                Section {
                    Button(T("Reset rows"), role: .destructive) { call("animeRowsReset", []) }
                        .accessibilityIdentifier("anime-rows-reset")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Anime rows"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? T("Done Reordering") : T("Reorder")) {
                    PhoneFeedback.shared.selection()
                    withMotion { editMode = editMode.isEditing ? .inactive : .active }
                }
                .disabled(rows.count < 2 && !editMode.isEditing)
                .accessibilityIdentifier("anime-rows-reorder")
            }
        }
        .alert(T("Rename %@", renaming?.originalName ?? ""), isPresented: renameShown) {
            TextField(renaming?.originalName ?? "", text: $newName)
                .accessibilityIdentifier("anime-rename-field")
            Button(T("Save")) {
                if let r = renaming { call("animeRowRename", [.string(r.key), .string(newName)]) }
            }
            Button(T("Use original name")) {
                if let r = renaming { call("animeRowRename", [.string(r.key), .string("")]) }
            }
            Button(T("Cancel"), role: .cancel) {}
        }
        .task { await load() }
        .onChange(of: watch.tick) { _, _ in Task { await load() } }
        .accessibilityIdentifier("settings-anime-rows")
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    // MARK: Tune

    /// AnimeGenrePicker ("Tune anime"): genres steer Top Picks for You (settings.animeFavoriteGenres);
    /// origins and already-watched titles leave the picks. Each tap saves.
    @ViewBuilder private func tuneSections(_ t: Tune) -> some View {
        Section {
            LazyVGrid(columns: genreColumns, alignment: .leading, spacing: 8) {
                ForEach(t.genres) { g in
                    Button {
                        PhoneFeedback.shared.selection()
                        tuneCall("animeTuneGenre", [.number(Double(g.id))])
                    } label: {
                        Text(verbatim: g.label)
                            .font(PhoneTheme.sans(14, g.on ? .semibold : .regular, relativeTo: .subheadline))
                            .lines(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(g.on ? BP.on : BP.ink)
                            .background(Capsule().fill(g.on ? BP.accent : BP.glass))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(g.on ? [.isSelected] : [])
                    .accessibilityIdentifier("anime-genre-\(g.id)")
                }
            }
            .padding(.vertical, 4)
            if t.genres.contains(where: { $0.on }) {
                Button(T("Clear all")) { tuneCall("animeTuneClear", []) }
                    .accessibilityIdentifier("anime-genres-clear")
            }
        } header: {
            Text(verbatim: T("Genres you want more of"))
        }
        Section {
            ForEach(t.origins) { o in
                Toggle(isOn: Binding(get: { o.on }, set: { _ in tuneCall("animeTuneOrigin", [.string(o.code)]) })) {
                    Text(verbatim: o.label)
                }
            }
            Toggle(isOn: Binding(get: { t.hideWatched }, set: { tuneCall("animeTuneHideWatched", [.bool($0)]) })) {
                Text(verbatim: T("Hide anime I've already watched"))
            }
            .accessibilityIdentifier("anime-hide-watched")
        } header: {
            Text(verbatim: T("Hide from your picks"))
        }
    }

    // MARK: Rows

    private func rowCell(_ r: Row) -> some View {
        Button {
            newName = r.name
            renaming = r
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: r.name)
                        .font(PhoneTheme.sans(17, .medium, relativeTo: .body))
                        .foregroundStyle(r.hidden ? BP.inkSubtle : BP.ink)
                        .lines(1)
                    if r.name != r.originalName {
                        Text(verbatim: r.originalName)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                            .lines(1)
                    }
                }
                Spacer(minLength: 8)
                if r.hidden {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(verbatim: T("Hidden")))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(r.hidden ? T("Show") : T("Hide")) { call("animeRowToggleHidden", [.string(r.key)]) }
                .tint(r.hidden ? BP.accent : .gray)
        }
        .contextMenu {
            Button(r.hidden ? T("Show") : T("Hide"), systemImage: r.hidden ? "eye" : "eye.slash") {
                call("animeRowToggleHidden", [.string(r.key)])
            }
            Button(T("Rename"), systemImage: "pencil") {
                newName = r.name
                renaming = r
            }
        }
        .accessibilityIdentifier("anime-row-\(r.key)")
    }

    /// A drag as the engine's one-step moves (actions.animeRowMove ±1), shown at once.
    private func move(_ from: IndexSet, _ to: Int) {
        guard let i = from.first else { return }
        let target: Int = to > i ? to - 1 : to
        guard target != i else { return }
        let key: String = rows[i].key
        let step: Double = target > i ? 1 : -1
        rows.move(fromOffsets: from, toOffset: to)
        PhoneFeedback.shared.selection()
        let p = profile
        Task {
            var last: [Row]?
            for _ in 0..<abs(target - i) {
                if let out = try? await HarborEngine.shared.callJSON("actions.animeRowMove", [.string(p.id), .bool(p.linked), .string(key), .number(step)]),
                   let list = try? out.decode([Row].self) { last = list }
            }
            if let last { rows = last }
            HarborEngine.shared.emitEvent("harbor:anime-updated")
        }
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    private func load() async {
        let p = profile
        // A failed re-read keeps what is on screen.
        if let t: Tune = try? await HarborEngine.shared.call("actions.animeTune", [p.id, p.linked]) { tune = t }
        if let list: [Row] = try? await HarborEngine.shared.call("actions.animeRows", [p.id, p.linked]) { rows = list }
        loaded = true
    }

    /// The engine saves, raises `harbor:anime-updated` itself and returns the new picker state.
    private func tuneCall(_ fn: String, _ args: [AnyJSON]) {
        let p = profile
        Task {
            if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args),
               let next = try? out.decode(Tune.self) { tune = next }
        }
    }

    private func call(_ fn: String, _ args: [AnyJSON]) {
        let p = profile
        PhoneFeedback.shared.selection()
        Task {
            if let out = try? await HarborEngine.shared.callJSON("actions.\(fn)", [.string(p.id), .bool(p.linked)] + args),
               let list = try? out.decode([Row].self) { rows = list }
            HarborEngine.shared.emitEvent("harbor:anime-updated")
        }
    }
}
