import SwiftUI
import UIKit

/// An addon's page (views/addons/addon-detail.tsx, AddonDetailView on the TV), pushed from the
/// Addons screen: header, Install / Configure & install / Install default / Remove / Reconfigure,
/// the catalogs it adds (Browse catalogs opens them as the poster grid), documentation, the
/// manifest facts with the masked URL (Reveal, Copy), More like this and Recommended for you. The
/// stremio-addons.net page and its rating page open in Safari over the app.
struct PhoneAddonDetailPage: View {
    let addonId: String
    @ObservedObject var model: AddonsModel
    @EnvironmentObject private var nav: PhoneNavigator
    @Environment(\.dismiss) private var dismiss

    struct Detail: Decodable {
        struct Catalog: Decodable, Hashable { var name: String; var type: String }
        struct Stat: Decodable, Hashable { var label: String; var value: String; var mono: Bool }
        struct Community: Decodable { var stars: Double; var slug: String; var siteUrl: String; var rateUrl: String }
        var card: AddonsModel.Card
        var eyebrow: String
        var version: String?
        var types: [String]
        var resources: [String]
        var catalogs: [Catalog]
        var stats: [Stat]
        var configurable: Bool
        var configurationRequired: Bool
        var adult: Bool
        var configureUrl: String
        var stremioUrl: String
        var maskedUrl: String
        var community: Community?
        var risingStars: Double?
        var documentation: String?
        var related: [AddonsModel.Card]
        var recommended: [AddonsModel.Card]
    }

    @State private var detail: Detail?
    @State private var loading = true
    @State private var failed = false
    @State private var busy: String?
    @State private var revealed = false
    @State private var docOpen = false
    @State private var sheet: PhoneAddonsSheet?
    @State private var external: PhoneExternalLink?

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if failed {
                ErrorPlate(title: T("Couldn't load this addon"), retry: { Task { await load() } })
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PhoneBackground())
        .navigationTitle(detail?.card.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $sheet, onDismiss: { Task { await load() } }) { which in
            switch which {
            case .install(let target, let scan):
                PhoneAddonInstallSheet(target: target, model: model, startScan: scan) { sheet = nil }
            case .reorder, .ageGate:
                EmptyView()
            }
        }
        .sheet(item: $external) { link in PhoneSafariView(url: link.url).ignoresSafeArea() }
        .phoneAddonToasts(model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addon-page")
    }

    private func load() async {
        let again = detail != nil
        loading = true; defer { loading = false }
        let d: Detail? = try? await AddonsEngine.call("addonsManager.detail", [addonId, model.authKey, model.adultAllowed])
        guard let d else {
            // RemoteOrLocalDetail: an addon known only from its install has nothing left once removed.
            if busy == "remove" { dismiss() } else if !again { failed = true }
            return
        }
        failed = false
        detail = d
    }

