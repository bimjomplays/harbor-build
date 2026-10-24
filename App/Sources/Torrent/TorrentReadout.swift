import SwiftUI

/// The P2P part of the player's connecting card: bp-p2p-status.tsx (useBpP2pStatus polling the
/// engine once a second, bpStageLabel, BpP2pReadout's meter and "peers · speed · bytes") and
/// bp-connecting.tsx's notes, for a stream served by the TV's torrent engine.
struct TorrentReadout: View {
    let url: URL
    /// The player already holds the stream and waits on the next piece (snap.buffering).
    var buffering = false
    /// cinematic-player-loader.tsx kid branch: white type on the sea plate, and no large-file P2P
    /// warning (`!kid && heavyForP2p`).
    var kid = false
    /// use-p2p-preparing-status phase "no-peers": called once when the torrent is declared dead,
    /// so the kid loader can swap in its "Try again" block (cinematic-player-loader.tsx).
    var onNoPeers: (() -> Void)? = nil

    private var ink: Color { kid ? .white : BP.ink }
    private var inkMuted: Color { kid ? .white.opacity(0.7) : BP.inkMuted }

    /// The readout's logic and last reading (App/Shared/Torrent/TorrentReadoutModel.swift, shared with the phone).
    @State private var model = TorrentReadoutModel()
    private var sample: TorrentReadoutModel.Sample { model.sample }
    private var pct: Double { model.pct }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(9)) {
            meter
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                if sample.peers == 0, sample.phase != .noPeers {
                    Circle().fill(ink.opacity(0.45)).frame(width: BP.px(9), height: BP.px(9))
                }
                Text(label).font(BP.sans(15, .bold)).textCase(.uppercase).tracking(2.4).foregroundStyle(ink)
                Spacer(minLength: BP.px(10))
                if pct >= 1 { Text("\(Int(pct.rounded()))%").font(BP.sans(19, .semibold)).monospacedDigit().foregroundStyle(inkMuted) }
            }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).font(BP.sans(19, .medium)).monospacedDigit().foregroundStyle(inkMuted)
            }
            if let note { Text(note).font(BP.sans(15, .medium)).foregroundStyle(inkMuted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
            if !kid, let heavyNote { Text(heavyNote).font(BP.sans(15, .medium)).foregroundStyle(inkMuted.opacity(0.8)).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: BP.px(620), alignment: .leading)
        .task(id: url) { await poll() }
    }

    private var meter: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(kid ? Color.white.opacity(0.25) : BP.glass)
                if pct >= 1 {
                    Capsule().fill(ink).frame(width: g.size.width * pct / 100)
                        .animation(.linear(duration: 1.9), value: pct)
                } else {
                    Capsule().fill(ink.opacity(0.6)).frame(width: g.size.width * 0.2)
                }
            }
        }
        .frame(height: BP.px(7))
    }

    private var label: String { model.label(buffering: buffering) }
    private var parts: [String] { model.parts }
    private var note: String? { model.note(buffering: buffering) }
    private var heavyNote: String? { model.heavyNote }

    static func bytes(_ n: Double) -> String { TorrentReadoutModel.bytes(n) }
    static func speedText(_ bps: Double) -> String { TorrentReadoutModel.speedText(bps) }

    /// useBpP2pStatus's poll (TorrentReadoutModel.poll).
    private func poll() async {
        await TorrentReadoutModel.poll(url: url, update: { model = $0 }, onNoPeers: onNoPeers)
    }
}
