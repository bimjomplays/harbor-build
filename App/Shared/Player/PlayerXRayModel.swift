import SwiftUI

/// X-Ray (components/player/xray/*, lib/xray/use-xray-cast.ts; settings.xrayEnabled, off by
/// default): while the viewer is paused, the cast of what is playing, each card opening the
/// person page, with "View all" for the Cast / Crew / About browser.
///
/// Upstream shows a small "X-Ray" button while the chrome is up and opens the rail from it; its
/// rail leads with the faces matched on screen (lib/face, on-device ONNX models) and falls back to
/// the cast list. The TV has no face engine, so the rail is that cast list, it opens as the viewer
/// pauses (the button comes back once it is closed), and the browser has no "In scene" tab. Data
/// comes from the engine's `xray.load` (engine/xray.ts).
@MainActor
final class PlayerXRayModel: ObservableObject {
    struct Person: Decodable, Hashable {
        /// TMDB person id (TVDB's fallback cast carries negative ids, as upstream's does).
        var id: Int
        var name: String
        var sub: String?
        var photo: String?
        var initials: String
        var key: String
    }
    struct Fact: Decodable, Hashable { var label: String; var value: String }
    struct Video: Decodable, Hashable { var ytId: String; var name: String; var thumb: String }
    struct About: Decodable {
        var title: String
        var logo: String?
        var tagline: String?
        var overview: String?
        var genres: [String]
        var year: String?
        var runtime: String?
        var rating: String?
        var votes: String?
        var status: String?
        var facts: [Fact]
        var hero: String?
        var videos: [Video]
        var strip: [String]
        var showStrip: Bool
    }
    struct Tab: Decodable, Hashable { var id: String; var label: String }
    struct EmptyLabels: Decodable { var details: String; var cast: String; var crew: String }
    struct Payload: Decodable {
        var needsTmdbKey: Bool
        var hasDetails: Bool
        var rail: [Person]
        var cast: [Person]
        var crew: [Person]
        var about: About?
        var tabs: [Tab]
        var initialTab: String?
        var railStatus: String?
        var empty: EmptyLabels
    }

    @Published private(set) var payload: Payload?
    @Published private(set) var loading = false
    /// The engine call failed (an engine error or an answer that would not decode): the
    /// rail and the browser said "Reading the cast" with a spinner for as long as the pause lasted.
    @Published private(set) var failed = false
    /// The overlay is rebuilt on every pause; the last title's answer shows at once.
    private static var last: (metaId: String, payload: Payload)?

    func load(_ meta: Meta) async {
        if let hit = Self.last, hit.metaId == meta.id { payload = hit.payload; failed = false; return }
        loading = true
        failed = false
        defer { loading = false }
        let p = ProfilesStore.shared.active
        let got: Payload? = try? await HarborEngine.shared.call("xray.load", [meta, p?.id ?? "default", p?.linked ?? true])
        if let got {
            payload = got
            // Only a full answer is kept: a failed TMDB lookup or a missing key must be asked again
            // (the engine caches its own successes for ten minutes).
            if got.hasDetails && !got.needsTmdbKey { Self.last = (meta.id, got) }
        } else if payload == nil {
            failed = true
        }
    }
}
