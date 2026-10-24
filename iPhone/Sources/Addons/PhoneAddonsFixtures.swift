import Foundation

/// The addon list a fixture launch (`--fixtures shell`, not `live`) works on: three installed
/// addons, a few community ones to browse, and one URL that installs (`installableUrl`). It answers
/// the addonsManager calls AddonsModel, AddonOrganizeModel and the phone's Addons screens make
/// (through `AddonsEngine.stub`), in the engine's shapes, so install, reorder and remove can be
/// tested without the network or a Stremio account. Nothing is kept past the launch.
@MainActor
final class PhoneAddonsFixtures {
    static let installableUrl = "https://fixture.example/community/manifest.json"
    static let setupUrl = "https://fixture.example/streams/configure"

    struct Addon {
        var id: String
        var name: String
        var url: String
        var description: String
        var types: [String]
        var configurable = false
        var enabled = true
    }

    private(set) var installed: [Addon]
    private let community: [Addon]

    init() {
        installed = [
            Addon(id: "com.linvo.cinemeta", name: "Cinemeta", url: "https://v3-cinemeta.strem.io/manifest.json",
                  description: "The official addon for movie and series catalogs", types: ["movie", "series"]),
            Addon(id: "org.stremio.opensubtitlesv3", name: "OpenSubtitles", url: "https://opensubtitles-v3.strem.io/manifest.json",
                  description: "Subtitles from OpenSubtitles", types: ["movie", "series"]),
            Addon(id: "example.fixture.streams", name: "Fixture Streams", url: "https://fixture.example/streams/manifest.json",
                  description: "A configurable fixture addon", types: ["movie"], configurable: true),
        ]
        community = [
            Addon(id: "example.fixture.community", name: "Fixture Community", url: Self.installableUrl,
                  description: "A community fixture addon", types: ["movie", "series"]),
            Addon(id: "example.fixture.anime", name: "Fixture Anime", url: "https://fixture.example/anime/manifest.json",
                  description: "Anime catalogs for the fixtures", types: ["anime"]),
        ]
    }

    /// Puts the fixture list behind AddonsModel on a fixture launch. Safe to call from every screen.
    static func installIfNeeded() {
        guard Fixtures.active, !Fixtures.liveRooms, AddonsEngine.stub == nil else { return }
        let fixtures = PhoneAddonsFixtures()
        AddonsEngine.stub = { path, args in try fixtures.answer(path, args) }
    }

    // MARK: answers

    struct Unknown: Error { let path: String }

    func answer(_ path: String, _ args: [AnyJSON]) throws -> AnyJSON {
        func arg(_ i: Int) -> AnyJSON { i < args.count ? args[i] : .null }
        switch path {
        case "addonsManager.load":
            return .object(["installed": .array(installed.enumerated().map { card($1, position: $0 + 1) }),
                            "installedCount": .number(Double(installed.count)), "total": .number(Double(installed.count)),
                            "cached": .bool(false)])
        case "addonsManager.categories":
            return .array([category("Streams", "http"), category("Metadata", "metadata"), category("Subtitles", "subtitles"),
                           category("Anime", "anime")])
        case "addonsManager.spotlight":
            return .object(["addon": card(community[0], position: 0), "trending": .bool(true)])
        case "addonsManager.rail":
            return .array(available.map { card($0, position: 0) })
        case "addonsManager.browse":
            let search = arg(2).string?.lowercased() ?? ""
            let found = community.filter { search.isEmpty || $0.name.lowercased().contains(search) }
            let page = arg(4).number ?? 1
            return .object(["items": .array(page > 1 ? [] : found.map { card($0, position: 0) }),
                            "hasMore": .bool(false), "empty": .string(found.isEmpty ? "search" : "none")])
        case "addonsManager.detail":
            guard let addon = find(id: arg(0).string ?? "") else { return .null }
            return detail(addon)
        case "addonsManager.install", "addonsManager.installDefault":
            guard let addon = find(id: arg(0).string ?? "") else { return outcomeError() }
            if addon.configurable && path == "addonsManager.install" {
                return .object(["kind": .string("configure"), "id": .string(addon.id), "name": .string(addon.name),
                                "configureUrl": .string(Self.setupUrl)])
            }
            add(addon)
            return .object(["kind": .string("installed"), "id": .string(addon.id), "name": .string(addon.name),
                            "toast": .string(T("Installed"))])
        case "addonsManager.resolveUrl":
            let raw = PhoneAddonLink.normalize(arg(0).string ?? "") ?? ""
            guard let addon = (community + installed).first(where: { $0.url == raw }) else {
                return .object(["error": .string(T("Couldn't read that addon URL."))])
            }
            let present = installed.contains { $0.id == addon.id }
            return .object(["url": .string(addon.url), "name": .string(addon.name), "logo": .null, "version": .string("1.0.0"),
                            "description": .string(addon.description), "matchKind": .string(present ? "id-match" : "fresh"),
                            "replaceId": .null, "replaceName": .null])
        case "addonsManager.installUrl":
            guard let addon = (community + installed).first(where: { $0.url == arg(0).string }) else {
                return .object(["ok": .bool(false), "message": .string(T("Install failed."))])
            }
            let replaced = installed.contains { $0.id == addon.id }
            add(addon)
            return .object(["ok": .bool(true), "replaced": .bool(replaced), "id": .string(addon.id), "name": .string(addon.name),
                            "logo": .null, "toast": .string(replaced ? T("Updated") : T("Installed locally"))])
        case "addonsManager.uninstall":
            let before = installed.count
            installed.removeAll { $0.id == arg(0).string }
            let ok = installed.count < before
            return .object(["ok": .bool(ok), "toast": .string(ok ? T("Removed") : T("Couldn't remove. Try again."))])
        case "addonStore.setAddonEnabled":
            if let i = installed.firstIndex(where: { $0.url == arg(0).string }) { installed[i].enabled = arg(1).bool ?? true }
            return .null
        case "addonsManager.organizeLoad":
            // Signed out: everything lives on this device.
            return .object(["ok": .bool(true), "signedIn": .bool(false), "cloud": .array([]),
                            "device": .array(installed.map(row)), "backups": .number(0)])
        case "addonsManager.organizeSave":
            let keys = arg(1).array?.compactMap(\.string) ?? []
            let byKey = Dictionary(uniqueKeysWithValues: installed.map { ($0.url, $0) })
            let ordered = keys.compactMap { byKey[$0] }
            guard ordered.count == installed.count else {
                return .object(["ok": .bool(false), "tone": .string("danger"), "text": .string("The list changed."), "reload": .bool(true)])
            }
            installed = ordered
            return .object(["ok": .bool(true), "scope": .string("device"), "toast": .string(T("Addon order saved on this device"))])
        case "addonsManager.organizeBackups":
            return .array([])
        case "addonsManager.organizeMoveAll":
            return .object(["ok": .bool(false), "text": .string(""), "reload": .bool(false)])
        case "addonsManager.ageGate":
            return .object(["questions": .array([
                question("How many days are in a week?", ["Five", "Seven", "Ten"], 1),
                question("Which of these is a fruit?", ["Apple", "Carrot", "Potato"], 0),
                question("What do you pay bills with?", ["Leaves", "Pebbles", "Money"], 2),
            ])])
        default:
            throw Unknown(path: path)
        }
    }

