import Foundation

/// The addon links the phone takes in (typed, pasted, scanned, handed back by a setup page or
/// opened from another app), turned into the https manifest URL the engine reads.
///
/// - `stremio://host/path/manifest.json` is Stremio's install form of `https://host/path/manifest.json`.
/// - A link inside other text (a message, a QR payload with a label) is picked out.
/// - A web.stremio.com install link (`#/addons?addon=<encoded manifest url>`) gives the URL it carries.
enum PhoneAddonLink {
    /// The manifest URL in `raw`, or nil when there is no http(s) / stremio link with a host in it.
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = firstLink(in: text) else { return nil }
        var link = token
        if link.lowercased().hasPrefix("stremio://") {
            link = "https://" + link.dropFirst("stremio://".count)
        }
        if let carried = carriedAddon(in: link) { link = carried }
        // URL(string:) percent-encodes what a URL can't hold as typed (a raw `{` in a configured path).
        guard let url = URL(string: link), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        return parts.string
    }

    /// True when the path ends in manifest.json (the URL is an addon, not its setup page).
    static func isManifest(_ url: String) -> Bool {
        guard let path = URLComponents(string: url)?.path else { return false }
        return path.lowercased().hasSuffix("/manifest.json")
    }

    /// The addon's base, as the catalogs page keys it (engine/addonsRoom.ts bpAddonBase): the
    /// transport URL without `/manifest.json` and without a trailing slash.
    static func base(of transportUrl: String) -> String {
        var url = transportUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.lowercased().hasSuffix("/manifest.json") { url.removeLast("/manifest.json".count) }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// The first `stremio://`, `https://` or `http://` token in the text.
    private static func firstLink(in text: String) -> String? {
        let starts = ["stremio://", "https://", "http://"].compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
        guard let start = starts.min() else { return nil }
        let rest = text[start...]
        let end = rest.firstIndex { $0.isWhitespace || $0 == "<" || $0 == ">" } ?? rest.endIndex
        var token = String(rest[..<end])
        // A link at the end of a sentence or in quotes keeps the full stop, bracket or quote out.
        while let last = token.last, ".,;:)]\"'".contains(last) { token.removeLast() }
        return token
    }

    /// web.stremio.com/#/addons?addon=<manifest url>: the URL after `addon=`.
    private static func carriedAddon(in link: String) -> String? {
        guard let hash = link.range(of: "#") else { return nil }
        let fragment = String(link[hash.upperBound...])
        guard let query = fragment.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        let items = URLComponents(string: "x:?" + query)?.queryItems ?? []
        guard let value = items.first(where: { $0.name == "addon" })?.value, !value.isEmpty else { return nil }
        // queryItems has already decoded it once; the manifest URL's own escapes stay as they are.
        return value.lowercased().hasPrefix("stremio://") ? "https://" + value.dropFirst("stremio://".count) : value
    }
}

/// A SwiftUI `onMove` turned into the organizer's move: `onMove` gives the gap the row is dropped
/// into (an offset in the list before the move), AddonOrganizeModel.move the index it ends up at.
enum PhoneAddonOrder {
    static func target(from: Int, toOffset offset: Int) -> Int {
        offset > from ? offset - 1 : offset
    }
}
