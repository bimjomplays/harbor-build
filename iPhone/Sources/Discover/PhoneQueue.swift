import SwiftUI
import Combine

/// The Discovery Queue's state for the phone: the engine's deck (QueueDeckModel, the same picks the
/// TV steps through) with a cursor of its own, because on the phone every pick is answered, not
/// just stepped over: skipped (hidden for two weeks), saved to the watchlist, or opened.
///
/// Under `--fixtures` the engine has no TMDB and so no queue (it answers "nokey"), so the deck is a
/// fixed list of six picks and every answer stays local.
@MainActor
final class PhoneQueueModel: ObservableObject {
    enum Action: Equatable { case skip, watchlist, accept }

    struct Tally: Equatable {
        var skipped = 0
        var saved = 0
        var opened = 0
        var hidden = 0
        var answered: Int { skipped + saved + opened + hidden }
    }

    @Published private(set) var status = "loading"
    @Published private(set) var entries: [QueueDeckModel.Entry] = []
    @Published private(set) var index = 0
    @Published private(set) var saved: Set<String> = []
    @Published private(set) var tally = Tally()

    private let deck = QueueDeckModel()
    private let offline = Fixtures.active && !Fixtures.liveRooms
    private var opened = false
    private var mirror: AnyCancellable?

    init() {
        // The deck pages more picks in by itself as the end nears; they land here as they arrive.
        mirror = deck.$entries.receive(on: RunLoop.main).sink { [weak self] list in
            guard let self, !self.offline else { return }
            self.entries = list
        }
    }

    var current: QueueDeckModel.Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// The next picks behind the one on screen, for the stack's edge.
    var upNext: [QueueDeckModel.Entry] {
        guard index + 1 < entries.count else { return [] }
        return Array(entries[(index + 1)..<min(entries.count, index + 3)])
    }

    // MARK: Opening

    func open() async {
        guard !opened else { return }
        opened = true
        if offline {
            entries = Self.fixtureDeck()
            status = "ready"
            index = 0
            return
        }
        await deck.open()
        sync()
        index = 0
    }

    private func sync() {
        entries = deck.entries
        status = deck.status
        saved = deck.saved
    }

    /// The deck acts on its own current pick: put it where the phone's cursor is.
    private func align() {
        deck.index = min(index, max(0, deck.entries.count - 1))
    }

    /// Whether the pick on screen is already on the watchlist (read again as the card changes).
    func refreshSaved() async {
        guard !offline, current != nil else { return }
        align()
        await deck.readSaved()
        saved = deck.saved
    }

    // MARK: Answers

    func perform(_ action: Action) async {
        guard let entry = current else { return }
        switch action {
        case .skip:
            if offline {
                entries.remove(at: index)
            } else {
                align()
                await deck.snooze()
                sync()
            }
            tally.skipped += 1
            // The next pick slid into this place; past the last one the deck is done.
            index = min(index, entries.count)
        case .watchlist:
            if !saved.contains(entry.id) {
                if offline {
                    saved.insert(entry.id)
                } else {
                    align()
                    await deck.readSaved()
                    if !deck.saved.contains(entry.id) { await deck.toggleSave() }
                    sync()
                }
            }
            tally.saved += 1
            advance()
        case .accept:
            tally.opened += 1
            advance()
        }
    }

    /// Not interested: the pick is hidden for good (the engine's block list).
    func block(_ entry: QueueDeckModel.Entry) async {
        let at: Int? = entries.firstIndex(where: { $0.id == entry.id })
        if offline {
            if let at { entries.remove(at: at) }
        } else {
            await deck.block(entry.id)
            sync()
        }
        if let at, at < index { index -= 1 }
        index = min(index, entries.count)
        tally.hidden += 1
    }

    private func advance() {
        guard index < entries.count else { return }
        index += 1
        guard !offline, index < deck.entries.count else { return }
        // QueueDeckModel.step is what pages more picks in as the end nears.
        deck.index = index - 1
        deck.step(1)
    }

    // MARK: Fixtures

