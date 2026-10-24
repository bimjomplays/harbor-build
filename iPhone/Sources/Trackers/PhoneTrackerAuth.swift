import Foundation

/// The trackers the TV's Settings signs in to (SettingsView: Trakt, Simkl, AniList, MyAnimeList,
/// Letterboxd), in its order, with how each one signs in. The sessions are the engine's (the same
/// secret store and settings the TV's TraktModel / PasteTrackerModel / LetterboxdModel read), so a
/// tracker connected here behaves as it does on the TV.
enum PhoneTracker: String, CaseIterable, Identifiable {
    case trakt, simkl, anilist, mal, letterboxd

    enum Flow {
        /// Trakt (lib/trakt/device-auth.ts) and Simkl (lib/simkl/device-auth.ts): a code the viewer
        /// approves on the tracker's site while the app polls (TraktModel).
        case deviceCode
        /// AniList and MyAnimeList (lib/anilist/auth.ts, lib/mal/auth.ts): the authorize page hands
        /// back a code that is exchanged through Harbor's token proxy (PasteTrackerModel).
        case authorizeCode
        /// Letterboxd (settings/letterboxd-panel.tsx public mode): a username checked against Stremboxd.
        case username
    }

    var id: String { rawValue }

    /// The engine export prefix (`trakt.status`, `anilist.disconnect`, …) and the Library tab id.
    var service: String { rawValue }

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        case .letterboxd: return "Letterboxd"
        }
    }

    var flow: Flow {
        switch self {
        case .trakt, .simkl: return .deviceCode
        case .anilist, .mal: return .authorizeCode
        case .letterboxd: return .username
        }
    }

    var systemImage: String {
        switch self {
        case .trakt: return "dot.radiowaves.left.and.right"
        case .simkl: return "checkmark.circle"
        case .anilist: return "sparkles.tv"
        case .mal: return "list.star"
        case .letterboxd: return "film.stack"
        }
    }

    /// What the tracker feeds, the TV panels' "Not connected" lines (translated).
    var blurb: String {
        switch self {
        case .trakt, .simkl: return T("Scrobbling, watchlist and history")
        case .anilist, .mal: return T("Your %@ lists in the Anime room and the Library", label)
        case .letterboxd: return T("Your watchlist shows in the Library, and your Letterboxd rows on Movies.")
        }
    }

    /// engine/trackers.ts ANILIST_RAILS / MAL_RAILS: the list rails a Home row can show.
    var homeRails: [(key: String, title: String)] {
        switch self {
        case .anilist: return HomeSourceRegistry.anilistRails
        case .mal: return HomeSourceRegistry.malRails
        default: return []
        }
    }

    /// The Home row source of one of `homeRails`.
    func homeSource(railKey: String) -> HomeRowSource? {
        switch self {
        case .anilist: return .anilistList(railKey: railKey)
        case .mal: return .malList(railKey: railKey)
        default: return nil
        }
    }
}

/// One tracker's sign-in, from the engine's `<service>.status` (or `letterboxd.status`).
enum PhoneTrackerState: Equatable {
    case signedOut
    case connected(username: String?)
    /// A session is stored but expired or could not be renewed; it is kept, and signing out
    /// still clears it.
    case reconnect(username: String?)

    init(authenticated: Bool, username: String?, reconnect: Bool?) {
        let name = username.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if reconnect == true {
            self = .reconnect(username: name)
        } else if authenticated {
            self = .connected(username: name)
        } else {
            self = .signedOut
        }
    }

    /// Whether there is a session to sign out of.
    var hasSession: Bool { self != .signedOut }

    var username: String? {
        switch self {
        case .signedOut: return nil
        case .connected(let name), .reconnect(let name): return name
        }
    }

    /// The row's status line: the TV panels' "Connected as …", "Reconnect needed", "Not connected".
    func title(for tracker: PhoneTracker) -> String {
        switch self {
        case .signedOut: return T("Not connected")
        case .reconnect: return T("Reconnect needed")
        case .connected(let name):
            // trakt-device-modal.tsx says "@name"; the others the bare name.
            guard let name else { return T("Connected to %@", tracker.label) }
            return tracker == .trakt ? T("Connected as @%@", name) : T("Connected as %@", name)
        }
    }
}

