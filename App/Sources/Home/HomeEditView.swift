import SwiftUI

/// Edit Home: the active profile's Home layout, made for the Siri remote. The left
/// column holds the page's actions (Add a row, the hero, Reset to default, Done); the right one lists
/// the rows in Home's order, each with Move up, Move down and Remove (and Split into rows for a whole
/// page's rows). Nothing is typed: rows are added from a source picker, the hero from the same
/// sources. Every change is saved at once; Menu or Done closes and Home re-reads.
struct HomeEditView: View {
    @StateObject private var model: HomeEditModel
    @Environment(\.dismiss) private var dismiss
    /// "add", "hero", "reset", "reset-yes", "done", or "<action>:<spec id>" on a row.
    @FocusState private var focus: String?
    @State private var picker: HomeSourcePickerView.Mode?
    @State private var resetAsk = false
    /// Where the ring goes once the picker has closed (the row just added, or Hero).
    @State private var afterPicker: String?

    init(source: HomeLayoutBrowseSource) {
        _model = StateObject(wrappedValue: HomeEditModel(source: source))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            HStack(alignment: .top, spacing: BP.px(36)) {
                sidebar
                    .frame(width: BP.px(320), alignment: .leading)
                    .focusSection()
                rows
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(52))
        }
        .task { await model.loadSources() }
        .onAppear { ring("add", after: 0.25) }
        .onExitCommand {
            if resetAsk { resetAsk = false; ring("reset") } else { dismiss() }
        }
        .fullScreenCover(item: $picker, onDismiss: {
            let next: String? = afterPicker
            afterPicker = nil
            ring(next ?? "add", after: 0.2)
        }) { mode in
            HomeSourcePickerView(model: model, mode: mode) { id in afterPicker = id }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(verbatim: T("Edit Home")).font(BP.display(32)).foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: model.profileName.isEmpty ? T("Saved on this Apple TV") : T("Saved for %@", model.profileName))
                .font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
            Text(verbatim: T("Continue Watching and Live TV lead Home; the rows follow in this order."))
                .font(BP.sans(14)).foregroundStyle(BP.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, BP.px(10))

            sideButton(T("Add a row"), icon: "plus", id: "add", testId: "home-edit-add", primary: true) {
                picker = .row
            }

            VStack(alignment: .leading, spacing: BP.px(6)) {
                sideButton(T("Hero: %@", model.heroTitle), icon: "sparkles.rectangle.stack", id: "hero", testId: "home-edit-hero") {
                    picker = .hero
                }
                Text(verbatim: model.heroNote).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, BP.px(6))

