import AuthenticationServices
import UIKit

/// The web auth sheet (ASWebAuthenticationSession) a tracker's sign-in page opens in: the phone's
/// in-place stand-in for the TV's "scan the QR code on your phone". It shares Safari's cookies, so a
/// viewer already signed in to the tracker only has to approve. `close()` takes the sheet down when
/// the app learns the outcome some other way (a device code's poll said yes).
@MainActor
final class PhoneWebAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isOpen = false
    private var session: ASWebAuthenticationSession?
    /// Which open() the current session belongs to.
    private var generation = 0
    private var pending: CheckedContinuation<URL?, Error>?

    /// Opens `url` and returns the callback URL it redirected to, or nil when the sheet closed
    /// without one (the viewer's Cancel, or `close()`). An open sheet is closed first.
    func open(_ url: URL, callbackScheme: String = PhoneTrackerAuth.callbackScheme) async throws -> URL? {
        close()
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            generation &+= 1
            let mine = generation
            let s = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callback, error in
                Task { @MainActor in
                    // A cancelled session's late handler must not resolve a newer open().
                    guard let self, self.generation == mine, self.session != nil else { return }
                    if let callback {
                        self.finish(.success(callback))
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        self.finish(.success(nil))
                    } else if let error {
                        self.finish(.failure(error))
                    } else {
                        self.finish(.success(nil))
                    }
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            isOpen = true
            if !s.start() { finish(.success(nil)) }
        }
    }

    /// Takes the sheet down; a waiting `open` returns nil.
    func close() {
        session?.cancel()
        finish(.success(nil))
    }

    private func finish(_ result: Result<URL?, Error>) {
        session = nil
        isOpen = false
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
