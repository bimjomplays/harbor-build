import SwiftUI

/// The poster menu's "Add to collection" (PhoneContextMenu): the viewer's collections, ticked where
/// the title already is (picking a ticked one takes it out), and "New collection", which asks for a
/// name and puts the title in the new one. Films and shows only, as the TV's add search offers.
struct PhoneAddToCollectionMenu: View {
    let meta: Meta
    /// Asks for the new collection's name (the alert lives on the tile: a menu cannot hold one).
    let newCollection: () -> Void
    @ObservedObject private var store = PhoneCollectionsStore.shared

    var body: some View {
        Menu {
            ForEach(store.mine) { card in
                let added = card.items.contains { $0.id == meta.id }
                Button {
                    PhoneFeedback.shared.tap()
                    Self.toggle(meta, in: card)
                } label: {
                    Label(card.name, systemImage: added ? "checkmark" : "rectangle.stack")
                }
            }
            if store.canCreate {
                Divider()
                Button(action: newCollection) {
                    Label(T("New collection"), systemImage: "plus")
                }
            }
        } label: {
            Label(T("Add to collection"), systemImage: "rectangle.stack.badge.plus")
        }
    }

    static func toggle(_ meta: Meta, in card: CollectionsModel.Card) {
        let title = meta
        let ref = card.ref
        let name = card.name
        Task {
            let store = PhoneCollectionsStore.shared
            let had = store.contains(title.id, in: ref)
            let now = await store.toggle(title, in: ref)
            guard now != had else { return }
            PhoneToaster.shared.show(now ? T("Added to %@", name) : T("Removed from %@", name))
        }
    }
}

/// The name prompt behind the menu's "New collection": makes the collection and adds the title.
struct PhoneNewCollectionPrompt: ViewModifier {
    let meta: Meta
    @Binding var isPresented: Bool
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(T("New collection"), isPresented: $isPresented) {
            TextField(T("Name this collection"), text: $draft)
            Button(T("Create")) {
                let name = draft
                let title = meta
                draft = ""
                Task {
                    let store = PhoneCollectionsStore.shared
                    guard let made = await store.create(name: name) else { return }
                    if await store.add(title, to: made.ref) {
                        PhoneToaster.shared.show(T("Added to %@", made.name))
                    }
                }
            }
            Button(T("Cancel"), role: .cancel) { draft = "" }
        }
    }
}
