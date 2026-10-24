import Foundation

/// A video player app Harbor can hand a stream to. Only players
/// whose URL scheme the vendor documents are listed; each case cites the page its format comes from.
/// Not listed, for want of a vendor page with the format (checked 2026-10-18): Outplayer (only a
/// developer's reply on X and App Store release notes), nPlayer and SenPlayer (third-party write-ups only).
/// Every scheme here is also in the HarborPhone Info.plist's LSApplicationQueriesSchemes (project.yml),
/// which `UIApplication.canOpenURL` needs to say whether the app is installed.
enum ExternalPlayer: String, CaseIterable, Identifiable, Sendable {
    /// Firecore, "API for Third-Party Apps & Services": https://support.firecore.com/hc/en-us/articles/215090997
    /// `infuse://x-callback-url/play?url=…&position=…&filename=…&sub=…&x-success=…&x-error=…`; every
    /// query value url-encoded. x-success comes back with `lastPlayedUrl` and `position` (seconds).
    case infuse
    /// VideoLAN wiki, "Documentation:IOS", Integration with third party apps (VLC 2.4+):
    /// https://wiki.videolan.org/Documentation:IOS/ — `vlc-x-callback://x-callback-url/stream?url=…`
    /// with optional `x-success` and `x-error` (2.5+). No subtitle or start position parameter.
    case vlc
    /// Oka Apps, "Play Videos in VidHub from Third-Party Apps and Services":
    /// https://vidhub.okaapps.com/3rd-party-app-integration/ — the `/play` method (the page says new
    /// integrations use it): `open-vidhub://x-callback-url/play?url=…&position=…&filename=…&sub=…`
    /// with `x-success` (`position`, `duration`, `status`), `x-error`, `x-cancel`, `x-source`.
    case vidhub

    var id: String { rawValue }

    var name: String {
        switch self {
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        case .vidhub: return "VidHub"
        }
    }

    /// The scheme `canOpenURL` asks about (and LSApplicationQueriesSchemes lists).
    var scheme: String {
        switch self {
        case .infuse: return "infuse"
        case .vlc: return "vlc-x-callback"
        case .vidhub: return "open-vidhub"
        }
    }

    /// A URL with only the scheme, for `canOpenURL`.
    var probeURL: URL { URL(string: "\(scheme)://")! }

    /// Whether the player takes a start position (Harbor's resume spot).
    var takesPosition: Bool { self != .vlc }
    /// Whether the player takes one external subtitle URL.
    var takesSubtitle: Bool { self != .vlc }

    /// What goes to the player: the stream, and what the player can take of the rest.
    struct Request: Equatable {
        var url: URL
        var subtitle: URL? = nil
        /// The file's name (helps Infuse's metadata) or the title to show.
        var filename: String? = nil
        /// Whole seconds; nil or 0 starts at the beginning.
        var positionSec: Int? = nil
        /// Where the player goes back to when playback ends (x-success, and VidHub's x-cancel).
        var onSuccess: URL? = nil
        /// Where the player goes back to when it cannot play (x-error).
        var onError: URL? = nil
    }

    /// The URL that opens `request` in this player. Every value is percent-encoded once, with only the
    /// RFC 3986 unreserved characters left as they are (Infuse: "all querystring values should be
    /// url-safe or encoded"; VidHub decodes each value once, so it must not be encoded twice).
    func playURL(_ request: Request) -> URL? {
        var items: [(String, String)] = [("url", request.url.absoluteString)]
        let position: Int? = request.positionSec.flatMap { $0 > 0 ? $0 : nil }
        switch self {
        case .infuse:
            if let p = position { items.append(("position", String(p))) }
            if let f = request.filename, !f.isEmpty { items.append(("filename", f)) }
            if let s = request.subtitle { items.append(("sub", s.absoluteString)) }
        case .vlc:
            break
        case .vidhub:
            // VidHub checks the position: 0 to 31536000 seconds.
            if let p = position, p <= 31_536_000 { items.append(("position", String(p))) }
            if let f = request.filename, !f.isEmpty { items.append(("filename", f)) }
            if let s = request.subtitle { items.append(("sub", s.absoluteString)) }
        }
        if let ok = request.onSuccess { items.append(("x-success", ok.absoluteString)) }
        if let bad = request.onError { items.append(("x-error", bad.absoluteString)) }
        if self == .vidhub {
            if let ok = request.onSuccess { items.append(("x-cancel", ok.absoluteString)) }
            items.append(("x-source", "Harbor"))
        }
        let action: String = self == .vlc ? "stream" : "play"
        let query: String = items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(scheme)://x-callback-url/\(action)?\(query)")
    }

    /// Percent-encodes everything but RFC 3986's unreserved characters (A-Z a-z 0-9 - . _ ~), so a
    /// stream URL's own `?`, `&`, `=`, `+` and `%` survive the trip as part of the one value.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()
}

/// Whether another app can play a stream Harbor resolved. An external player fetches the URL itself,
/// while Harbor may be suspended in the background, so only a plain http(s) address it can reach on
/// its own passes: not Harbor's in-app torrent or local server (gone once Harbor is in the background),
/// not a link that only works with request headers the player would never send.
enum ExternalReach: Equatable {
    case reachable(URL)
    /// Served by Harbor itself: the torrent engine or another local server.
    case local
    /// The link needs request headers (an addon's proxy headers, a home server's token).
    case needsHeaders
    /// A home-server copy: it reports progress to the server and keeps its session through Harbor.
    case homeServer
    /// Not an http(s) address.
    case notWeb

    /// Checks a resolved link. `via` is the resolve's `via` ("p2p" for the torrent engine).
    static func check(url raw: String, headers: [String: String]?, via: String?, homeServer: Bool) -> ExternalReach {
        if homeServer { return .homeServer }
        if via == "p2p" { return .local }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return .notWeb }
        if isLocalHost(host) { return .local }
        if let headers, headers.contains(where: { !$0.value.isEmpty }) { return .needsHeaders }
        return .reachable(url)
    }

    /// The loopback names and addresses (Harbor's own servers listen there).
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.")
    }

    /// Before resolving, from the row alone: a peer-to-peer row plays through Harbor's torrent engine,
    /// and an addon URL that is not http(s) (a magnet, an addon-specific scheme) is no use to a player.
    /// Everything else is worth a try; the resolved link is checked again (`check`).
    static func rowMayReach(availability: String?, url: String?) -> Bool {
        if availability == "p2p" { return false }
        guard let url else { return true }
        let scheme: String = URL(string: url)?.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    /// Why a stream stays in Harbor, for the picker's note.
    var reason: String? {
        switch self {
        case .reachable: return nil
        case .local: return T("Peer-to-peer streams play only in Harbor: they stop when Harbor is in the background.")
        case .needsHeaders: return T("This stream needs Harbor's own player: its link only works with extra request headers.")
        case .homeServer: return T("Home server copies play only in Harbor.")
        case .notWeb: return T("This stream's link can't be opened in another app.")
        }
    }
}
