import Foundation

/// A resolved stream link as a URL. Some addons hand back links with spaces or other
/// characters a URL can't hold. The tvOS 17 SDK's `URL(string:)` already escapes most of those;
/// this also escapes a stray `%` and trims whitespace, keeping the `%XX` escapes already in the
/// link so nothing is encoded twice. nil when no absolute URL can be made of it.
enum PlayableURL {
    static func make(_ raw: String) -> URL? {
        if let u = URL(string: raw), u.scheme != nil { return u }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        // A `%` that does not start an escape is itself escaped; existing escapes stay as they are.
        let percents = trimmed.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "%#[]")
        guard let encoded = percents.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: encoded), u.scheme != nil else { return nil }
        return u
    }
}
