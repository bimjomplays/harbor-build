import SwiftUI

/// Settings → About, as the TV's About section reads (advanced-panel/about-tab.tsx): the app and its
/// build, then the engine's own report (EngineStatusView, also under the account sheet's About).
struct PhoneAboutView: View {
    @EnvironmentObject private var app: AppModel

    private var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: T("Harbor for iPhone"))
                        .font(PhoneTheme.display(22, .semibold, relativeTo: .title2))
                    Text(verbatim: T("Build %@ · upstream beta-branch", build))
                        .font(PhoneTheme.sans(14, .regular, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-about-build")
                }
                .padding(.vertical, 4)
            }
            Section {
                NavigationLink {
                    EngineStatusView()
                } label: {
                    Label(T("Engine status"), systemImage: "cpu")
                }
                .accessibilityIdentifier("settings-about-engine")
            }
            // about-tab.tsx OnboardingRow: setup opens again over the app (AppModel.replayOnboarding); profiles,
            // sign-ins and settings stay.
            Section {
                Button {
                    PhoneFeedback.shared.tap()
                    app.replayOnboarding()
                } label: {
                    Label(T("Replay walkthrough"), systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("settings-replay-walkthrough")
            } footer: {
                Text(verbatim: T("Opens the welcome setup again. Your profiles, sign-ins and settings stay."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneBackground())
        .navigationTitle(T("About"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-about")
    }
}
