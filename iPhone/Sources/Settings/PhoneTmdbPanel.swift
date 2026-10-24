import SwiftUI

/// Settings → TMDB, the TV's "Artwork and rows" (SettingsView, TmdbKeyForm): the v3 key unlocks
/// Trending, In Theaters, Top Rated and the service rows; without it Harbor runs on Cinemeta. A new
/// key is checked against TMDB first (engine onboarding.checkTmdbKey) and saved only once TMDB
/// accepts it; an unreachable TMDB offers "Save it anyway". The saved key stays in the profile's
/// settings (the engine reads it from there) and is never written to a log or shown back, only counted.
struct PhoneTmdbPanel: View {
    @EnvironmentObject private var settings: SettingsBridge
    @ObservedObject private var health = TmdbHealth.shared
    @State private var key = ""
    /// "idle" | "checking" | "rejected" | "unreachable".
    @State private var check = "idle"
    @State private var saveError: String?
    @State private var testing = false
    @State private var testNote: String?
    @State private var testOk = false

    private static let maxLength = 64
    private static let keyLength = 32

    private var saved: Bool { !settings.slice.tmdbKey.isEmpty }
    private var draft: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { check == "checking" }
    private var alert: Bool { check == "rejected" || check == "unreachable" }

    /// What the Settings list says in the row.
    static func summary(key: String, rejected: Bool) -> String {
        key.isEmpty ? T("Cinemeta") : (rejected ? T("Refused") : T("Saved"))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: status)
                        .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                        .foregroundStyle(health.rejected && saved ? BP.danger : BP.ink)
                    Text(verbatim: saved ? T("Saved on this device only (%lld characters)", settings.slice.tmdbKey.count) : T("Add a free TMDB key for Trending, In Theaters, Top Rated and service rows"))
                        .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tmdb-status")
                if saved {
                    Button {
                        Task { await testSaved() }
                    } label: {
                        Text(verbatim: testing ? T("Testing…") : T("Test saved key"))
                    }
                    .disabled(testing)
                    .accessibilityIdentifier("tmdb-test")
                    Button(T("Remove key"), role: .destructive) { Task { await remove() } }
                        .accessibilityIdentifier("tmdb-remove")
                    if let testNote { PhoneSettingsNote(text: testNote, ok: testOk).accessibilityIdentifier("tmdb-test-note") }
                }
            }
            Section {
                TextField(T("TMDB API key, v3 auth"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("tmdb-key")
                Button(busy ? T("Checking…") : T("Verify key")) { Task { await verify() } }
                    .disabled(busy || draft.isEmpty)
                    .accessibilityIdentifier("tmdb-verify")
                if check == "unreachable" && !draft.isEmpty {
                    Button(T("Save it anyway")) { Task { await save() } }
                        .accessibilityIdentifier("tmdb-save-anyway")
                }
                if alert || saveError != nil || !key.isEmpty {
                    PhoneSettingsNote(text: saveError ?? noteText, ok: !alert && saveError == nil)
                        .accessibilityIdentifier("tmdb-note")
                }
            } header: {
                Text(verbatim: saved ? T("Use a different key") : T("Connect TMDB"))
            } footer: {
                Text(verbatim: T("Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail. Get one at themoviedb.org/settings/api."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("TMDB"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: key) { _, now in
            // Typing clears the last answer; the draft stops at 64 characters.
            if now.count > Self.maxLength { key = String(now.prefix(Self.maxLength)) }
            if check != "checking" { check = "idle" }
            saveError = nil
        }
        .accessibilityIdentifier("settings-tmdb")
    }

    private var status: String {
        if !saved { return T("Running on Cinemeta") }
        return health.rejected ? T("TMDB refused the saved key") : T("TMDB key saved")
    }

    private var noteText: String {
        if check == "rejected" { return T("TMDB did not accept that key. Check you copied the v3 key, not the read access token.") }
        if check == "unreachable" { return T("Could not reach TMDB from this phone. You can save the key without checking it.") }
        let n: Int = key.count
        if n > Self.keyLength { return T("%lld characters", n) }
        return T("%lld of %lld characters", n, Self.keyLength)
    }

    private func verify() async {
        let candidate: String = draft
        guard !candidate.isEmpty, !busy else { return }
        check = "checking"
        saveError = nil
        let raw: String? = try? await HarborEngine.shared.call("onboarding.checkTmdbKey", [candidate])
        let answer: String = raw ?? "unreachable"
        // Typed on while TMDB answered: that answer is for another key.
        guard candidate == draft else { check = "idle"; return }
        if answer == "ok" {
            check = "idle"
            await save()
        } else {
            check = answer == "rejected" ? "rejected" : "unreachable"
            PhoneFeedback.shared.failure()
        }
    }

    private func save() async {
        let value: String = draft
        guard !value.isEmpty else { return }
        do {
            try await settings.patch(["tmdbKey": .string(value)])
            check = "idle"
            key = ""
            testNote = nil
            PhoneFeedback.shared.success()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// SettingsView.testSavedKey.
    private func testSaved() async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        let r = await settings.verifyTmdb(key: settings.slice.tmdbKey)
        testNote = r.ok ? T("OK: TMDB accepted the saved key.") : T("Rejected. TMDB said: %@", r.reason ?? T("no details"))
        testOk = r.ok
    }

    private func remove() async {
        do {
            try await settings.patch(["tmdbKey": .string("")])
            testNote = nil
        } catch {
            testNote = T("Failed: %@", error.localizedDescription)
            testOk = false
        }
    }
}