    private func content(_ d: Detail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(d)
                actions(d)
                catalogs(d)
                if let doc = d.documentation, !doc.isEmpty { documentation(doc) }
                projectInfo(d)
                related(T("More like this"), d.related)
                related(T("Recommended for you"), d.recommended)
            }
            .padding(.vertical, 16)
        }
        .refreshable { await load() }
    }

    // MARK: header and actions

    private func header(_ d: Detail) -> some View {
        let c = d.card
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                PhoneAddonLogo(url: c.logo, name: c.name, side: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: d.eyebrow)
                        .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                    Text(verbatim: c.name)
                        .font(PhoneTheme.display(28, .semibold, relativeTo: .title))
                        .foregroundStyle(BP.ink)
                        .lines(2)
                        .accessibilityIdentifier("addon-page-name")
                    HStack(spacing: 10) {
                        if let v = d.version, !v.isEmpty { Text(verbatim: "v\(v)").foregroundStyle(BP.inkSubtle) }
                        if c.stars > 0 { Label(clampedInt(c.stars).formatted(), systemImage: "star.fill").foregroundStyle(BP.accent) }
                        if let r = d.risingStars, r > 0 {
                            Text(clampedInt(r) == 1 ? T("Rising · +%lld star in 24h", clampedInt(r)) : T("Rising · +%lld stars in 24h", clampedInt(r)))
                                .foregroundStyle(BP.live)
                        }
                    }
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                }
            }
            HStack(spacing: 8) {
                if d.adult { badge(T("Adult"), "exclamationmark.triangle") }
                if d.configurable { badge(T("Configurable"), "slider.horizontal.3") }
                if !c.enabled && c.installed { badge(T("Off"), "poweroff") }
            }
            if !c.description.isEmpty {
                Text(verbatim: c.description)
                    .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                    .foregroundStyle(BP.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    private func badge(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(PhoneTheme.sans(12, .bold, relativeTo: .caption))
            .foregroundStyle(BP.inkMuted)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    private func actions(_ d: Detail) -> some View {
        let c = d.card
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { primary(d) } label: { primaryLabel(d).frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(c.installed && busy == nil ? BP.danger : BP.accent)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("addon-page-primary")
                if busy == nil && c.installed && d.configurable && !d.configureUrl.isEmpty {
                    Button { sheet = .install(target(d, mode: .manage), scan: false) } label: {
                        Label(T("Reconfigure"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("addon-page-reconfigure")
                }
                // An addon that requires configuration has nothing sensible to install by default.
                if busy == nil && !c.installed && d.configurable && !d.configurationRequired {
                    Button(T("Install default")) { Task { await install(c, useDefault: true) } }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("addon-page-install-default")
                }
            }
            .controlSize(.large)
            if let comm = d.community {
                HStack(spacing: 10) {
                    Button { openExternal(comm.siteUrl) } label: { Label(T("On Stremio-Addons"), systemImage: "arrow.up.right.square") }
                    Button { openExternal(comm.rateUrl) } label: { Label(T("Rate"), systemImage: "star") }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, PhoneTheme.margin)
    }

    @ViewBuilder private func primaryLabel(_ d: Detail) -> some View {
        if busy == "remove" {
            Label(T("Removing"), systemImage: "hourglass")
        } else if busy == "install" {
            Label(T("Installing"), systemImage: "hourglass")
        } else if d.card.installed {
            Label(T("Remove"), systemImage: "trash")
        } else if d.configurable {
            Label(T("Configure & install"), systemImage: "slider.horizontal.3")
        } else {
            Label(T("Install"), systemImage: "plus")
        }
    }

    private func target(_ d: Detail, mode: AddonsModel.ConfigureTarget.Mode) -> AddonsModel.ConfigureTarget {
        AddonsModel.ConfigureTarget(mode: mode, name: d.card.name, logo: d.card.logo, configureUrl: d.configureUrl,
                                    manageId: mode == .manage ? d.card.addonId : nil)
    }

    private func primary(_ d: Detail) {
        guard busy == nil else { return }
        let c = d.card
        if c.installed { Task { await remove(c) } }
        else if d.configurable { sheet = .install(target(d, mode: .configure), scan: false) }
        else { Task { await install(c, useDefault: false) } }
    }

    // Busy until the page has read the addon again, so the old button can't be pressed twice.
    private func install(_ c: AddonsModel.Card, useDefault: Bool) async {
        guard busy == nil else { return }
        busy = "install"
        let setup = await model.install(c, useDefault: useDefault)
        if let setup { busy = nil; sheet = .install(setup, scan: false); return }
        await load()
        busy = nil
    }

    private func remove(_ c: AddonsModel.Card) async {
        guard busy == nil else { return }
        busy = "remove"
        await model.uninstall(c)
        await load()
        busy = nil
    }

    private func openExternal(_ link: String) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        external = PhoneExternalLink(url: url)
    }

    // MARK: sections

    @ViewBuilder private func catalogs(_ d: Detail) -> some View {
        if !d.catalogs.isEmpty {
            let browseAction: (() -> Void)? = d.card.installed ? { browse(d.card) } : nil
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: T("Catalogs"), actionTitle: d.card.installed ? T("Browse") : nil,
                              action: browseAction, actionIdentifier: "addon-page-browse")
                VStack(spacing: 0) {
                    ForEach(Array(d.catalogs.enumerated()), id: \.offset) { i, cat in
                        if i > 0 { Divider().padding(.leading, 16) }
                        HStack {
                            Text(verbatim: cat.name)
                                .font(PhoneTheme.sans(16, .medium, relativeTo: .body))
                                .foregroundStyle(BP.ink)
                            Spacer()
                            Text(verbatim: T(cat.type.capitalized))
                                .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                                .foregroundStyle(BP.inkSubtle)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .phoneGlassPlate()
                .padding(.horizontal, PhoneTheme.margin)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("addon-page-catalogs")
            }
        }
    }

    /// The addon's catalogs as the poster grid (the page an installed addon's brand tile opens).
    private func browse(_ c: AddonsModel.Card) {
        nav.push(PhoneRoute.addon(base: PhoneAddonLink.base(of: c.transportUrl), name: c.name, logo: c.logo))
    }

    private func documentation(_ doc: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Documentation"))
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.markdown(doc))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .lineLimit(docOpen ? nil : 8)
                    .fixedSize(horizontal: false, vertical: true)
                Button(docOpen ? T("Show less") : T("Show full documentation")) { withMotion(.snappy) { docOpen.toggle() } }
                    .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(BP.accent)
                Text(T("From stremio-addons.net"))
                    .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                    .foregroundStyle(BP.inkSubtle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .phoneGlassPlate()
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    /// stremio-addons.net documentation is markdown; links and emphasis render, the rest stays as typed.
    private static func markdown(_ doc: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: doc, options: options)) ?? AttributedString(doc)
    }

    private func projectInfo(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: T("Project information"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(d.stats, id: \.self) { stat in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: stat.label)
                            .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                            .foregroundStyle(BP.inkSubtle)
                        Spacer(minLength: 12)
                        Text(verbatim: stat.value)
                            .font(stat.mono ? PhoneTheme.sans(14, .medium, relativeTo: .subheadline).monospaced() : PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                            .foregroundStyle(BP.ink)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 16)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(T("Manifest URL"))
                            .font(PhoneTheme.sans(12, .semibold, relativeTo: .caption))
                            .textCase(.uppercase)
                            .foregroundStyle(BP.inkSubtle)
                        Spacer()
                        Button { revealed.toggle() } label: {
                            Label(revealed ? T("Hide") : T("Reveal"), systemImage: revealed ? "eye.slash" : "eye")
                        }
                        .accessibilityIdentifier("addon-page-reveal")
                        Button {
                            UIPasteboard.general.string = d.stremioUrl
                            PhoneToaster.shared.show(T("Link copied"))
                        } label: {
                            Label(T("Copy"), systemImage: "doc.on.doc")
                        }
                    }
                    .font(PhoneTheme.sans(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(BP.accent)
                    // The manifest URL can hold an account's keys: masked until asked for.
                    Text(verbatim: revealed ? d.stremioUrl : d.maskedUrl)
                        .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote).monospaced())
                        .foregroundStyle(BP.inkMuted)
                        .textSelection(.enabled)
                        .lineLimit(revealed ? nil : 1)
                        .accessibilityIdentifier("addon-page-url")
                }
                .padding(16)
            }
            .phoneGlassPlate()
            .padding(.horizontal, PhoneTheme.margin)
        }
    }

    @ViewBuilder private func related(_ title: String, _ cards: [AddonsModel.Card]) -> some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PhoneTheme.railGap) {
                        ForEach(cards) { c in
                            Button { nav.push(PhoneAddonRoute.detail(id: c.addonId)) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    PhoneAddonLogo(url: c.logo, name: c.name, side: 44)
                                    Text(verbatim: c.name)
                                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                                        .foregroundStyle(BP.ink)
                                        .lines(1)
                                    Text(verbatim: c.description)
                                        .font(PhoneTheme.sans(12, .regular, relativeTo: .caption))
                                        .foregroundStyle(BP.inkMuted)
                                        .lines(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .frame(width: 180, height: 140, alignment: .topLeading)
                                .phoneGlassPlate()
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, PhoneTheme.margin)
                }
            }
        }
    }
}
