import SwiftUI

/// About: boots the shared engine (`HarborEngine`, compiled straight from App/Shared/Engine) and
/// shows what `EngineSmoke` reports, the proof that JavaScriptCore runs the bundle on iPhone. Pushed
/// from the account sheet, so it sits inside that sheet's navigation stack.
@MainActor
final class EngineStatusModel: ObservableObject {
    enum State: Equatable {
        case booting
        case booted(milliseconds: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .booting
    @Published private(set) var lines: [String] = []
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        let began = Date()
        // The boot evaluates a ~4 MB bundle: keep it off the main thread, as the TV does.
        let boot = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                _ = try HarborEngine.sharedOrThrow()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch boot {
        case .success:
            state = .booted(milliseconds: Int(Date().timeIntervalSince(began) * 1000))
        case .failure(let error):
            state = .failed("\(error)")
            return
        }
        lines = await EngineSmoke.run()
    }
}

struct EngineStatusView: View {
    @StateObject private var model = EngineStatusModel()

    private var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    private var statusText: String {
        switch model.state {
        case .booting: return "Engine starting…"
        case .booted(let milliseconds): return "Engine booted in \(milliseconds) ms"
        case .failed(let message): return "Engine failed: \(message)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PhoneMark(size: 72)
                    .padding(.top, 24)
                PhoneWordmark(size: 34)
                Text("Build \(build)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("build-label")
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusText)
                        .font(.headline)
                        .accessibilityIdentifier("engine-status")
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(.horizontal, 16)
            }
        }
        .background(PhoneBackground())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
    }
}
