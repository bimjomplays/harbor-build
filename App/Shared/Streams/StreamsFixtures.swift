import Foundation

/// Fake stream search answers for the simulator: `--fixtures <stage> --fixture-streams` makes
/// StreamsModel take these instead of the engine's search, resolve, P2P consent, auto candidates
/// and remembered pick, so a UI test can open the picker on a title and read real rows (three
/// addons, 4K to 480p, cached and not) without addons or a debrid. `--fixture-streams empty`
/// lists nothing, for the empty state. Nothing here runs without that flag: a plain `--fixtures`
/// launch (every TV test) still searches through the engine.
extension StreamsModel {
    @MainActor static var usesFixtures: Bool {
        Fixtures.active && !Fixtures.liveRooms && ProcessInfo.processInfo.arguments.contains("--fixture-streams")
    }

    @MainActor private static var fixtureEmpty: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fixture-streams"), i + 1 < args.count else { return false }
        return args[i + 1] == "empty"
    }

    /// The addons the fixture streams come from, in installed order.
    private static let fixtureAddons: [(id: String, name: String, url: String)] = [
        ("fx.torrentio", "Torrentio", "https://fixtures.harbor.invalid/torrentio/manifest.json"),
        ("fx.comet", "Comet", "https://fixtures.harbor.invalid/comet/manifest.json"),
        ("fx.mediafusion", "MediaFusion", "https://fixtures.harbor.invalid/mediafusion/manifest.json"),
    ]

    /// One stream, shaped as engine/streams.ts stamps it (stampPickerRows, pickerRowLabels).
    private static func fixtureStream(key: String, addon: Int, native: Int, title: String, resolution: String, source: String,
                                      codec: String, hdr: String?, audio: String, channels: Double, languages: [String],
                                      sizeGB: Double, seeders: Double?, cached: Bool, hash: Bool, quality: String,
                                      formats: [(String, String, String)], score: Double) -> [String: Any] {
        let a = fixtureAddons[addon]
        let availability: String = cached ? "cached" : (hash ? "p2p" : "cache")
        let summary: [String] = [resolution, source, codec, hdr, audio].compactMap { $0 }
        var labels: [String: Any] = [
            "quality": quality, "confidence": "labeled",
            "badges": formats.dropFirst().map { $0.2 },
            "formats": formats.map { ["kind": $0.0, "file": $0.1, "text": $0.2] },
            "cached": cached, "availability": availability,
        ]
        if cached { labels["cachedOn"] = ["name": "Real-Debrid", "owned": false] }
        var s: [String: Any] = [
            "parsedTitle": title, "title": title, "name": a.name, "resolution": resolution, "codec": codec, "source": source,
            "audio": ["codec": audio, "channels": channels], "audioLanguages": languages,
            "size": sizeGB * 1_073_741_824, "releaseGroup": String(title.split(separator: "-").last ?? ""),
            "remux": source == "Remux", "score": score, "tier": cached ? "cached" : "uncached",
            "addonName": a.name, "addonId": a.id, "addonUrl": a.url, "nativeIdx": native,
            "tvRow": ["headline": title, "detail": summary.joined(separator: " · "),
                      "description": summary.joined(separator: " · ") + "\n" + String(format: "%.1f GB", sizeGB),
                      "filename": title + ".mkv"],
            "tvFilters": [String](), "tvCached": cached,
            "tvSort": ["watchHub": false, "needsDownload": !cached && !hash, "instant": cached],
            "tvKey": key, "tvLabels": labels, "tvModes": ["addons": !hash || cached, "p2p": hash], "tvLang": true,
        ]
        if let hdr { s["hdrFormat"] = hdr }
        if let seeders { s["seeders"] = seeders }
        if cached { s["cached"] = ["realdebrid": true]; s["url"] = "https://fixtures.harbor.invalid/stream/\(key).mkv" }
        if hash { s["infoHash"] = String(repeating: String(key.suffix(1)), count: 40) }
        return s
    }

    private static var fixtureStreams: [[String: Any]] {
        let uhd = ("4k-uhd", "4k_uhd.webp", "4K UHD"), fhd = ("1080p", "1080p_fhd.webp", "1080p"), hd = ("720p", "720p_hd.webp", "720p")
        let remux = ("remux", "remux.png", "REMUX"), dv = ("dv", "dv.webp", "Dolby Vision"), hdr10p = ("hdr10-plus", "hdr10plus.webp", "HDR10+")
        let atmos = ("atmos", "atmos.webp", "Atmos"), ddp = ("ddp", "ddplus.png", "DD+"), dtshd = ("dts-hd", "dtshd.webp", "DTS-HD")
        let hevc = ("hevc", "hevc.png", "HEVC"), av1 = ("av1", "av1.png", "AV1"), webdl = ("webdl", "webdl.png", "WEB-DL")
        let bluray = ("bluray", "bluray.png", "Blu-ray"), aac = ("aac", "aac.png", "AAC"), hdtv = ("hdtv", "hdtv.png", "HDTV")
        return [
            fixtureStream(key: "fx-1", addon: 0, native: 0, title: "Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HEVC.Atmos-FGT",
                          resolution: "2160p", source: "Remux", codec: "HEVC", hdr: "DV", audio: "Atmos", channels: 8,
                          languages: ["English", "Multi"], sizeGB: 71.4, seeders: 412, cached: true, hash: true, quality: "4K",
                          formats: [uhd, remux, dv, atmos, hevc], score: 98),
            fixtureStream(key: "fx-2", addon: 0, native: 1, title: "Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.HDR10+.HEVC-FLUX",
                          resolution: "2160p", source: "WEB-DL", codec: "HEVC", hdr: "HDR10+", audio: "DD+", channels: 6,
                          languages: ["English"], sizeGB: 18.2, seeders: 230, cached: true, hash: true, quality: "4K",
                          formats: [uhd, webdl, hdr10p, ddp, hevc], score: 91),
            fixtureStream(key: "fx-3", addon: 1, native: 0, title: "Dune.Part.Two.2024.1080p.BluRay.DTS-HD.MA.7.1.x264-SPARKS",
                          resolution: "1080p", source: "BluRay", codec: "AVC", hdr: nil, audio: "DTS-HD MA", channels: 8,
                          languages: ["English", "French", "German"], sizeGB: 14.6, seeders: 188, cached: true, hash: true, quality: "1080p",
                          formats: [fhd, bluray, dtshd], score: 84),
            fixtureStream(key: "fx-4", addon: 1, native: 1, title: "Dune.Part.Two.2024.1080p.WEB-DL.DDP5.1.HEVC-NTb",
                          resolution: "1080p", source: "WEB-DL", codec: "HEVC", hdr: nil, audio: "DD+", channels: 6,
                          languages: ["English", "Spanish"], sizeGB: 5.1, seeders: 96, cached: false, hash: true, quality: "1080p",
                          formats: [fhd, webdl, ddp, hevc], score: 70),
            fixtureStream(key: "fx-5", addon: 2, native: 0, title: "Dune.Part.Two.2024.1080p.WEBRip.AV1.AAC-Kitsune",
                          resolution: "1080p", source: "WEBRip", codec: "AV1", hdr: nil, audio: "AAC", channels: 2,
                          languages: ["English", "Japanese"], sizeGB: 2.4, seeders: 41, cached: true, hash: true, quality: "1080p",
                          formats: [fhd, av1, aac], score: 66),
            fixtureStream(key: "fx-6", addon: 2, native: 1, title: "Dune.Part.Two.2024.720p.WEB-DL.AAC.x264-EVO",
                          resolution: "720p", source: "WEB-DL", codec: "AVC", hdr: nil, audio: "AAC", channels: 2,
                          languages: ["English"], sizeGB: 1.6, seeders: nil, cached: false, hash: false, quality: "720p",
                          formats: [hd, webdl, aac], score: 52),
            fixtureStream(key: "fx-7", addon: 0, native: 2, title: "Dune.Part.Two.2024.720p.HDTV.x264-ITA-ENG",
                          resolution: "720p", source: "HDTV", codec: "AVC", hdr: nil, audio: "DD", channels: 6,
                          languages: ["Italian", "English"], sizeGB: 1.1, seeders: 12, cached: false, hash: true, quality: "720p",
                          formats: [hd, hdtv], score: 40),
        ]
    }

    /// engine streamsRoom.search's answer: the whole list at once, after a short beat so the
    /// loading state shows.
    @MainActor static func fixtureSearch(token: String) async throws -> SearchResult {
        try? await Task.sleep(for: .milliseconds(700))
        let streams: [[String: Any]] = fixtureEmpty ? [] : fixtureStreams
        let ids: [String] = fixtureAddons.map(\.id)
        var picker: [String: Any] = ["all": streams]
        if let first = streams.first { picker["primary"] = first }
        let body: [String: Any] = [
            "token": token, "imdb": ["id": "tt15239678", "verified": true], "streamIds": ids,
            "addonCount": ids.count, "addonOrder": fixtureAddons.map(\.url), "debridCount": 1,
            "seasonLock": false, "addonRanked": false,
            "setup": ["streamAddonIds": ids, "preferredLangs": [String](), "langLabel": "", "langFilterDefault": false, "isAnime": false],
            "result": ["picker": picker, "debridErrors": [[String: Any]]()],
        ]
        let data: Data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(SearchResult.self, from: data)
    }

    /// engine streamsRoom.resolve: a link for every stream but the one that needs a debrid fetch
    /// first (fx-6), which fails as a dead source would, for "Unavailable, try another."
    @MainActor static func fixtureResolved(_ stream: ScoredStream) async -> Resolved {
        try? await Task.sleep(for: .milliseconds(450))
        let key: String = stream.tvKey ?? "fx"
        guard key != "fx-6" else { return Resolved(ok: false, data: nil, via: nil, code: "not-cached", debridFailure: false) }
        let name: String = (stream.tvRow?.filename).flatMap { $0.isEmpty ? nil : $0 } ?? key + ".mkv"
        let link = Resolved.Link(url: "https://fixtures.harbor.invalid/play/\(key).mkv", filename: name, headers: nil, notWebReady: nil, subtitles: nil)
        return Resolved(ok: true, data: link, via: "fixture", code: nil)
    }

    /// use-auto-candidates: the cached streams, best first.
    static func fixtureAutoKeys(_ streams: [ScoredStream]) -> [String] {
        streams.filter(\.isCached).sorted { $0.score > $1.score }.compactMap(\.tvKey)
    }
}
