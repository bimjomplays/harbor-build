import SwiftUI

/// Settings → Stream priority, the TV's "Sources first" (StreamPriorityPanel) with the whole order:
/// the stream addons in the order their sources lead the stream picker. The engine keeps it as
/// settings.streamPriority ([{key, name}], engine/streams.ts prioritisedOrder): an addon in the list
/// ranks by its place, the rest follow in installed order. Tap an addon to put it first, or drag
/// (Reorder) to place any of them; Installed order clears it. The TV's "one first" is the same list.
@MainActor
struct PhoneStreamPriorityPanel: View {
    struct Entry: Decodable, Identifiable, Equatable {
        var key: String
        var name: String
        var first: Bool
        var id: String { key }
    }

    @EnvironmentObject private var settings: SettingsBridge
    /// The addons in the order they lead the picker.
    @State private var entries: [Entry] = []
    /// Whether the profile has an order of its own (else the installed order stands).
    @State private var custom = false
    @State private var loaded = false
    @State private var editMode: EditMode = .inactive

    /// Under `--fixtures` there is no engine to ask for addons.
    private static let fixtureAddons: [Entry] = [
        Entry(key: "fixture.streams", name: "Fixture Streams", first: false),
        Entry(key: "fixture.torrents", name: "Fixture Torrents", first: false),
        Entry(key: "fixture.debrid", name: "Fixture Debrid", first: false),
    ]

    /// engine prioritisedOrder: an addon ranks by its place in the saved list, else after all of
    /// them in installed order.
    static func arranged(_ installed: [Entry], saved: [String]) -> [Entry] {
        var rank: [String: Int] = [:]
        for (i, key) in saved.enumerated() where rank[key] == nil { rank[key] = i }
        return installed.enumerated()
            .map { (rank: rank[$0.element.key] ?? saved.count + $0.offset, entry: $0.element) }
            .sorted { $0.rank < $1.rank }
            .map { $0.entry }
    }

    private var who: (id: String, linked: Bool, authKey: String?) {
        let p = ProfilesStore.shared.active
        let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        return (p?.id ?? "default", p?.linked ?? true, authKey)
    }

    var body: some View {
        Form {
            Section {
                if loaded && entries.isEmpty {
                    Text(verbatim: T("No stream addons found."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("priority-empty")
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                }
                .onMove(perform: move)
            } header: {
                Text(verbatim: T("Sources first"))
            } footer: {
                Text(verbatim: T("The addon at the top leads the stream list and the rest follow in this order. Tap one to put it first, or use Reorder to drag."))
            }
            if custom {
                Section {
                    Button(T("Installed order")) { reset() }
                        .accessibilityIdentifier("priority-reset")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Stream priority"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if entries.count > 1 { PhoneReorderButton(editMode: $editMode, id: "priority-reorder") }
        }
        .task { await load() }
        .accessibilityIdentifier("settings-priority")
    }

    private func row(_ entry: Entry, index: Int) -> some View {
        let leads: Bool = custom && index == 0
        return Button {
            guard index > 0 || !custom else { return }
            PhoneFeedback.shared.selection()
            var list: [Entry] = entries
            list.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
            save(list)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: "\(index + 1)")
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline).monospacedDigit())
                    .foregroundStyle(BP.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                        .font(PhoneTheme.sans(17, .regular, relativeTo: .body))
                        .foregroundStyle(BP.ink)
                    if leads {
                        Text(verbatim: T("Its sources lead the stream list"))
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if leads {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BP.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("priority-row-\(entry.key)")
        .accessibilityValue(leads ? T("First") : "")
        .accessibilityAction(named: T("Move up")) { shift(index, by: -1) }
        .accessibilityAction(named: T("Move down")) { shift(index, by: 1) }
    }

    // MARK: engine

    private func load() async {
        let installed: [Entry]
        if PhoneSettingsFixtures.active {
            installed = Self.fixtureAddons
        } else {
            let w = who
            let args: [AnyJSON] = [.string(w.id), .bool(w.linked), w.authKey.map { AnyJSON.string($0) } ?? AnyJSON.null]
            installed = (try? await HarborEngine.shared.call("streamsRoom.priorityList", args)) ?? []
        }
        let saved: [String] = await savedKeys()
        entries = Self.arranged(installed, saved: saved)
        custom = !saved.isEmpty
        loaded = true
    }

    /// settings.streamPriority as the profile has it (the slice the bridge keeps does not carry it).
    private func savedKeys() async -> [String] {
        let w = who
        guard let all = try? await HarborEngine.shared.callJSON("settings.activate", [.string(w.id), .bool(w.linked)]),
              case .object(let fields) = all, case .array(let list)? = fields["streamPriority"] else { return [] }
        var keys: [String] = []
        for item in list {
            if case .object(let one) = item, case .string(let key)? = one["key"] { keys.append(key) }
        }
        return keys
    }

    private func save(_ list: [Entry]) {
        entries = list
        custom = true
        let value: [AnyJSON] = list.map { .object(["key": .string($0.key), "name": .string($0.name)]) }
        Task { try? await settings.patch(["streamPriority": .array(value)]) }
    }

    private func reset() {
        PhoneFeedback.shared.selection()
        custom = false
        Task {
            try? await settings.patch(["streamPriority": .array([])])
            await load()
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var list: [Entry] = entries
        list.move(fromOffsets: from, toOffset: to)
        guard list != entries else { return }
        save(list)
    }

    /// VoiceOver's Move up / Move down.
    private func shift(_ index: Int, by step: Int) {
        let target: Int = index + step
        guard entries.indices.contains(target) else { return }
        var list: [Entry] = entries
        list.swapAt(index, target)
        save(list)
    }
}