    // MARK: shapes

    private var available: [Addon] { community.filter { c in !installed.contains { $0.id == c.id } } }

    private func find(id: String) -> Addon? {
        installed.first { $0.id == id } ?? community.first { $0.id == id }
    }

    private func add(_ addon: Addon) {
        if let i = installed.firstIndex(where: { $0.id == addon.id }) { installed[i] = addon } else { installed.append(addon) }
    }

    private func card(_ a: Addon, position: Int) -> AnyJSON {
        let isInstalled = installed.contains { $0.id == a.id }
        let enabled = installed.first { $0.id == a.id }?.enabled ?? true
        return .object([
            "key": .string(a.url), "id": .string(a.id), "name": .string(a.name), "description": .string(a.description),
            "subtitle": .string(a.types.joined(separator: " · ")), "logo": .null, "background": .null,
            "transportUrl": .string(a.url), "configureUrl": .string(a.configurable ? Self.setupUrl : ""),
            "installed": .bool(isInstalled), "configurable": .bool(a.configurable),
            "types": .array(a.types.map(AnyJSON.string)), "stars": .number(12), "rising": .null, "risingWindow": .null,
            "isNew": .bool(false), "slug": .null, "enabled": .bool(enabled), "position": .number(Double(position)),
        ])
    }

    private func row(_ a: Addon) -> AnyJSON {
        .object(["key": .string(a.url), "name": .string(a.name), "host": .string(URL(string: a.url)?.host ?? ""),
                 "addonId": .string(a.id), "logo": .null])
    }

    private func detail(_ a: Addon) -> AnyJSON {
        let catalogs: [AnyJSON] = a.types.contains("anime") || a.name == "OpenSubtitles" ? [] : [
            .object(["name": .string("Popular"), "type": .string(a.types.first ?? "movie")]),
        ]
        return .object([
            "card": card(a, position: (installed.firstIndex { $0.id == a.id } ?? -1) + 1),
            "eyebrow": .string("Community · Streams"), "version": .string("1.0.0"),
            "types": .array(a.types.map(AnyJSON.string)), "resources": .array([.string("catalog"), .string("stream")]),
            "catalogs": .array(catalogs),
            "stats": .array([.object(["label": .string("Version"), "value": .string("1.0.0"), "mono": .bool(true)])]),
            "configurable": .bool(a.configurable), "configurationRequired": .bool(false), "adult": .bool(false),
            "configureUrl": .string(a.configurable ? Self.setupUrl : ""), "stremioUrl": .string(a.url),
            "maskedUrl": .string("https://\(URL(string: a.url)?.host ?? "")/…/manifest.json"),
            "community": .null, "risingStars": .null, "documentation": .null,
            "related": .array([]), "recommended": .array([]),
        ])
    }

    private func category(_ name: String, _ slug: String) -> AnyJSON {
        .object(["name": .string(name), "slug": .string(slug)])
    }

    private func question(_ q: String, _ options: [String], _ correct: Int) -> AnyJSON {
        .object(["q": .string(q), "options": .array(options.map(AnyJSON.string)), "correct": .number(Double(correct))])
    }

    private func outcomeError() -> AnyJSON {
        .object(["kind": .string("error"), "message": .string(T("Install failed."))])
    }
}
