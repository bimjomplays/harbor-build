import SwiftUI
import UIKit

/// The phone's answer to `Platform.feedback` (App/Shared/App/Platform.swift): UIKit haptics instead of
/// the TV's sound effects. The shared code only needs `audition`; screens call the rest directly.
@MainActor
final class PhoneFeedback: Feedback {
    static let shared = PhoneFeedback()
    var audition: String?

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    /// A choice moved: a tab, a chip, a profile.
    func selection() { selectionGenerator.selectionChanged() }
    /// A press landed: a tile, a key.
    func tap() { impactGenerator.impactOccurred() }
    func success() { notificationGenerator.notificationOccurred(.success) }
    func warning() { notificationGenerator.notificationOccurred(.warning) }
    func failure() { notificationGenerator.notificationOccurred(.error) }
}

/// Which sheets and covers are up over the shell. Read by `PhoneHooks.mainWindowUncovered` (a deep
/// link waits for a clear shell) and by the root, which holds a theme or language rebuild while one
/// is up: the rebuild would drop the sheet's state with nothing to show for it (the TV's CoverPresence).
@MainActor
final class PhonePresence: ObservableObject {
    static let shared = PhonePresence()
    @Published private(set) var covers: Set<String> = []
    var coverUp: Bool { !covers.isEmpty }

    func enter(_ id: String) { covers.insert(id) }
    func leave(_ id: String) { covers.remove(id) }
}

private struct PresentedCover: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .onAppear { PhonePresence.shared.enter(id) }
            .onDisappear { PhonePresence.shared.leave(id) }
    }
}

extension View {
    /// Marks this view as a sheet or cover that is up while it is on screen.
    func presentedCover(_ id: String) -> some View {
        modifier(PresentedCover(id: id))
    }
}

/// `Platform.hooks` for the phone: no screensaver, no PiP browse layer, one window. A sheet over the
/// shell is what "covered" means here.
@MainActor
struct PhoneHooks: PlatformHooks {
    var screensaverActive: Bool { false }
    func wakeScreensaver() {}
    var mainWindowUncovered: Bool { !PhonePresence.shared.coverUp }
    var pipBrowseUp: Bool { false }
    func pipLayerUncovered(for app: AppModel) -> Bool { false }
    func installActivityMonitor() {}
}
