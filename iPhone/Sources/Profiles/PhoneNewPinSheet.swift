import SwiftUI

/// Choosing a PIN: four digits, then the same four again. `done` gets the PIN, or nil when the viewer
/// cancelled. A confirmation that differs buzzes and shakes like a wrong PIN (PhonePinPad), so a typo
/// never becomes the PIN that locks a profile.
struct PhoneNewPinSheet: View {
    let title: String
    let done: (String?) -> Void

    @State private var first: String?
    @State private var typed = ""
    /// Per sheet, so the pad's try counter and cool-down belong to this one entry.
    @State private var token = UUID().uuidString

    var body: some View {
        Group {
            if let first {
                PhonePinPad(title: T("Confirm the PIN"),
                            subtitle: T("Enter the same 4 digits again."),
                            cooldownKey: "confirm-\(token)",
                            verify: { $0 == first },
                            finish: { ok in done(ok ? first : nil) })
            } else {
                PhonePinPad(title: title,
                            subtitle: T("Choose a 4-digit PIN."),
                            cooldownKey: "new-\(token)",
                            verify: { entry in
                                typed = entry
                                return ProfilesStore.isValidPin(entry)
                            },
                            finish: { ok in
                                if ok { first = typed } else { done(nil) }
                            })
            }
        }
    }
}