            if resetAsk {
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    Text(verbatim: T("Put Home back the way it came?")).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                    HStack(spacing: BP.px(8)) {
                        Button(T("Reset")) {
                            model.reset()
                            resetAsk = false
                            ring("add")
                        }
                        .buttonStyle(BPActionStyle(primary: true))
                        .focused($focus, equals: "reset-yes")
                        .accessibilityIdentifier("home-edit-reset-confirm")
                        Button(T("Cancel")) { resetAsk = false; ring("reset") }
                            .buttonStyle(BPActionStyle())
                            .accessibilityIdentifier("home-edit-reset-cancel")
                    }
                }
                .padding(.top, BP.px(6))
            } else {
                // Dimmed, not disabled, on the default layout: a disabled button drops the ring.
                sideButton(T("Reset to default"), icon: "arrow.counterclockwise", id: "reset", testId: "home-edit-reset", dimmed: model.isDefault) {
                    guard !model.isDefault else { return }
                    resetAsk = true
                    ring("reset-yes")
                }
                .padding(.top, BP.px(6))
            }

            sideButton(T("Done"), icon: "checkmark", id: "done", testId: "home-edit-done") { dismiss() }
                .padding(.top, BP.px(18))
        }
    }

    private func sideButton(_ title: String, icon: String, id: String, testId: String, primary: Bool = false,
                            dimmed: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle(primary: primary, busy: dimmed))
        .focused($focus, equals: id)
        .accessibilityIdentifier(testId)
    }

    // MARK: Rows

    private var rows: some View {
        let lines: [HomeEditModel.Line] = model.lines
        return VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                Text(verbatim: T("Rows on Home")).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                Text(verbatim: "\(lines.count)").font(BP.sans(15, .semibold)).foregroundStyle(BP.inkSubtle)
                Spacer(minLength: 0)
                if model.loadingSources { ProgressView().tint(BP.inkMuted).scaleEffect(0.7) }
            }
            if lines.isEmpty {
                Text(verbatim: T("Home has no rows. Add one, or reset Home to the way it came."))
                    .font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
                    .padding(.vertical, BP.px(24))
                    .accessibilityIdentifier("home-edit-empty")
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    ForEach(lines) { line in rowCard(line) }
                }
                // Room for a focused button's lift at the ends.
                .padding(.vertical, BP.px(12))
                .padding(.bottom, BP.px(80))
            }
        }
    }

    private func rowCard(_ line: HomeEditModel.Line) -> some View {
        let lit: Bool = focus?.hasSuffix(":\(line.id)") ?? false
        // The buttons are icons, so the row's name keeps the room; the focused one's name shows
        // under it in place of the source line (as a tvOS caption would).
        let caption: String? = lit ? focus.flatMap { Self.actionName($0) } : nil
        return HStack(spacing: BP.px(10)) {
            Image(systemName: line.systemImage)
                .font(.system(size: BP.px(18), weight: .semibold))
                .foregroundStyle(BP.ink)
                .frame(width: BP.px(42), height: BP.px(42))
                .background(Circle().fill(BP.panel2))
                .padding(.trailing, BP.px(6))
            // The name and source take everything the buttons leave (the row keeps one height, so the
            // caption swapping in on focus never makes it jump).
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(verbatim: line.title).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if let caption {
                    Text(verbatim: caption).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                } else {
                    Text(verbatim: line.subtitle).font(BP.sans(13, .medium))
                        .foregroundStyle(line.unavailable ? BP.danger : BP.inkMuted)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(line.unavailable ? 0.8 : 1)
            .layoutPriority(1)
            if !line.pinned {
                rowButton(T("Move up"), icon: "chevron.up", action: "up", line, dimmed: !model.canMove(line.id, by: -1)) { move(line, -1) }
                rowButton(T("Move down"), icon: "chevron.down", action: "down", line, dimmed: !model.canMove(line.id, by: 1)) { move(line, 1) }
            }
            if line.canSplit {
                rowButton(T("Split into rows"), icon: "square.split.1x2", action: "split", line) {
                    if let next = model.split(line.id) { ring("remove:\(next)") }
                }
            }
            rowButton(T("Remove"), icon: "minus.circle", action: "remove", line) {
                if let next = model.remove(line.id) { ring("remove:\(next)") } else { ring("add") }
            }
        }
        .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(10))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(lit ? BP.panel2 : BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(lit ? BP.edge2 : BP.edge, lineWidth: 1))
        .animation(BP.easeFast, value: lit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-edit-row-\(line.identity)")
    }

    private func rowButton(_ title: String, icon: String, action: String, _ line: HomeEditModel.Line,
                           dimmed: Bool = false, perform: @escaping () -> Void) -> some View {
        // Icon only (VoiceOver still reads the title); the row's caption names the focused one.
        Button(action: perform) { Label(title, systemImage: icon).labelStyle(.iconOnly) }
            .buttonStyle(HomeEditIconStyle(dimmed: dimmed))
            .focused($focus, equals: "\(action):\(line.id)")
            .accessibilityIdentifier("home-edit-\(action)-\(line.identity)")
    }

    /// The name of a row button from its focus id ("<action>:<spec id>").
    private static func actionName(_ focusId: String) -> String? {
        let action: String = focusId.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        switch action {
        case "up": return T("Move up")
        case "down": return T("Move down")
        case "split": return T("Split into rows")
        case "remove": return T("Remove")
        default: return nil
        }
    }

    /// Moves a row and keeps the ring on the button pressed, so pressing again keeps it going.
    private func move(_ line: HomeEditModel.Line, _ delta: Int) {
        var moved = false
        withAnimation(BP.easeFast) { moved = model.move(line.id, by: delta) }
        guard moved else { return }
        ring("\(delta < 0 ? "up" : "down"):\(line.id)", after: 0.05)
    }

    private func ring(_ id: String, after delay: Double = 0.1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { focus = id }
    }
}

/// A row's compact square icon button in Edit Home: the action button's faces and ring, without
/// its wide text padding, so four of them leave the row its name.
private struct HomeEditIconStyle: ButtonStyle {
    var dimmed = false
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(.system(size: BP.px(16), weight: .semibold))
                .foregroundStyle(BP.ink)
                .opacity(dimmed ? 0.45 : 1)
                .frame(width: BP.px(40), height: BP.px(40))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(focused ? BP.on : BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.rSM, lift: 1.06))
        }
    }
}

/// Edit Home's source picker: every source a row (or the hero) can come from, by group: Home, Movies,
/// Shows and Anime (their whole pages, each of their rows and their Continue Watching), the AniList
/// and MyAnimeList lists, and every addon's catalogs. A source already on Home is marked and not
/// offered twice; a list whose account is not connected says so.
struct HomeSourcePickerView: View {
    enum Mode: String, Identifiable { case row, hero; var id: String { rawValue } }

