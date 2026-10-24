import SwiftUI

/// Multiview (views/multiview.tsx, multiview/grid.tsx, multiview/cell.tsx, lib/multiview/store.ts):
/// up to four live channels at once in a 1 / 2 / Stacked / 3 / 2x2 layout, one tile with the
/// sound. Desktop draws each tile as a separate native window (Windows only); here every tile is
/// its own MPVPlayerController in `tile` mode: muted unless it holds the audio focus, a short live
/// cache, and it never touches the TV's display mode or HDR. The desktop drag-to-resize splits
/// are not ported (tiles split evenly); the layout is remembered like upstream's.
@MainActor
final class MultiviewModel: ObservableObject {
    typealias Channel = LiveModel.Channel

    /// bridge.ts MAX_SLOTS.
    static let maxSlots = 4
    /// multiview.tsx LAYOUTS with their titles; the chip shows the id ("Stacked" for 2v).
    static let layouts: [(id: String, title: String)] = [("1", "Single"), ("2", "Side by side"), ("2v", "Stacked"), ("3", "Triple"), ("2x2", "Quad")]

    /// store.ts layoutSlotCount.
    static func slotCount(_ layout: String) -> Int {
        switch layout {
        case "1": return 1
        case "2", "2v": return 2
        case "3": return 3
        default: return 4
        }
    }

    @Published private(set) var slots: [Channel?] = Array(repeating: nil, count: MultiviewModel.maxSlots)
    @Published private(set) var layout = "2x2"
    /// The tile with the sound; -1 = every tile muted (the cell's Mute button).
    @Published private(set) var audioFocus = 0
    @Published private(set) var bannerDismissed = true
    /// Channels of sources other than the Live room's, loaded when the picker asks for them.
    @Published private(set) var otherChannels: [String: [Channel]] = [:]
    @Published private(set) var loadingOther: Set<String> = []

    var slotCount: Int { Self.slotCount(layout) }
    var activeCount: Int { slots.prefix(slotCount).compactMap { $0 }.count }

    func loadPrefs() async {
        struct Prefs: Decodable { var layout: String; var bannerDismissed: Bool }
        if let p: Prefs = try? await HarborEngine.shared.call("live.multiviewPrefs", []) {
            layout = p.layout
            bannerDismissed = p.bannerDismissed
        } else {
            bannerDismissed = false
        }
    }

    /// store.ts setLayout (persisted).
    func setLayout(_ l: String) {
        guard Self.layouts.contains(where: { $0.id == l }) else { return }
        layout = l
        Task { _ = try? await HarborEngine.shared.callJSON("live.setMultiviewLayout", [.string(l)]) }
    }

    func dismissBanner() {
        bannerDismissed = true
        Task { _ = try? await HarborEngine.shared.callJSON("live.dismissMultiviewBanner", []) }
    }

    /// multiview.tsx ChannelPicker onPick: the first channel into an empty grid takes the sound.
    func pick(_ slot: Int, _ ch: Channel) {
        guard slots.indices.contains(slot) else { return }
        let wasEmpty = slots.allSatisfy { $0 == nil }
        slots[slot] = ch
        if wasEmpty { audioFocus = slot }
    }

    /// multiview.tsx closeSlot: the sound moves to the first other filled tile (else tile 1).
    func close(_ slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        if audioFocus == slot {
            audioFocus = slots.indices.first { $0 != slot && slots[$0] != nil } ?? 0
        }
    }

    func setAudioFocus(_ slot: Int) { audioFocus = slot }

    /// store.ts reset ("Clear all", and when Multiview closes).
    func reset() {
        slots = Array(repeating: nil, count: Self.maxSlots)
        audioFocus = 0
    }

    /// channel-picker.tsx playlists: another source's channels, through the same engine call the Live room uses.
    func loadChannels(of playlistId: String) async {
        guard otherChannels[playlistId] == nil, !loadingOther.contains(playlistId) else { return }
        loadingOther.insert(playlistId)
        defer { loadingOther.remove(playlistId) }
        if let v: LiveModel.View_ = try? await HarborEngine.shared.call("live.channels", [playlistId, false]) {
            otherChannels[playlistId] = v.channels
        } else {
            otherChannels[playlistId] = []
        }
    }
}
