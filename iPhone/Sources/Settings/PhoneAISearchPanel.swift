import SwiftUI

/// Settings → AI search, the TV's AISearchPanel (ai-search-section.tsx): the provider (OpenRouter /
/// Groq), that provider's key, its model list, a custom model id, and the live web context (Jina
/// Reader). Keys go to the engine (engine/aiSearch.ts keeps them in the Keychain); the panel only ever
/// sees the masked tail the engine hands back, and a draft is cleared as soon as it is saved.
struct PhoneAISearchPanel: View {
    @State private var state: AISearchModel.State?
    @State private var models: AISearchModel.Models?
    @State private var keyDraft = ""
    @State private var jinaDraft = ""
    @State private var customDraft = ""
    @State private var failed = false

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }
    private var tab: String { state?.tab ?? "openrouter" }
    private var groq: Bool { tab == "groq" }
    private var tabModels: [AISearchModel.ModelRow] { (groq ? models?.groq : models?.openrouter) ?? [] }
    private var savedMask: String? { groq ? state?.saved.groq : state?.saved.openrouter }

    var body: some View {
        Form {
            Section {
                ForEach(["openrouter", "groq"], id: \.self) { p in
                    PhoneChoiceRow(title: p == "groq" ? "Groq" : "OpenRouter", on: tab == p, id: "ai-provider-\(p)") {
                        Task { await setProvider(p) }
                    }
                }
            } header: {
                Text(verbatim: T("Provider"))
            } footer: {
                Text(verbatim: T("Type what you want in plain language and let a model find it. Bring your own API key from either service."))
            }

            Section {
                SecureField(groq ? T("Groq API key (gsk-...)") : T("OpenRouter API key (sk-or-...)"), text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ai-key")
                Button(T("Save")) { Task { await saveKey(groq ? "groq" : "openrouter", keyDraft) } }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ai-key-save")
                if let savedMask {
                    Text(verbatim: "\(T("Saved")) · \(savedMask)")
                        .foregroundStyle(BP.live)
                        .accessibilityIdentifier("ai-key-saved")
                    Button(T("Remove"), role: .destructive) { Task { await saveKey(groq ? "groq" : "openrouter", "") } }
                        .accessibilityIdentifier("ai-key-remove")
                }
            } header: {
                Text(verbatim: groq ? T("Groq LPU inference") : T("Natural-language search"))
            } footer: {
                Text(verbatim: help)
            }

            Section {
                ForEach(tabModels) { m in
                    PhoneChoiceRow(title: m.label, detail: tags(m), on: m.id == state?.model, id: "ai-model-\(m.id)") {
                        Task { await setModel(m.id) }
                    }
                }
            } header: {
                Text(verbatim: T("AI model"))
            }

            Section {
                TextField(groq ? "llama-3.3-70b-versatile" : "vendor/model-name:free", text: $customDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ai-custom")
                Button(T("Use model")) { Task { await setModel(customDraft.trimmingCharacters(in: .whitespaces)) } }
                    .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ai-custom-use")
            } header: {
                Text(verbatim: T("Custom model id"))
            } footer: {
                Text(verbatim: groq ? T("Any model id from console.groq.com/docs/models works here.") : T("Any model id from openrouter.ai/models works here, including :free variants."))
            }

            Section {
                Toggle(isOn: Binding(get: { state?.webSearch ?? false }, set: { on in Task { await setWebSearch(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: T("Use live web context"))
                        Text(verbatim: T("Fetches DuckDuckGo results and feeds top hits into the model prompt."))
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("ai-web")
                SecureField("jina_...", text: $jinaDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ai-jina")
                Button(T("Save")) { Task { await saveKey("jina", jinaDraft) } }
                    .disabled(jinaDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ai-jina-save")
                if let mask = state?.saved.jina {
                    Text(verbatim: "\(T("Saved")) · \(mask)").foregroundStyle(BP.live)
                    Button(T("Remove"), role: .destructive) { Task { await saveKey("jina", "") } }
                        .accessibilityIdentifier("ai-jina-remove")
                }
            } header: {
                Text(verbatim: T("Live web"))
            } footer: {
                Text(verbatim: "\(T("Augments AI picks with current web results before asking the model. Powered by")) Jina Reader. \(T("Works without a key at low volume; add a key for higher quotas.")) \(T("Get a key at")) jina.ai/reader.")
            }

            if failed {
                Section { PhoneSettingsNote(text: T("Could not reach Harbor's engine. Try again in a moment.")).accessibilityIdentifier("ai-error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("AI search"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .accessibilityIdentifier("settings-ai")
    }

    private var help: String {
        let lead = T("Adds an \"Ask AI\" button to search, so you can type things like a plain-language request.")
        if groq {
            return "\(lead) \(T("Get a key at")) console.groq.com/keys. \(T("Groq runs open-source models on its LPU hardware with a generous free tier; every model listed below runs on the free tier."))"
        }
        return "\(lead) \(T("Get a key at")) openrouter.ai/keys. \(T("It only runs when you tap that button, so it never costs anything unless you ask."))"
    }

    private func tags(_ m: AISearchModel.ModelRow) -> String {
        var parts: [String] = []
        if m.recommended { parts.append(T("Recommended")) }
        if m.free { parts.append(m.provider == "groq" ? T("Free tier") : T("Free")) }
        parts.append(m.providerName)
        return parts.joined(separator: " · ")
    }

    // MARK: engine (engine/aiSearch.ts)

    private func load() async {
        let p = profile
        state = try? await HarborEngine.shared.call("aiSearch.state", [p.id, p.linked])
        models = try? await HarborEngine.shared.call("aiSearch.models", [p.id, p.linked])
        failed = state == nil
    }

    private func saveKey(_ slot: String, _ value: String) async {
        let p = profile
        let trimmed: String = value.trimmingCharacters(in: .whitespaces)
        guard let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.saveKey", [slot, trimmed, p.id, p.linked]) else {
            failed = true
            PhoneFeedback.shared.failure()
            return
        }
        failed = false
        state = s
        if slot == "jina" { jinaDraft = "" } else { keyDraft = "" }
        PhoneFeedback.shared.success()
        // A Groq key lets the live catalog prune Groq's list.
        if slot == "groq" { models = try? await HarborEngine.shared.call("aiSearch.models", [p.id, p.linked]) }
    }

    private func setProvider(_ next: String) async {
        let p = profile
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setProvider", [next, p.id, p.linked]) {
            state = s
            keyDraft = ""
            PhoneFeedback.shared.selection()
        }
    }

    /// ai-search-section.tsx setModel: `update({ aiSearchModel: id, aiSearchProvider: tab })`.
    private func setModel(_ id: String) async {
        guard !id.isEmpty else { return }
        let p = profile
        let current: String? = state?.tab
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setModel", [id, current, p.id, p.linked]) {
            state = s
            PhoneFeedback.shared.selection()
        }
    }

    private func setWebSearch(_ on: Bool) async {
        let p = profile
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setWebSearch", [on, p.id, p.linked]) { state = s }
    }
}