    /// Six picks for `--fixtures`: ids, names and tags a UI test can name.
    static func fixtureDeck() -> [QueueDeckModel.Entry] {
        let names: [String] = ["Past Lives", "The Holdovers", "Anatomy of a Fall", "Poor Things", "Shōgun", "Fallout"]
        let tags: [String] = ["Critics' pick", "Because you watched Oppenheimer", "Hidden gem", "Trending now", "Staff pick", "New this week"]
        return names.enumerated().map { i, name -> QueueDeckModel.Entry in
            let kind: String = i >= 4 ? "series" : "movie"
            let meta = Meta(id: "tt90000\(i)", type: kind, name: name, poster: nil, background: nil, logo: nil,
                            description: "A placeholder synopsis for \(name), long enough to wrap onto a few lines so the card's clamp can be checked on a small phone.",
                            releaseInfo: "202\(i % 5)", releaseDate: nil, inTheaters: nil, imdbRating: "8.\(i)", tmdbScore: nil,
                            runtime: "1h \(40 + i)m", genres: ["Drama", "Thriller"], adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
            return QueueDeckModel.Entry(meta: meta, tag: tags[i])
        }
    }
}

// MARK: - The deck

/// The Discovery Queue as a stack of cards. Swipe right to open a pick, left to skip it, up to put it
/// on the watchlist; every swipe has a button, and VoiceOver gets the same three as actions.
struct PhoneQueueView: View {
    let open: (Meta) -> Void

    @StateObject private var model = PhoneQueueModel()
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGSize = .zero
    @State private var armed: PhoneQueueModel.Action?
    @State private var busy = false
    @State private var confirmBlock: QueueDeckModel.Entry?

