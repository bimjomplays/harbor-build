import SwiftUI

/// Settings → Stremio account, the TV's Stremio section (SettingsView): who is signed in for the
/// active profile with a Sign out, or an email and password form with Sign in. The session is the
/// profile's own (ProfilesStore keeps it in the secret store); the password is never kept.
struct PhoneStremioPanel: View {
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var session: ProfilesStore.StremioSession?
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmOut = false

    private var profile: ProfilesStore.Profile? { profiles.active ?? profiles.profiles.first }

    /// SettingsView.stremioLine: the name, else the email.
    static func line(_ fullname: String?, _ email: String) -> String {
        let name: String = [fullname ?? "", email].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return name.isEmpty ? T("Signed in") : T("Signed in as %@", name)
    }

    /// What the Settings list says in the row.
    static func summary(_ profiles: ProfilesStore) -> String {
        guard let p = profiles.active ?? profiles.profiles.first, profiles.stremioSession(for: p.id) != nil else { return T("Not signed in") }
        return T("Signed in")
    }

    var body: some View {
        Form {
            if let session {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: Self.line(session.user.fullname, session.user.email))
                            .font(PhoneTheme.sans(17, .semibold, relativeTo: .body))
                            .foregroundStyle(BP.ink)
                        if let p = profile {
                            Text(verbatim: T("For the %@ profile", p.name))
                                .font(PhoneTheme.sans(14, .regular, relativeTo: .footnote))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("stremio-account")
                    Button(T("Sign out"), role: .destructive) { confirmOut = true }
                        .accessibilityIdentifier("stremio-sign-out")
                } footer: {
                    Text(verbatim: T("Stream and catalog addons are installed on this phone plus the ones on your Stremio account."))
                }
            } else {
                Section {
                    TextField(T("Email"), text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .accessibilityIdentifier("stremio-email")
                    SecureField(T("Password"), text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("stremio-password")
                    Button(busy ? T("Signing in…") : T("Sign in")) { Task { await signIn() } }
                        .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                        .accessibilityIdentifier("stremio-sign-in")
                    if let failure {
                        PhoneSettingsNote(text: failure).accessibilityIdentifier("stremio-error")
                    }
                } header: {
                    Text(verbatim: T("Not signed in"))
                } footer: {
                    if let p = profile {
                        Text(verbatim: T("Your Stremio library for the %@ profile", p.name))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("Stremio account"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(T("Sign out of Stremio?"), isPresented: $confirmOut, titleVisibility: .visible) {
            Button(T("Sign out"), role: .destructive) { signOut() }
                .accessibilityIdentifier("stremio-sign-out-confirm")
            Button(T("Cancel"), role: .cancel) {}
        }
        .onAppear { refresh() }
        .accessibilityIdentifier("settings-stremio")
    }

    private func refresh() {
        guard let p = profile else { session = nil; return }
        session = profiles.stremioSession(for: p.id)
    }

    private func signOut() {
        guard let p = profile else { return }
        profiles.setStremioSession(nil, for: p.id)
        PhoneFeedback.shared.selection()
        refresh()
    }

    private func signIn() async {
        guard let p = profile else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let result = try await StremioAPI.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            profiles.setStremioSession(ProfilesStore.StremioSession(authKey: result.authKey, user: result.user), for: p.id)
            password = ""
            PhoneFeedback.shared.success()
            refresh()
        } catch {
            failure = error.localizedDescription
            PhoneFeedback.shared.failure()
        }
    }
}
