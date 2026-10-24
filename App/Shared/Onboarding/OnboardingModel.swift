import SwiftUI

/// The setup wizard's step machine: which step
/// is up, advancing and going back past the steps the phone already delivered, the "Leave setup?"
/// dialog, the resume point kept across a relaunch, and the recap facts. OnboardingView draws it on
/// the TV with the remote's focus ring; the hand-off host (TvHandoff, TV only) stays in the view and
/// is read through `bind`.
///
/// Every property is @Published where it was @State, so a write redraws the view exactly as before.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case language, phone, tmdb, stremio, layout, streaming, subtitles, taste, done }

    /// bp-onboarding.tsx readResumeIndex: setup opens on the screen it was
    /// left on. It always opened on Language, so a TV switched off or an app killed mid-setup (and
    /// any rebuild of the tree, such as a language change) started over.
    @Published var step: Step = OnboardingModel.resumeStep()
    /// A Stremio sign-in parked for the first profile (read back on appear after a relaunch).
    @Published var stremioName: String?
    @Published var facts: OnboardFacts?
    /// bp-onboarding.tsx leaveOpen: Back on the first screen asks "Leave setup?".
    @Published var leaveOpen = false
    /// Where the ring was when the dialog opened (BpOnboardLeave hands focus back to it on close).
    private var leaveReturn: String?

    // MARK: what the view hands over (its @FocusState and the hand-off host)

    private var focusReader: () -> String? = { nil }
    private var focusWriter: (String?) -> Void = { _ in }
    private var handoffDone: () -> [HandoffStep] = { [] }
    /// advanceBpOnboardRing: once a step's answer is given the ring moves to its primary button.
    var ring: String? {
        get { focusReader() }
        set { focusWriter(newValue) }
    }

    /// The view hands over its @FocusState and the phone hand-off's finished steps (capturing only
    /// the state and the host, never the view or the model).
    func bind(read: @escaping () -> String?, write: @escaping (String?) -> Void, handoffDone: @escaping () -> [HandoffStep]) {
        focusReader = read
        focusWriter = write
        self.handoffDone = handoffDone
    }

    // MARK: Stremio sign-in carried over from before a profile existed

    /// On appear: the parked sign-in, else the active (or first) profile's.
    func adoptStremioName(profiles: ProfilesStore) {
        if stremioName == nil, let s = PendingStremio.session { stremioName = s.user.fullname ?? s.user.email }
        // After Finish later the parked sign-in already went to a profile.
        if stremioName == nil, let p = profiles.active ?? profiles.profiles.first, let s = profiles.stremioSession(for: p.id) {
            stremioName = s.user.fullname ?? s.user.email
        }
    }

    /// The phone delivered a Stremio sign-in.
    func adoptPendingStremio() {
        if stremioName == nil, let s = PendingStremio.session { stremioName = s.user.fullname ?? s.user.email }
    }

    // MARK: steps

    /// The step changed (or setup opened on `.done`): keep the resume point, read the recap facts.
    func stepChanged(_ s: Step) {
        Self.saveResume(s)
        if s == .done { Task { await loadFacts() } }
    }

    /// A resumed setup opens past the phone step (or on the recap) without a step change.
    func loadFactsIfNeeded() {
        if step == .done, facts == nil { Task { await loadFacts() } }
    }

    func loadFacts() async {
        let p = ProfilesStore.shared.active
        facts = try? await HarborEngine.shared.call("onboarding.facts", [p?.id ?? "default", p?.linked ?? true])
    }

    static func resumeStep() -> Step {
        // UI-test launches always open on the first screen.
        guard !Fixtures.active, let raw = Prefs.get(String.self, for: OnboardingResume.key) else { return .language }
        // A setup left on the retired Harbor account step picks up at the next one.
        if raw == "harbor" { return .layout }
        return Step.allCases.first { "\($0)" == raw } ?? .language
    }

    private static func saveResume(_ s: Step) {
        guard !Fixtures.active else { return }
        try? Prefs.set("\(s)", for: OnboardingResume.key)
    }

    /// Steps the phone already delivered are passed over, so nobody signs in twice.
    func advance() {
        var next = Step(rawValue: step.rawValue + 1) ?? .done
        let done = handoffDone()
        while let h = Self.handoffStep(next), done.contains(h), let after = Step(rawValue: next.rawValue + 1) { next = after }
        withAnimation(BP.easeSlow) { step = next }
    }

    /// bp-onboarding.tsx Back: `setIndex(i - 1)`, passing over the steps the phone delivered as
    /// advance() does, so Back never lands on a sign-in the viewer never saw.
    func back() {
        guard var prev = Step(rawValue: step.rawValue - 1) else { return }
        let done = handoffDone()
        while let h = Self.handoffStep(prev), done.contains(h), let before = Step(rawValue: prev.rawValue - 1) { prev = before }
        withAnimation(BP.easeSlow) { step = prev }
    }

    private static func handoffStep(_ s: Step) -> HandoffStep? {
        switch s {
        case .tmdb: return .tmdb
        case .stremio: return .stremio
        default: return nil
        }
    }

    // MARK: leave dialog

    /// Menu: closes "Leave setup?" when it is up, opens it on the first screen, back() past it
    /// (bp-onboarding.tsx pushBpBack). The first screen under the intro wall (setup disabled)
    /// leaves the press to the system, as before: the dialog must not open behind the wall.
    func exitAction(enabled: Bool) -> (() -> Void)? {
        if leaveOpen { return { [self] in closeLeave() } }
        if step == .language {
            if !enabled { return nil }
            return { [self] in openLeave() }
        }
        return { [self] in back() }
    }

    /// BpOnboardLeave mount: remembers the ring; the dialog seeds Keep setting up.
    func openLeave() {
        leaveReturn = ring
        withAnimation(BP.easeFast) { leaveOpen = true }
    }

    /// Keep setting up, or Back with the dialog up: the ring goes back where it
    /// was (BpOnboardLeave's cleanup setBpFocus(prev)). OnboardLanguageStep re-seeds the current
    /// language the moment its list is enabled again; this lands just after, so a ring that was on
    /// another row or on Continue returns there.
    func closeLeave() {
        let target = leaveReturn
        leaveReturn = nil
        withAnimation(BP.easeFast) { leaveOpen = false }
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in ring = target }
    }
}

/// use-bp-onboard-facts.ts (the counts) plus bp-done-flourish's five posters (engine onboarding.facts).
struct OnboardFacts: Decodable {
    var servicesOn: Int
    var subLangs: [String]
    var tastePicks: Int
    var art: [String]
}