    /// How far a card has to travel before it counts as an answer, and how far a flick has to promise.
    private static let reach: CGFloat = 90
    private static let flick: CGFloat = 320

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 12) {
                if model.current != nil {
                    header
                    stack
                    actions
                } else if model.status == "loading" {
                    ProgressView().tint(BP.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("queue-loading")
                } else {
                    finished
                }
            }
            .padding(.horizontal, PhoneTheme.margin)
            .padding(.bottom, 8)
        }
        .navigationTitle(T("Discovery Queue"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(T("Done")) { dismiss() }
                    .accessibilityIdentifier("queue-done")
            }
        }
        .task { await model.open() }
        .task(id: model.current?.id) { await model.refreshSaved() }
        .alert(Text(T("Hide this permanently?")),
               isPresented: Binding(get: { confirmBlock != nil }, set: { shown in if !shown { confirmBlock = nil } }),
               presenting: confirmBlock) { entry in
            Button(T("Not interested"), role: .destructive) {
                PhoneFeedback.shared.warning()
                Task { await model.block(entry) }
            }
            Button(T("Keep"), role: .cancel) {}
        } message: { entry in
            Text(T("%@ will not come back in the Discovery Queue.", entry.meta.name))
        }
        // `.contain` keeps the card, buttons and counters their own identifiers: a bare identifier on a
        // plain ZStack is stamped on its children, so the UI tests never found queue-card.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue")
    }

    // MARK: Parts

    /// The pick's own art, blurred and dimmed, behind the stack.
    private var backdrop: some View {
        ZStack {
            BP.canvas
            if let entry = model.current {
                PhoneImage(url: entry.meta.background ?? entry.meta.poster, decodeScale: 0.25)
                    .blur(radius: 46)
                    .opacity(0.55)
                    .id(entry.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [BP.canvas.opacity(0.35), BP.canvas.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .motion(.easeOut(duration: 0.25), value: model.current?.id)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack {
            Text(verbatim: T("%lld of %lld", model.index + 1, model.entries.count))
                .font(PhoneTheme.sans(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(BP.ink)
                .monospacedDigit()
                .accessibilityIdentifier("queue-position")
            Spacer()
            Text(verbatim: tallyLine)
                .font(PhoneTheme.sans(12, .medium, relativeTo: .caption))
                .foregroundStyle(BP.inkMuted)
                .accessibilityIdentifier("queue-tally")
        }
    }

    private var tallyLine: String {
        let t = model.tally
        return T("Saved %lld · Skipped %lld · Opened %lld", t.saved, t.skipped, t.opened)
    }

    private var stack: some View {
        GeometryReader { proxy in
            let room: CGFloat = 132
            let height: CGFloat = max(180, min((proxy.size.width - 40) * 1.5, proxy.size.height - room))
            let width: CGFloat = height / 1.5
            let travel: CGFloat = min(1, hypot(drag.width, drag.height) / 120)
            ZStack {
                ForEach(Array(model.upNext.enumerated().reversed()), id: \.element.id) { depth, entry in
                    let level: CGFloat = CGFloat(depth + 1) - travel
                    QueueCardFace(entry: entry, width: width, height: height)
                        .scaleEffect(1 - 0.06 * level)
                        .offset(y: 14 * level)
                        .opacity(1 - 0.25 * level)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let entry = model.current {
                    topCard(entry, width: width, height: height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private func topCard(_ entry: QueueDeckModel.Entry, width: CGFloat, height: CGFloat) -> some View {
        QueueCardFace(entry: entry, width: width, height: height, stamps: stamps)
            .id(entry.id)
            .offset(drag)
            .rotationEffect(.degrees(Double(drag.width / 24)))
            .gesture(
                // Global space: the card moves under the finger, so its own space would feed back.
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        guard !busy else { return }
                        drag = value.translation
                        let hit = Self.answer(value.translation, limit: Self.reach)
                        if hit != armed {
                            armed = hit
                            if hit != nil { PhoneFeedback.shared.selection() }
                        }
                    }
                    .onEnded { value in
                        guard !busy else { return }
                        armed = nil
                        let hit = Self.answer(value.translation, limit: Self.reach)
                            ?? Self.answer(value.predictedEndTranslation, limit: Self.flick)
                        if let hit {
                            commit(hit)
                        } else {
                            withMotion(.spring(duration: 0.3)) { drag = .zero }
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: cardLabel(entry)))
            .accessibilityAction(named: Text(T("Watch"))) { commit(.accept) }
            .accessibilityAction(named: Text(T("Skip"))) { commit(.skip) }
            .accessibilityAction(named: Text(T("Save to watchlist"))) { commit(.watchlist) }
            .accessibilityIdentifier("queue-card")
    }

    private func cardLabel(_ entry: QueueDeckModel.Entry) -> String {
        var parts: [String] = [entry.meta.name]
        if !entry.meta.facts.isEmpty { parts.append(entry.meta.facts) }
        if !entry.tag.isEmpty { parts.append(T(entry.tag)) }
        return parts.joined(separator: ", ")
    }

    /// How much of each answer the card's travel has earned (0...1), for its stamps.
    private var stamps: QueueCardFace.Stamps {
        let reach: CGFloat = Self.reach
        let horizontal: Bool = abs(drag.width) >= abs(drag.height)
        let accept: Double = horizontal ? Double(min(1, max(0, drag.width / reach))) : 0
        let skip: Double = horizontal ? Double(min(1, max(0, -drag.width / reach))) : 0
        let save: Double = horizontal ? 0 : Double(min(1, max(0, -drag.height / reach)))
        return QueueCardFace.Stamps(accept: accept, skip: skip, save: save)
    }

    private var actions: some View {
        let entry = model.current
        let isSaved: Bool = entry.map { model.saved.contains($0.id) } ?? false
        return HStack(spacing: 14) {
            QueueButton(title: T("Skip"), label: T("Skip"), icon: "xmark", id: "queue-skip") { commit(.skip) }
            QueueButton(title: T("Hide"), label: T("Not interested"), icon: "hand.thumbsdown", id: "queue-block") {
                confirmBlock = entry
            }
            QueueButton(title: isSaved ? T("Saved") : T("Save"), label: T("Save to watchlist"),
                        icon: isSaved ? "bookmark.fill" : "bookmark", id: "queue-watchlist") { commit(.watchlist) }
            QueueButton(title: T("Details"), label: T("Details"), icon: "info.circle", id: "queue-details") {
                if let entry { open(entry.meta) }
            }
            QueueButton(title: T("Watch"), label: T("Watch"), icon: "play.fill", id: "queue-accept", prominent: true) { commit(.accept) }
        }
        .disabled(busy || entry == nil)
    }

    private var finished: some View {
        let t = model.tally
        let title: String
        let message: String
        switch model.status {
        case "nokey":
            title = T("Discovery Queue")
            message = T("Add a TMDB key in Settings to unlock the full discovery feed.")
        case "unreachable":
            title = T("Discovery Queue")
            message = T("No picks loaded. TMDB might be unreachable.")
        default:
            title = t.answered > 0 ? T("You're through tonight's picks") : T("Nothing left in today's picks")
            message = t.answered > 0 ? tallyLine : T("Come back tomorrow, or clear what you skipped in Settings.")
        }
        return EmptyState(title: title, message: message, systemImage: "rectangle.stack",
                          actionTitle: T("Back to Discover")) { dismiss() }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("queue-empty")
    }

    // MARK: Answers

    /// The answer a travel of `t` names, once it reaches `limit`: right opens, left skips, up saves.
    private static func answer(_ t: CGSize, limit: CGFloat) -> PhoneQueueModel.Action? {
        if abs(t.width) >= abs(t.height) {
            if t.width >= limit { return .accept }
            if t.width <= -limit { return .skip }
            return nil
        }
        return t.height <= -limit ? .watchlist : nil
    }

    private static func exit(for action: PhoneQueueModel.Action) -> CGSize {
        switch action {
        case .accept: return CGSize(width: 520, height: 0)
        case .skip: return CGSize(width: -520, height: 0)
        case .watchlist: return CGSize(width: 0, height: -760)
        }
    }

    /// Fly the card off in its answer's direction, record the answer, then bring the next card up.
    private func commit(_ action: PhoneQueueModel.Action) {
        guard !busy, let entry = model.current else { return }
        busy = true
        armed = nil
        let meta: Meta = entry.meta
        let fly: CGSize = Self.exit(for: action)
        let animate: Bool = !PhoneMotion.reduced
        if action == .skip { PhoneFeedback.shared.tap() } else { PhoneFeedback.shared.success() }
        Task {
            if animate {
                withMotion(.easeIn(duration: 0.2)) { drag = fly }
                try? await Task.sleep(for: .milliseconds(210))
            }
            await model.perform(action)
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain) { drag = .zero }
            busy = false
            if action == .accept { open(meta) }
        }
    }
}

/// One pick as a card: the poster, then its name, its facts and its tag.
private struct QueueCardFace: View {
    struct Stamps {
        var accept: Double = 0
        var skip: Double = 0
        var save: Double = 0
    }

    let entry: QueueDeckModel.Entry
    let width: CGFloat
    let height: CGFloat
    var stamps = Stamps()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                PhoneImage(url: entry.meta.poster ?? entry.meta.background)
                if entry.meta.poster == nil && entry.meta.background == nil {
                    Text(verbatim: entry.meta.name)
                        .font(PhoneTheme.display(24, .semibold, relativeTo: .title2))
                        .foregroundStyle(BP.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
                stamp(T("Watch"), icon: "play.fill", color: BP.accent, amount: stamps.accept, alignment: .topLeading)
                stamp(T("Skip"), icon: "xmark", color: BP.danger, amount: stamps.skip, alignment: .topTrailing)
                stamp(T("Save"), icon: "bookmark.fill", color: BP.ink, amount: stamps.save, alignment: .bottom)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.radiusLarge, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 4) {
                if !entry.tag.isEmpty {
                    Text(verbatim: T(entry.tag))
                        .font(PhoneTheme.sans(11, .bold, relativeTo: .caption2))
                        .textCase(.uppercase)
                        .foregroundStyle(BP.accent)
                        .lines(1)
                }
                Text(verbatim: entry.meta.name)
                    .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(BP.ink)
                    .lines(1)
                Text(verbatim: entry.meta.facts)
                    .font(PhoneTheme.sans(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(BP.inkMuted)
                    .lines(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
    }

    /// The answer's name stamped on the poster as the card travels toward it.
    private func stamp(_ title: String, icon: String, color: Color, amount: Double, alignment: Alignment) -> some View {
        Label(title, systemImage: icon)
            .font(PhoneTheme.sans(18, .bold, relativeTo: .headline))
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BP.canvas.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color, lineWidth: 2))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .opacity(amount)
            .accessibilityHidden(true)
    }
}

/// A round glass button with its name under it.
private struct QueueButton: View {
    let title: String
    let label: String
    let icon: String
    let id: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            if prominent {
                Button(action: action) { glyph }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
            } else {
                Button(action: action) { glyph }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            Text(verbatim: title)
                .font(PhoneTheme.sans(11, .medium, relativeTo: .caption2))
                .foregroundStyle(BP.inkMuted)
                .lines(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier(id)
    }

    private var glyph: some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 30, height: 30)
    }
}