/// The phone's in-place sign-in (: the TV's QR hand-off becomes a web auth
/// sheet): the URL the sheet opens, and what comes back from it.
enum PhoneTrackerAuth {
    /// The callback scheme the web auth sheet listens for. No tracker redirects to it today (AniList's
    /// redirect is its own PIN page, MyAnimeList's Harbor's server), so the viewer copies the code off
    /// the page; a redirect that does come back here is read without a paste.
    static let callbackScheme = "harbor-auth"

    enum Callback: Equatable {
        case code(String)
        /// The service said no (`error=access_denied`, …), with its description when it gave one.
        case denied(String?)
        case invalid
    }

    /// An OAuth redirect: `code=` in the query or the fragment (implicit-style redirects put it
    /// there), else `error=` / `error_description=`.
    static func parseCallback(_ url: URL) -> Callback {
        var items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment, !fragment.isEmpty {
            var f = URLComponents()
            f.percentEncodedQuery = fragment
            items += f.queryItems ?? []
        }
        let value = { (name: String) -> String? in
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        if let error = value("error"), !error.isEmpty {
            let detail = value("error_description").map { $0.replacingOccurrences(of: "+", with: " ") }
            return .denied(detail?.isEmpty == false ? detail : nil)
        }
        return .invalid
    }

    /// A pasted code: the whole page address (anything with `code=`) or the bare code, quotes and
    /// spaces trimmed. lib/anilist/auth.ts extractAnilistCode / lib/mal/auth.ts extractMalCode, which
    /// the engine runs again on what it is handed.
    static func code(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: #"[?&#]code=([^&\s#]+)"#, options: .regularExpression) {
            let raw = String(trimmed[range].drop { $0 != "=" }.dropFirst())
            let code = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespaces)
            return code.isEmpty ? nil : code
        }
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n"))
        return bare.isEmpty ? nil : bare
    }

    /// Where the viewer approves a device code. Simkl's PIN page takes the code in its path
    /// (lib/simkl/device-auth.ts deepLinkUrl: `https://simkl.com/pin/<code>`), so nothing is typed;
    /// Trakt's activation page is opened as the service sent it and the code is copied for pasting.
    static func approvalURL(for tracker: PhoneTracker, userCode: String, verificationUrl: String) -> URL? {
        let code = userCode.trimmingCharacters(in: .whitespaces)
        if tracker == .simkl, !code.isEmpty,
           let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "https://simkl.com/pin/\(escaped)")
        }
        return webURL(verificationUrl)
    }

    /// Whether a device-code sign-in just ended (TraktModel's code went from one to none: approved,
    /// denied, expired or cancelled), so the tracker's state is read again. Not gated on the shared
    /// model's own `status`: its poll clears the code before it re-reads that status, so on the
    /// change it still says signed out.
    static func deviceCodeEnded(from old: String?, to new: String?) -> Bool {
        old != nil && new == nil
    }

    /// Only http(s) pages go to the web auth sheet; an empty or odd address opens nothing.
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The engine's error line without the bridge's prefixes (TraktModel / PasteTrackerModel do the same).
    static func engineMessage(_ error: Error) -> String? {
        let text = "\(error)".replacingOccurrences(of: "JS error: ", with: "")
        let line = text.split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "")
        return line?.isEmpty == false ? line : nil
    }
}

/// When each tracker's lists were last fetched from the phone (Sync now, or a sign-in's first read).
/// Kept in the app's defaults, never with the session: no token is ever written here.
struct PhoneTrackerSyncLog {
    let defaults: UserDefaults
    static let keyPrefix = "phone.trackers.synced."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func date(for tracker: PhoneTracker) -> Date? {
        let t = defaults.double(forKey: Self.keyPrefix + tracker.rawValue)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func record(_ tracker: PhoneTracker, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.keyPrefix + tracker.rawValue)
    }

    func clear(_ tracker: PhoneTracker) {
        defaults.removeObject(forKey: Self.keyPrefix + tracker.rawValue)
    }

    /// "Never synced", "Synced just now" (under a minute), else "Synced 5 minutes ago".
    static func text(_ date: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let date else { return T("Never synced") }
        if now.timeIntervalSince(date) < 60 { return T("Synced just now") }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .full
        return T("Synced %@", f.localizedString(for: date, relativeTo: now))
    }
}
