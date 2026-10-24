import SwiftUI

/// What a row header or a band tile opens. Catalog, service and addon pages are the poster grid
/// (PhoneCatalogView); a curated collection opens the collection page (PhoneCollectionPage).
struct PhoneCatalogTarget: Hashable {
    var room: Room
    var key: String
    var title: String
    /// The titles the row already holds, so a page can draw at once while it loads the rest.
    var metas: [Meta]

    static func == (a: PhoneCatalogTarget, b: PhoneCatalogTarget) -> Bool { a.room == b.room && a.key == b.key }
    func hash(into hasher: inout Hasher) {
        hasher.combine(room)
        hasher.combine(key)
    }
}

enum PhoneRoute: Hashable {
    /// A row's "See all" (bp-row-header chip → CatalogPageView on the TV).
    case catalog(PhoneCatalogTarget)
    /// A streaming-service tile (ServicePageView).
    case service(id: String, name: String)
    /// An installed addon's brand tile (AddonPageView).
    case addon(base: String, name: String, logo: String?)
    /// A curated TMDB collection tile (HomeCollectionView).
    case collection(ref: String, name: String, image: String?)
    /// A title page (DetailView): any tile, hero, menu or search result.
    case title(PhoneDetailTarget)
    /// A cast member's page (PersonView), from a title page's cast rail.
    case person(id: Int, name: String)

    var title: String {
        switch self {
        case .catalog(let target): return target.title
        case .service(_, let name), .addon(_, let name, _), .collection(_, let name, _), .person(_, let name): return name
        case .title(let target): return target.meta.name
        }
    }

    /// The accessibility identifier of the page, so UI tests can tell which route opened.
    var identifier: String {
        switch self {
        case .catalog: return "route-catalog"
        case .service: return "route-service"
        case .addon: return "route-addon"
        case .collection: return "route-collection"
        case .title: return "route-title"
        case .person: return "route-person"
        }
    }

    /// The tile a title page zooms out of.
    var zoomKey: String? {
        if case .title(let target) = self { return target.zoomKey }
        return nil
    }
}

/// The page a route opens: the poster grid for a row's See all, a service and an addon; the title
/// page; a person page; a curated collection's page.
struct PhoneRoutePage: View {
    let route: PhoneRoute
    let open: (Meta) -> Void

    var body: some View {
        switch route {
        case .catalog(let target):
            PhoneCatalogPage(origin: .row(target), title: route.title, identifier: route.identifier, open: open)
        case .service(let id, _):
            PhoneCatalogPage(origin: .service(id: id), title: route.title, identifier: route.identifier, open: open)
        case .addon(let base, _, let logo):
            PhoneCatalogPage(origin: .addon(base: base), title: route.title, logo: logo, identifier: route.identifier, open: open)
        case .collection(let ref, let name, let image):
            PhoneCollectionPage(card: CollectionsModel.Card(key: "tmdb:\(ref)", source: "tmdb", ref: ref, name: name, image: image,
                                                            count: nil, byline: nil, description: nil, items: [], hidden: nil),
                                open: open, identifier: route.identifier)
        case .title(let target):
            PhoneDetailView(target: target)
        case .person(let id, let name):
            PhonePersonPage(personId: id, name: name, open: open)
        }
    }
}
