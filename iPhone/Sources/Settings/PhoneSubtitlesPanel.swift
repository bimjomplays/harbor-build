import SwiftUI

/// Settings → Subtitles, the TV's "Which subtitle languages, in order?" (SubtitleLanguageGrid,
/// bp-step-subtitles.tsx): settings.preferredSubLangs, the first match wins when searching online
/// subtitles. Every language is a row to switch on or off; the ones on are numbered, and Reorder drags
/// them into the order the search tries them. An empty list is allowed (the row reads Off).
struct PhoneSubtitlesPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @State private var editMode: EditMode = .inactive

    /// bp-step-subtitles.tsx COMMON: ALL_LANGUAGE_NAMES.slice(0, 24), upstream's order.
    static let common = ["English", "Spanish", "Spanish (Latin America)", "French", "German", "Italian", "Japanese", "Korean", "Chinese", "Russian", "Portuguese", "Portuguese (Brazil)", "Arabic", "Hindi", "Thai", "Vietnamese", "Turkish", "Polish", "Dutch", "Swedish", "Norwegian", "Danish", "Finnish", "Hebrew"]

    private var chosen: [String] { settings.slice.preferredSubLangs }

    /// A language chosen elsewhere but outside the common set still needs a row, or it could be
    /// switched off here but never given back.
    private var languages: [String] {
        var out: [String] = Self.common
        for lang in chosen where !out.contains(lang) { out.append(lang) }
        return out
    }

    /// What the Settings list says in the row: the first language, and how many more.
    static func summary(_ langs: [String]) -> String {
        guard let first = langs.first else { return T("Off") }
        return langs.count == 1 ? first : "\(first) +\(langs.count - 1)"
    }

    var body: some View {
        Form {
            if chosen.count > 1 {
                Section {
                    ForEach(Array(chosen.enumerated()), id: \.element) { index, lang in
                        HStack(spacing: 12) {
                            Text(verbatim: "\(index + 1)")
                                .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline).monospacedDigit())
                                .foregroundStyle(BP.accent)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(verbatim: lang)
                                .font(PhoneTheme.sans(17, .regular, relativeTo: .body))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("subs-order-\(lang)")
                        .accessibilityAction(named: T("Move up")) { shift(index, by: -1) }
                        .accessibilityAction(named: T("Move down")) { shift(index, by: 1) }
                    }
                    .onMove(perform: move)
                } header: {
                    Text(verbatim: T("Order"))
                } footer: {
                    Text(verbatim: T("First match wins when searching online subtitles. Use Reorder to drag."))
                }
            }
            Section {
                ForEach(languages, id: \.self) { lang in
                    let index: Int? = chosen.firstIndex(of: lang)
                    PhoneChoiceRow(title: lang, detail: index.map { T("Number %lld", $0 + 1) }, on: index != nil, id: "subs-lang-\(lang)") {
                        toggle(lang)
                    }
                }
            } header: {
                Text(verbatim: T("Which subtitle languages, in order?"))
            } footer: {
                if chosen.count <= 1 { Text(verbatim: T("First match wins when searching online subtitles.")) }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Subtitles"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if chosen.count > 1 { PhoneReorderButton(editMode: $editMode, id: "subs-reorder") }
        }
        .motion(.default, value: chosen)
        .accessibilityIdentifier("settings-subtitles")
    }

    private func toggle(_ lang: String) {
        PhoneFeedback.shared.selection()
        var list: [String] = chosen
        if let i = list.firstIndex(of: lang) { list.remove(at: i) } else { list.append(lang) }
        save(list)
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var list: [String] = chosen
        list.move(fromOffsets: from, toOffset: to)
        save(list)
    }

    private func shift(_ index: Int, by step: Int) {
        let target: Int = index + step
        var list: [String] = chosen
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        save(list)
    }

    private func save(_ list: [String]) {
        Task { try? await settings.patch(["preferredSubLangs": .array(list.map { .string($0) })]) }
    }
}
