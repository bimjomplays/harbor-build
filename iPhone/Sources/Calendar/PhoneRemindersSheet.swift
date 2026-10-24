import SwiftUI

/// components/reminders-manager.tsx as a sheet (the TV's RemindersManagerView through the shared
/// RemindersManagerModel): every reminder with its summary, a dot on one that fired unseen; a row
/// opens the show (once the sheet is down), the cross or a swipe removes it ("Reminder removed").
/// A reminder is added where the TV adds it, on the show's page (Detail's Remind me).
struct PhoneRemindersSheet: View {
    /// Under `--fixtures` the rows are PhoneCalendarFixtures' and nothing reaches the engine.
    let fixtures: Bool
    /// A show picked here; the calendar opens it when the sheet has closed.
    let pick: (Meta) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RemindersManagerModel()

    var body: some View {
        NavigationStack {
            List {
                if model.loaded && model.rows.isEmpty {
                    Text(verbatim: T("No reminders yet. Use the clock on a show's page to get told about new episodes and seasons."))
                        .font(PhoneTheme.sans(15, .regular, relativeTo: .subheadline))
                        .foregroundStyle(BP.inkMuted)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("reminders-empty")
                }
                if !model.rows.isEmpty {
                    Section {
                        ForEach(model.rows) { r in row(r) }
                    } footer: {
                        Text(verbatim: T("Use Remind me on a show's page to add one."))
                    }
                }
                if let note = model.note {
                    Text(verbatim: T(note))
                        .font(PhoneTheme.sans(14, .medium, relativeTo: .footnote))
                        .foregroundStyle(BP.inkSubtle)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("reminders-note")
                }
            }
            .motion(.snappy, value: model.rows)
            .overlay {
                if !model.loaded { ProgressView() }
            }
            .navigationTitle(T("Reminders"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("Done")) { dismiss() }
                        .accessibilityIdentifier("reminders-done")
                }
            }
        }
        .task {
            if fixtures {
                model.rows = PhoneCalendarFixtures.reminders
                model.loaded = true
            } else {
                await model.loadOnce()
            }
        }
        .accessibilityIdentifier("reminders-sheet")
    }

    private func row(_ r: ReminderCenter.Row) -> some View {
        HStack(spacing: 12) {
            Button {
                pick(Meta(id: r.id, type: r.type == "movie" ? "movie" : "series", name: r.name, poster: r.poster))
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        BP.ink.opacity(0.07)
                        if r.poster != nil {
                            PhoneImage(url: r.poster)
                        } else {
                            Image(systemName: "bell").foregroundStyle(BP.inkSubtle)
                        }
                    }
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // The show's name is read right after it either way.
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: r.name)
                            .font(PhoneTheme.sans(16, .semibold, relativeTo: .body))
                            .foregroundStyle(BP.ink)
                            .lines(1)
                        Text(verbatim: r.summary)
                            .font(PhoneTheme.sans(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(BP.inkSubtle)
                            .lines(1)
                    }
                    Spacer(minLength: 0)
                    if r.unseen {
                        Circle().fill(BP.danger).frame(width: 8, height: 8)
                            .accessibilityLabel(Text(verbatim: T("New")))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reminder-\(r.id)")
            Button {
                remove(r)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BP.inkMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: T("Remove reminder")))
            .accessibilityIdentifier("reminder-remove-\(r.id)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { remove(r) } label: {
                Label(T("Remove reminder"), systemImage: "bell.slash")
            }
        }
    }

    private func remove(_ r: ReminderCenter.Row) {
        PhoneFeedback.shared.tap()
        if fixtures {
            model.rows = PhoneCalendarFixtures.removeReminder(r.id)
            model.note = "Reminder removed"
        } else {
            Task { await model.remove(r) }
        }
    }
}
