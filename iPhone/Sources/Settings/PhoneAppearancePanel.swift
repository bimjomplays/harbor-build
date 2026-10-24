import SwiftUI

/// Settings → Appearance, the TV's AppearancePanel for touch (views/settings/theme-panel.tsx): the
/// presets as swatch tiles, grouped Built-in / Featured, then the Typography pairs, then how poster
/// cards are drawn. A pick is saved for the profile and syncs as its `theme` section. This page
/// redraws in the new theme at once; the app behind the sheet repaints when the sheet closes
/// (PhoneRootView holds its rebuild while a sheet is up, so the sheet is not torn down).
struct PhoneAppearancePanel: View {
    @ObservedObject private var theme = ThemeStore.shared
    @EnvironmentObject private var settings: SettingsBridge
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2) }

    var body: some View {
        Form {
            if let s = theme.state {
                ForEach(["Built-in", "Featured"], id: \.self) { group in
                    let presets: [ThemeStore.Preset] = s.presets.filter { $0.category == group }
                    if !presets.isEmpty {
                        Section {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(presets) { p in tile(p, active: s.active == p.id) }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        } header: {
                            Text(verbatim: T(group))
                        } footer: {
                            if group == "Built-in" {
                                Text(verbatim: T("Pick a look. Every color and surface updates instantly."))
                            }
                        }
                    }
                }
                Section {
                    ForEach(s.fontPairs) { f in fontRow(f, active: f.id == s.pickedFontPair) }
                } header: {
                    Text(verbatim: T("Typography"))
                } footer: {
                    // applyTheme: a preset with its own pairing (Stremio, Crunchy, Noir, MinUI) wins over this pick.
                    if s.presetOwnsFont, let name = s.presets.first(where: { $0.id == s.active })?.name {
                        Text(verbatim: T("%@ uses its own pairing while it is the theme.", name))
                    } else {
                        Text(verbatim: T("Pick a display and body pairing."))
                    }
                }
                Section {
                    // bp-tile.tsx showTitle = !settings.hidePosterTitles.
                    Toggle(isOn: posterTitles) {
                        Text(verbatim: T("Titles under posters"))
                    }
                    .accessibilityIdentifier("appearance-poster-titles")
                } header: {
                    Text(verbatim: T("Cards"))
                } footer: {
                    Text(verbatim: T("The name of each title under its poster. The theme picks the cards' shape."))
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if theme.state == nil { await theme.load() } }
        .accessibilityIdentifier("settings-appearance")
    }

    private var posterTitles: Binding<Bool> {
        Binding(
            get: { settings.slice.hidePosterTitles != true },
            set: { on in
                PhoneFeedback.shared.selection()
                Task { try? await settings.patch(["hidePosterTitles": .bool(!on)]) }
            }
        )
    }

    /// color-theme-body.tsx tile: the preset's own colours, a swatch dot that carries the check.
    private func tile(_ p: ThemeStore.Preset, active: Bool) -> some View {
        let base = ThemeStore.color(p.swatch.first ?? [0, 0, 0, 1])
        let top = ThemeStore.color(p.swatch.count > 1 ? p.swatch[1] : [0, 0, 0, 1])
        let ink = ThemeStore.color(p.swatch.count > 2 ? p.swatch[2] : [1, 1, 1, 1])
        return Button {
            guard !active else { return }
            PhoneFeedback.shared.selection()
            Task { await theme.select(p.id) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                base
                VStack(spacing: 0) {
                    LinearGradient(colors: [top, base], startPoint: .top, endPoint: .bottom).frame(height: 40)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: p.name)
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(ink)
                        .lines(1)
                    Text(verbatim: p.blurb)
                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                        .foregroundStyle(ink.opacity(0.7))
                        .lines(2)
                }
                .padding(10)
                Circle().fill(ink)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(base)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous)
                .strokeBorder(active ? BP.ink : BP.edge, lineWidth: active ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: p.name))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("theme-\(p.id)")
    }

    /// font-grid.tsx tile: the name, "Harbor" in the display face, the pangram in the body face.
    /// (BP's sizes are TV px, scaled by BP.k: 14 and 8 draw at about 24 and 13 points.)
    private func fontRow(_ f: ThemeStore.FontPair, active: Bool) -> some View {
        let display = BPThemeTokens.DisplayFace(rawValue: f.faces.display) ?? .system
        let sans = BPThemeTokens.SansFace(rawValue: f.faces.sans) ?? .system
        return Button {
            guard !active else { return }
            PhoneFeedback.shared.selection()
            Task { await theme.setFontPair(f.id) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: f.name)
                        .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Harbor").font(BP.display(14, .medium, face: display))
                    Text(verbatim: "The quick brown fox jumps over the lazy dog")
                        .font(BP.sans(8, .regular, face: sans))
                        .foregroundStyle(.secondary)
                        .lines(1)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(BP.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The name and blurb, not the "Harbor" and pangram samples drawn in the faces.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(f.name), \(f.blurb)"))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("font-\(f.id)")
    }
}
