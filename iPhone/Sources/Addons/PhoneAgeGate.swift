import SwiftUI

/// components/age-gate-modal.tsx on the phone (AgeGateView on the TV): three everyday questions
/// any adult would know (the engine's English or Arabic bank), all three right to turn adult addons
/// on. A wrong round shows the notice and deals a fresh round after 1.4 s; a pass shows "You're
/// verified" and closes after 1.7 s, as on the TV.
struct PhoneAgeGate: View {
    let onPass: () -> Void
    let close: () -> Void

    struct Question: Decodable, Hashable { var q: String; var options: [String]; var correct: Int }
    private struct Round: Decodable { var questions: [Question] }

    @State private var questions: [Question] = []
    @State private var picks: [Int?] = [nil, nil, nil]
    @State private var submitted = false
    @State private var verified = false
    @State private var dealFailed = false
    /// The wrong round's re-deal, cancelled when the gate closes inside the 1.4 s.
    @State private var redeal: Task<Void, Never>?

    private var allAnswered: Bool { !questions.isEmpty && picks.prefix(questions.count).allSatisfy { $0 != nil } }
    private var allCorrect: Bool { questions.enumerated().allSatisfy { i, q in picks[i] == q.correct } }

    var body: some View {
        NavigationStack {
            Group {
                if verified {
                    VStack(spacing: 18) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(BP.live)
                            .accessibilityHidden(true)
                        Text(T("You're verified"))
                            .font(PhoneTheme.display(26, .semibold, relativeTo: .title2))
                            .foregroundStyle(BP.ink)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("age-gate-verified")
                } else {
                    form
                }
            }
            .background(PhoneBackground())
            .navigationTitle(T("Quick age check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("Cancel"), action: close)
                        .disabled(verified)
                        .accessibilityIdentifier("age-gate-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Continue"), action: submit)
                        .disabled(!allAnswered || submitted || verified)
                        .accessibilityIdentifier("age-gate-continue")
                }
            }
        }
        .task { await deal() }
        .onDisappear { redeal?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("age-gate")
    }

    private var form: some View {
        List {
            SwiftUI.Section {
                Text(T("A quick age check before adult add-ons unlock. Answer three everyday questions any adult would know, and you're in."))
                    .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                    .foregroundStyle(BP.inkMuted)
                    .listRowBackground(Color.clear)
                if dealFailed && questions.isEmpty {
                    ErrorPlate(title: T("Failed to load")) { redeal?.cancel(); redeal = Task { await deal() } }
                        .listRowBackground(Color.clear)
                }
                if submitted && !allCorrect {
                    Label { Text(T("That's not it. Try a fresh round in a moment.")) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(PhoneTheme.sans(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(BP.danger)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("age-gate-wrong")
                }
            }
            ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                SwiftUI.Section {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { oi, option in
                        optionRow(qi: qi, oi: oi, text: option, correct: q.correct)
                    }
                } header: {
                    Text(verbatim: "\(qi + 1). \(q.q)")
                        .font(PhoneTheme.sans(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(BP.ink)
                        .textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func optionRow(qi: Int, oi: Int, text: String, correct: Int) -> some View {
        let picked = picks[qi] == oi
        let wasWrong = submitted && picked && oi != correct
        return Button {
            guard !submitted else { return }
            PhoneFeedback.shared.selection()
            picks[qi] = oi
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(wasWrong ? BP.danger : (picked ? BP.accent : BP.inkSubtle))
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(PhoneTheme.sans(16, .regular, relativeTo: .body))
                    .foregroundStyle(wasWrong ? BP.danger : BP.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear.background(.ultraThinMaterial))
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("age-gate-option-\(qi)-\(oi)")
    }

    private func deal() async {
        let r: Round? = try? await AddonsEngine.call("addonsManager.ageGate", [L10n.language])
        // The gate closed while the engine answered: nothing to deal.
        guard !Task.isCancelled else { return }
        questions = Array((r?.questions ?? []).prefix(3))
        picks = [nil, nil, nil]
        submitted = false
        dealFailed = questions.isEmpty
    }

    private func submit() {
        guard !submitted, allAnswered else { return }
        submitted = true
        if allCorrect {
            PhoneFeedback.shared.success()
            verified = true
            onPass()
            Task {
                try? await Task.sleep(for: .seconds(1.7))
                close()
            }
            return
        }
        PhoneFeedback.shared.failure()
        redeal = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            await deal()
        }
    }
}
