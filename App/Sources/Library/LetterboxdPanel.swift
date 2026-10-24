import SwiftUI


struct LetterboxdPanel: View {
    @StateObject private var model = LetterboxdModel()
    @State private var username = ""
    /// Disconnect asks nothing first, like letterboxd-panel.tsx
    /// handleDisconnect, and Connect swaps it out under the ring; the ring follows to the step's
    /// lead button (Disconnect ↔ Connect) instead of falling off the panel.
    @FocusState private var lead: Bool

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            if let s = model.status, s.active {
                Text("Connected as \(s.username)").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("Your watchlist shows in the Library, and your Letterboxd rows on Movies.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                Button("Disconnect") {
                    Task {
                        await model.disable()
                        // Only while the ring is still on this step (see Connect).
                        if lead { refocus() }
                    }
                }
                .buttonStyle(BPActionStyle())
                .focused($lead)
            } else {
                Text("Letterboxd username").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                Text("The handle in your profile address, letterboxd.com/your-name.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                HStack(alignment: .bottom, spacing: BP.px(8)) {
                    BPField(label: "Letterboxd username", placeholder: "your-name", text: $username)
                        .frame(maxWidth: BP.px(420))
                    // Dimmed, not disabled, while the field is empty, so the ring can land here.
                    let empty = username.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(model.busy ? "Connecting…" : "Connect") {
                        guard !empty else { return }
                        Task {
                            await model.connect(username)
                            // The Stremboxd check can take seconds: a viewer who walked
                            // on to another Settings section meanwhile was pulled back to
                            // Disconnect. Read before the swap re-renders: the ring still on
                            // Connect (lead) is the only case to follow.
                            let stillHere: Bool = lead
                            if model.status?.active == true, stillHere { refocus() }
                        }
                    }
                        .buttonStyle(BPActionStyle(primary: true, busy: model.busy || empty))
                        .focused($lead)
                }
                Text("Checks the username against Stremboxd and turns on the catalogs it finds.").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            if let n = model.note { BPNote(text: n, tone: model.noteOk ? BP.live : BP.danger) }
        }
        .task {
            await model.refresh()
            if username.isEmpty, let s = model.status { username = s.username }
        }
    }

    /// The step's lead button, once it is on screen.
    private func refocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { lead = true }
    }
}
