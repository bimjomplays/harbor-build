import SwiftUI

/// Person page (bp-person.tsx): portrait, name, department, facts, biography, awards; then
/// Known For, IMDb Top, Frequent Collaborators, and the filmography sections with Sort and
/// Rating filter rows. Needs a TMDB key.
@MainActor
final class PersonModel: ObservableObject {
    struct Person: Decodable {
        var id: Int; var name: String; var department: String; var portrait: String?; var imdbId: String?; var biography: String; var facts: [String]
        /// bp-person.tsx deptRank (lib/rankings): the place in the department's TMDB top 100, and its "Top {n}" label.
        var deptRank: Int?; var topLabel: String?
    }
    struct Collaborator: Decodable, Identifiable { var id: Int; var name: String; var portrait: String?; var role: String?; var titles: Int }
    struct Award: Decodable, Identifiable {
        var type: String; var wins: Int; var nominations: Int
        /// awards-catalog.ts AWARD_CATALOG[type].shorthand ("The Oscars"), nil for a body it lacks.
        var shorthand: String?
        var id: String { type }
    }
    struct Section: Decodable, Identifiable { var id: String; var title: String; @LossyArray var metas: [Meta] }   // lossy
    struct Page: Decodable {
        var hasKey: Bool; var person: Person?
        var knownFor: [Meta]?; var topRated: [Meta]?; var collaborators: [Collaborator]?; var awards: [Award]?
        var sections: [Section]?; var total: Int?; var shownTotal: Int?; var sort: String?; var minRating: Int?
    }

    let personId: Int
    @Published private(set) var page: Page?
    /// Starts true: the first frame (before `.task` runs) shows the spinner, not the failed-load card.
    @Published private(set) var loading = true
    @Published var sort = "popularity"
    @Published var minRating = 0
    private var unsubscribe: (() -> Void)?

    init(personId: Int) { self.personId = personId }
    deinit { unsubscribe?() }

    /// Only the newest load lands: a Sort or Rating pick made while the previous one
    /// was out (or a person-updated refresh) could put the older filmography under the new chips.
    private var loadGen = 0

    func load() async {
        loadGen += 1
        let gen = loadGen
        loading = true
        defer { if gen == loadGen { loading = false } }
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:person-updated", let self, (try? detail?.decode(Ping.self))?.personId == self.personId else { return }
                Task { await self.load() }
            }
        }
        let p = ProfilesStore.shared.active
        if let pg: Page = try? await HarborEngine.shared.call("personRoom.page", [personId, p?.id ?? "default", p?.linked ?? true, sort, minRating]) {
            guard gen == loadGen else { return }
            page = pg
            await CardMarksStore.shared.refresh((pg.knownFor ?? []) + (pg.sections ?? []).flatMap(\.metas))
        }
    }
    private struct Ping: Decodable { var personId: Int }
}
