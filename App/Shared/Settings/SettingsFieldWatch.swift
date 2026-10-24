import SwiftUI

/// Bumps `tick` (debounced 250 ms) when harbor:settings-updated names a field
/// `wants` accepts, or names none: a panel that reads its state once re-reads what profile sync
/// (or another screen) changed while it is open.
@MainActor
final class SettingsFieldWatch: ObservableObject {
    struct Detail: Decodable { var fields: [String]? }
    @Published private(set) var tick = 0
    private var unsubscribe: (() -> Void)?
    private var pending: Task<Void, Never>?

    init(_ wants: @escaping (String) -> Bool) {
        unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
            guard type == "harbor:settings-updated" else { return }
            let decoded: Detail? = detail.flatMap { try? $0.decode(Detail.self) }
            if let fields = decoded?.fields, !fields.contains(where: wants) { return }
            Task { @MainActor in self?.bump() }
        }
    }

    deinit { pending?.cancel(); unsubscribe?() }

    private func bump() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.tick &+= 1
        }
    }
}
