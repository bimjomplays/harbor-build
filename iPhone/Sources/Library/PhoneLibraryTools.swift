import SwiftUI

/// The Library menu's Repair library (the TV's LibraryRepairPanel beside its library; desktop
/// settings/advanced-panel/library-repair-rows.tsx): rewrite every Stremio library item, and find
/// and remove anime saved under the wrong id. Same model, same lines, as a sheet.
struct PhoneLibraryRepairSheet: View {
    let onRepaired: () -> Void
    @StateObject private var model = LibraryRepairModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.authKey == nil {
                        card("Repair library", "Sign in to Stremio first. The repair scans only the active profile's library.", tone: BP.inkMuted) { EmptyView() }
                        card("Repair anime library", "Sign in to Stremio first. This scans the active profile's library.", tone: BP.inkMuted) { EmptyView() }
                    } else {
                        let repaired = (model.outcome?.repaired ?? 0) > 0 && model.failure == nil
                        card("Repair library", model.line, tone: repaired ? BP.live : BP.inkMuted) {
                            action(model.cta, primary: model.outcome == nil, busy: model.busy, identifier: "repair-run") {
                                Task {
                                    await model.run()
                                    onRepaired()
                                }
                            }
                        }
                        let animeTone: Color = model.showRemove ? BP.danger : (model.animePhase == "done" && model.removed > 0 ? BP.live : BP.inkMuted)
                        card("Fix corrupted anime", model.animeLine, tone: animeTone) {
                            if model.showRemove {
                                Text(verbatim: T("This deletes those entries from your library. Playing them again re-adds them."))
                                    .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                                    .foregroundStyle(BP.inkSubtle)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            action(model.animeCta, primary: model.showRemove, busy: model.animeBusy, identifier: "repair-anime") {
                                Task {
                                    let removing = model.showRemove
                                    await model.animeAction()
                                    if removing { onRepaired() }
                                }
                            }
                        }
                    }
                }
                .padding(PhoneTheme.margin)
            }
            .background(PhoneBackground())
            .navigationTitle(T("Repair library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done")) { dismiss() }.accessibilityIdentifier("repair-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentedCover("library-repair")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-repair")
    }

    private func card<Extra: View>(_ title: String, _ line: String, tone: Color, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: T(title))
                    .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(BP.ink)
                Text(verbatim: T(line))
                    .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                    .foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            extra()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneGlassPlate()
    }

    @ViewBuilder
    private func action(_ title: String, primary: Bool, busy: Bool, identifier: String, run: @escaping () -> Void) -> some View {
        let label = Label {
            Text(verbatim: T(title))
        } icon: {
            if busy { ProgressView() } else { Image(systemName: "wrench.and.screwdriver") }
        }
        Group {
            if primary {
                Button { if !busy { run() } } label: { label }.buttonStyle(.glassProminent)
            } else {
                Button { if !busy { run() } } label: { label }.buttonStyle(.glass)
            }
        }
        .disabled(busy)
        .accessibilityIdentifier(identifier)
    }
}

/// The Library menu's Letterboxd (the TV's Settings → Letterboxd, settings/letterboxd-panel.tsx in
/// public mode): a username checked against Stremboxd turns on the Library's Letterboxd tab and the
/// Letterboxd rows on Movies; Disconnect turns it off. Password sign-in stays on the desktop app.
struct PhoneLetterboxdSheet: View {
    @StateObject private var model = LetterboxdModel()
    @State private var username = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let s = model.status, s.active {
                        Text(verbatim: T("Connected as %@", s.username))
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.ink)
                            .accessibilityIdentifier("letterboxd-connected")
                        Text(verbatim: T("Your watchlist shows in the Library, and your Letterboxd rows on Movies."))
                            .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(T("Disconnect")) {
                            Task { await model.disable() }
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("letterboxd-disconnect")
                    } else {
                        Text(verbatim: T("Letterboxd username"))
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .headline))
                            .foregroundStyle(BP.ink)
                        Text(verbatim: T("The handle in your profile address, letterboxd.com/your-name."))
                            .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(T("your-name"), text: $username)
                            .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.go)
                            .onSubmit(connect)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassEffect(.regular, in: .rect(cornerRadius: PhoneTheme.radiusSmall))
                            .accessibilityLabel(Text(verbatim: T("Letterboxd username")))
                            .accessibilityIdentifier("letterboxd-username")
                        let empty = username.trimmingCharacters(in: .whitespaces).isEmpty
                        Button(action: connect) {
                            HStack(spacing: 8) {
                                if model.busy { ProgressView() }
                                Text(verbatim: model.busy ? T("Connecting…") : T("Connect"))
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(empty || model.busy)
                        .accessibilityIdentifier("letterboxd-connect")
                        Text(verbatim: T("Checks the username against Stremboxd and turns on the catalogs it finds."))
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = model.note {
                        Text(verbatim: note)
                            .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                            .foregroundStyle(model.noteOk ? BP.live : BP.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("letterboxd-note")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .phoneGlassPlate()
                .padding(PhoneTheme.margin)
            }
            .background(PhoneBackground())
            .navigationTitle(T("Letterboxd"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T("Done")) { dismiss() }.accessibilityIdentifier("letterboxd-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentedCover("letterboxd")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("letterboxd")
        .task {
            // Under fixtures there is no engine to ask; the sheet shows the connect step.
            guard !Fixtures.active || Fixtures.liveRooms else { return }
            await model.refresh()
            if username.isEmpty, let s = model.status { username = s.username }
        }
    }

    private func connect() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.busy else { return }
        Task { await model.connect(name) }
    }
}
