import Foundation

/// The engine calls behind AddonsModel and AddonOrganizeModel. They go straight to the engine; the
/// phone's fixture launches (`--fixtures shell`, its UI tests) put an in-memory addon list in
/// `stub` instead (iPhone/Sources/Addons/PhoneAddonsFixtures.swift), so install, reorder and
/// remove run without the network or a Stremio account. The TV never sets it.
@MainActor
enum AddonsEngine {
    static var stub: (@MainActor (_ path: String, _ args: [AnyJSON]) async throws -> AnyJSON)?

    static func call<T: Decodable>(_ path: String, _ args: [any Encodable] = []) async throws -> T {
        guard let stub else { return try await HarborEngine.shared.call(path, args) }
        return try await stub(path, try args.map(json)).decode(T.self)
    }

    static func callJSON(_ path: String, _ args: [AnyJSON] = []) async throws -> AnyJSON {
        guard let stub else { return try await HarborEngine.shared.callJSON(path, args) }
        return try await stub(path, args)
    }

    /// `harbor:addons-changed` and the like, for the engine's own listeners; the fixtures have none.
    static func emit(_ type: String, detail: AnyJSON? = nil) {
        guard stub == nil else { return }
        HarborEngine.shared.emitEvent(type, detail: detail)
    }

    /// One argument as JSON. It crosses inside an array so a bare nil, number or string survives.
    private static func json(_ value: any Encodable) throws -> AnyJSON {
        struct Box: Encodable {
            let value: any Encodable
            func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
        }
        let wrapped = try JSONDecoder().decode([AnyJSON].self, from: JSONEncoder().encode([Box(value: value)]))
        return wrapped.first ?? .null
    }
}