    @ObservedObject var model: HomeEditModel
    let mode: Mode
    /// The picked row's ring target in Edit Home ("up:<id>"), or "hero".
    let picked: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(18), alignment: .top), count: 3)

    var body: some View {
        ZStack(alignment: .topLeading) {
            BPAmbientBackground()
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(verbatim: mode == .row ? T("Add a row") : T("Hero"))
                    .font(BP.display(32)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                Text(verbatim: mode == .row ? T("Pick what the new row shows. It goes at the end of Home; move it from there.")
                                            : T("Pick whose titles take turns at the top of Home."))
                    .font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(26)) {
                        if mode == .hero { heroChoices }
                        if model.snapshot == nil {
                            HStack(spacing: BP.px(12)) {
                                ProgressView().tint(BP.inkMuted)
                                Text(verbatim: T("Reading your sources…")).font(BP.sans(15, .medium)).foregroundStyle(BP.inkMuted)
                            }
                            .padding(.top, BP.px(30))
                            .accessibilityIdentifier("home-source-loading")
                        }
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: BP.px(12)) {
                                Text(verbatim: group.group.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
                                    .accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(16)) {
                                    ForEach(group.entries) { entry in card(for: entry) }
                                }
                            }
                            .focusSection()
                        }
                    }
                    .padding(.vertical, BP.px(24))
                    .padding(.bottom, BP.px(60))
                    // Room inside the scroll view for a focused card's lift at the sides (it clipped
                    // the ring of a first-column card); the negative padding keeps the grid aligned.
                    .padding(.horizontal, BP.px(16))
                }
                .padding(.horizontal, -BP.px(16))
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(52))
        }
        .task { await model.loadSources() }
        .onExitCommand { dismiss() }
    }

    /// The hero's own choices, before the sources.
    private var heroChoices: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BP.px(16)) {
            choice(title: T("Automatic"), subtitle: T("The first row's titles"), icon: "wand.and.stars",
                   state: model.layout.hero == .auto ? .current : .open, testId: "home-source-hero-auto") {
                pickHero(.auto)
            }
            choice(title: T("Off"), subtitle: T("The title you're on, no carousel"), icon: "pause.circle",
                   state: model.layout.hero == .off ? .current : .open, testId: "home-source-hero-off") {
                pickHero(.off)
            }
        }
        .focusSection()
    }

    private enum CardState { case open, current, onHome, signIn }

    private func card(for entry: HomeSourceEntry) -> some View {
        let state: CardState
        if entry.availability == .needsSignIn { state = .signIn }
        else if mode == .hero { state = model.layout.hero == .source(entry.source) ? .current : .open }
        else { state = model.onHome(entry) ? .onHome : .open }
        return choice(title: entry.title, subtitle: entry.subtitle, icon: entry.systemImage, state: state,
                      testId: "home-source-\(entry.id)") {
            guard state == .open || (mode == .hero && state == .current) else { return }
            if mode == .hero {
                pickHero(.source(entry.source))
            } else if let id = model.add(entry) {
                BPSound.shared.open()
                picked("up:\(id)")
                dismiss()
            }
        }
    }

    private func pickHero(_ hero: HomeHeroSource) {
        model.setHero(hero)
        picked("hero")
        dismiss()
    }

    private func choice(title: String, subtitle: String?, icon: String, state: CardState, testId: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: BP.px(12)) {
                Image(systemName: icon)
                    .font(.system(size: BP.px(17), weight: .semibold))
                    .foregroundStyle(BP.ink)
                    .frame(width: BP.px(40), height: BP.px(40))
                    .background(Circle().fill(BP.panel2))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(verbatim: title).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let note = note(state) ?? subtitle {
                        Text(verbatim: note).font(BP.sans(13, .medium))
                            .foregroundStyle(state == .open ? BP.inkMuted : BP.inkSubtle).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if state == .current || state == .onHome {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: BP.px(18))).foregroundStyle(BP.accent)
                }
            }
            .padding(.horizontal, BP.px(14))
            .frame(maxWidth: .infinity, minHeight: BP.px(68), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .opacity(state == .onHome || state == .signIn ? 0.6 : 1)
        }
        // Focusable even when it cannot be picked (on Home already, not signed in): a disabled card
        // drops the ring and the grid's walk skips over it.
        .buttonStyle(BPTileStyle(radius: BP.rMD, lift: 1.03))
        .accessibilityIdentifier(testId)
    }

    private func note(_ state: CardState) -> String? {
        switch state {
        case .open: return nil
        case .current: return T("The hero now")
        case .onHome: return T("On Home")
        case .signIn: return T("Sign in under Settings first")
        }
    }
}
