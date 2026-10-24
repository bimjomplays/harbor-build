import Foundation

/// The P2P readout's logic, shared by the TV's connecting card (App/Sources/Torrent/TorrentReadout.swift)
/// and the phone's (iPhone/Sources/Player/PhonePlayerCards.swift): bp-p2p-status.tsx (useBpP2pStatus
/// polling the engine once a second, bpStageLabel, BpP2pReadout's "peers · speed · bytes") and
/// bp-connecting.tsx's notes, for a stream served by the device's torrent engine. Each screen draws it
/// at its own scale.
struct TorrentReadoutModel: Equatable {
    enum Phase { case searching, connected, slow, noPeers }
    struct Sample: Equatable {
        var phase: Phase = .searching
        var peers = 0
        var speed: Double = 0
        var downloaded: Double = 0
        var total: Double?
        var readiness: Double = 0
        var elapsedMs: Double = 0
    }

    var sample = Sample()
    /// useMonotonicPct: the meter only ever climbs.
    var pct: Double = 0

    // bp-p2p-status.tsx / bp-connecting.tsx windows.
    static let noPeersMs: Double = 75_000
    static let slowMs: Double = 90_000
    static let stillLookingMs: Double = 22_000
    static let heavyBytes: Double = 20 * 1_073_741_824

    /// bpStageLabel for a torrent. `buffering`: the player already holds the stream and waits on the
    /// next piece (snap.buffering).
    func label(buffering: Bool) -> String {
        if sample.phase == .noPeers { return "No peers found" }
        if buffering { return "Buffering" }
        if sample.phase == .slow { return "Found peers, no data yet" }
        if sample.peers == 0 { return "Looking for peers…" }
        return "Preparing stream"
    }

    /// telemetryParts.
    var parts: [String] {
        var out: [String] = []
        if sample.peers > 0 {
            out.append("\(sample.peers) \(sample.peers == 1 ? "peer" : "peers")")
            out.append(Self.speedText(sample.speed))
        }
        if sample.downloaded > 0 {
            if let total = sample.total, total > 0 {
                out.append("\(Self.bytes(sample.downloaded)) / \(Self.bytes(total))")
            } else {
                out.append(Self.bytes(sample.downloaded))
            }
        }
        return out
    }

    /// bp-connecting's note chain.
    func note(buffering: Bool) -> String? {
        if sample.phase == .noPeers {
            return "Couldn't connect to any peers for this torrent. It may be unreachable on your network (some ISPs and VPNs block torrent traffic)."
        }
        if sample.phase == .slow { return "Found peers but no data yet. The torrent may be slow." }
        if buffering { return "The player has the stream open and is waiting on the next piece." }
        if sample.peers == 0, sample.elapsedMs >= Self.stillLookingMs { return "Still looking. Some torrents take a minute to find their first peer." }
        if sample.peers > 0 { return "Downloading the start of the file. Playback begins once there is enough to keep going." }
        return nil
    }

    var heavyNote: String? {
        guard let total = sample.total, total > Self.heavyBytes, sample.phase != .noPeers else { return nil }
        return "Heads up: this is a large file for peer-to-peer streaming, so it can take a while to start. A 1080p source or a debrid service will load faster."
    }

    /// formatBpBytes.
    static func bytes(_ n: Double) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", n / 1_073_741_824) }
        if n >= 1_048_576 { return "\(Int((n / 1_048_576).rounded())) MB" }
        return "\(Int((n / 1024).rounded())) KB"
    }

    /// speedText.
    static func speedText(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return "\(Int(bps / 1024)) KB/s" }
        return "Warming up"
    }

    /// engine-stats.ts readinessScore for an info-hash stream.
    static func readiness(peers: Int, downloaded: Double, speed: Double, streamLen: Double?) -> Double {
        let peerScore = min(1, Double(peers) / 8) * 20
        let minDownload = min(8 * 1_048_576, max(2 * 1_048_576, (streamLen ?? 0) * 0.008))
        let downloadedScore = min(1, downloaded / minDownload) * 70
        let speedScore = min(1, speed / 1_048_576) * 10
        return min(99, peerScore + downloadedScore + speedScore)
    }

    /// useBpP2pStatus's poll: once a second until the torrent is declared dead (`onNoPeers` then).
    /// Each reading goes to `update`; nothing is polled for a URL the torrent engine does not serve.
    @MainActor static func poll(url: URL, update: @MainActor (TorrentReadoutModel) -> Void, onNoPeers: (@MainActor () -> Void)? = nil) async {
        guard let ref = TorrentEngine.streamRef(url) else { return }
        let start = Date()
        var model = TorrentReadoutModel()
        var sawData = false
        var failed = false
        var total: Double?
        while !Task.isCancelled {
            if let s = await TorrentEngine.shared.stats(infoHash: ref.infoHash, fileIdx: ref.fileIdx) {
                let peers = s.unchoked > 0 ? s.unchoked : s.peers
                let elapsedMs = Date().timeIntervalSince(start) * 1000
                // Bytes moving is the only proof the torrent is alive; one byte is enough forever.
                if s.downloadSpeed > 0 || s.streamProgress > 0 || s.downloaded > 0 { sawData = true }
                let quiet = !sawData
                if quiet, peers == 0, elapsedMs >= noPeersMs { failed = true }
                if s.streamLen > 0 { total = s.streamLen }
                let phase: Phase = failed ? .noPeers : (quiet && peers > 0 && elapsedMs >= slowMs) ? .slow : peers > 0 ? .connected : .searching
                let ready = readiness(peers: peers, downloaded: s.downloaded, speed: s.downloadSpeed, streamLen: total)
                model.sample = Sample(phase: phase, peers: peers, speed: s.downloadSpeed, downloaded: s.downloaded, total: total, readiness: ready, elapsedMs: elapsedMs)
                model.pct = max(model.pct, ready)
                update(model)
                if failed { onNoPeers?(); return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
