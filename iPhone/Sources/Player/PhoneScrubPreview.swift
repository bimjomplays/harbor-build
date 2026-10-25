import CoreGraphics
import Foundation
import SwiftUI

/// Where the scrub preview's frames come from: a decoder of its own, apart from the one that plays
/// (PhoneScrubFrameSources.swift: a second mpv handle, AVAssetImageGenerator, the fixtures' still).
protocol ScrubFrameSource: AnyObject {
    /// A small frame at about `time` (seconds), or nil when there is none. Returns soon after the calling
    /// task is cancelled.
    func frame(at time: Double) async -> CGImage?
    /// Lets go of the stream (its connection) but stays ready for the next frame. A torrent's pieces are
    /// wanted only while a stream reads them.
    func park()
    /// Lets go of everything; a later frame(at:) opens the decoder again.
    func close()
}

/// How eagerly the preview decodes, by the kind of stream. Times are in seconds.
struct ScrubPreviewConfig: Equatable {
    /// A decode that takes longer is dropped and its spot counts as missed.
    var timeout: Double
    /// The finger rests this long before a decode starts (0: at once).
    var settle: Double
    /// A missed spot is not tried again for this long.
    var missFor: Double
    /// Misses allowed in one drag before it shows the time only (nil: no limit).
    var missBudget: Int?
    /// Failures in a row, with no frame yet, after which the stream gets no more tries (nil: never).
    var giveUpAfter: Int?
    /// A frame this close (seconds) stands in while the right one decodes.
    var nearby: Double
    /// The decoder closes after this long without a drag.
    var idleClose: Double
    /// When the finger lifts the decode in flight is cancelled and the stream let go.
    var parkOnEnd: Bool

    /// A remote file: a second connection, a few seconds for a keyframe far away.
    static let http = ScrubPreviewConfig(timeout: 5, settle: 0, missFor: 8, missBudget: nil, giveUpAfter: 4,
                                         nearby: 45, idleClose: 90, parkOnEnd: false)
    /// A torrent through Harbor's local stream: a spot whose pieces are not here yet would pull them in,
    /// so the decode waits for the finger to rest, gives up fast, only a few times per drag, and lets the
    /// stream go when the finger lifts.
    static let torrent = ScrubPreviewConfig(timeout: 1.5, settle: 0.18, missFor: 30, missBudget: 3, giveUpAfter: nil,
                                            nearby: 45, idleClose: 60, parkOnEnd: true)
    /// A file on the phone, or the fixtures' stand-in.
    static let local = ScrubPreviewConfig(timeout: 3, settle: 0, missFor: 5, missBudget: nil, giveUpAfter: 4,
                                          nearby: 45, idleClose: 90, parkOnEnd: false)
}

/// The preview's frames, keyed by time bucket: least recently used first out, bounded by count and bytes.
struct ScrubFrameCache {
    let maxCount: Int
    let maxBytes: Int
    private var entries: [Int: (image: CGImage, bytes: Int, used: Int)] = [:]
    private var tick = 0
    private(set) var bytes = 0

    init(maxCount: Int = 64, maxBytes: Int = 16 << 20) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }
    var buckets: [Int] { entries.keys.sorted() }

    static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    func contains(_ bucket: Int) -> Bool { entries[bucket] != nil }

    /// The bucket's frame, marked as just used.
    mutating func image(_ bucket: Int) -> CGImage? {
        guard let e = entries[bucket] else { return nil }
        tick += 1
        entries[bucket] = (e.image, e.bytes, tick)
        return e.image
    }

    mutating func insert(_ image: CGImage, bucket: Int) {
        let cost = Self.cost(image)
        guard cost <= maxBytes else { return }
        if let old = entries[bucket] { bytes -= old.bytes }
        tick += 1
        entries[bucket] = (image, cost, tick)
        bytes += cost
        while entries.count > maxCount || bytes > maxBytes {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
            bytes -= oldest.value.bytes
            entries[oldest.key] = nil
        }
    }

    /// The cached bucket nearest `bucket`, at most `within` buckets away (the later one on a tie).
    func nearest(to bucket: Int, within: Int) -> (bucket: Int, image: CGImage)? {
        guard within >= 0 else { return nil }
        var best: (bucket: Int, image: CGImage)?
        for (b, e) in entries {
            let d = abs(b - bucket)
            guard d <= within else { continue }
            if let cur = best {
                let dc = abs(cur.bucket - bucket)
                if d < dc || (d == dc && b > cur.bucket) { best = (b, e.image) }
            } else {
                best = (b, e.image)
            }
        }
        return best
    }

    mutating func removeAll() {
        entries.removeAll()
        bytes = 0
    }
}

/// The scrub preview (Infuse's thumbnail over the bar): while the finger drags along the bar, a small
/// frame of the film at that time. One decode at a time, always the latest spot: the finger's moves
/// while a frame decodes only change which spot comes next. Frames are kept per time bucket, so going
/// back over a stretch shows them at once; a spot that failed is left alone a while. With no frame yet
/// (or none near), `image` is nil and the bar shows the time alone.
/// A plain class held in @State by PhonePlayerView and observed only by the plate (PhoneScrubPlate), so a
/// new frame redraws the plate and not the player.
@MainActor
final class PhoneScrubPreview: ObservableObject {
    /// The frame to show (the spot's, or a near one while it decodes); nil: the time alone.
    @Published private(set) var image: CGImage?

    private(set) var key: String?
    private(set) var config: ScrubPreviewConfig = .http
    private var duration: Double = 0
    private var make: (() -> ScrubFrameSource?)?
    private var source: ScrubFrameSource?
    private(set) var cache = ScrubFrameCache()
    /// When each missed bucket may be tried again (ProcessInfo uptime).
    private var missedUntil: [Int: Double] = [:]
    private var dragMisses = 0
    private var failuresInRow = 0
    private var hadFrame = false
    private(set) var gaveUp = false
    /// The bucket under the finger (nil: no drag).
    private(set) var wanted: Int?
    private var inFlight: (bucket: Int, task: Task<Void, Never>)?
    private var settleTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Bumped by every reset, so a decode from before one is dropped when it lands.
    private var generation = 0

    /// How many decodes started (tests).
    private(set) var decodesStarted = 0

    // MARK: buckets

    /// Seconds per bucket: a 400th of the film, between 2 and 10 s.
    static func bucketSize(duration: Double) -> Double {
        guard duration > 0 else { return 5 }
        return min(10, max(2, duration / 400))
    }

    static func bucket(_ time: Double, duration: Double) -> Int {
        Int((max(0, time) / bucketSize(duration: duration)).rounded(.down))
    }

    /// The time decoded for a bucket: its middle, kept a second inside the end.
    static func time(of bucket: Int, duration: Double) -> Double {
        let size = bucketSize(duration: duration)
        let mid = (Double(bucket) + 0.5) * size
        return duration > 1 ? min(mid, duration - 1) : mid
    }

    private var nearbyBuckets: Int { Int((config.nearby / Self.bucketSize(duration: duration)).rounded(.down)) }

    // MARK: driving it

    /// The stream the frames come from. The same key keeps the decoder and the frames; a new one (another
    /// URL or engine) starts over.
    func prepare(key: String, duration: Double, config: ScrubPreviewConfig, make: @escaping () -> ScrubFrameSource?) {
        if key == self.key {
            if duration > 0, Self.bucketSize(duration: duration) != Self.bucketSize(duration: self.duration) {
                cache.removeAll()
                missedUntil.removeAll()
                image = nil
            }
            if duration > 0 { self.duration = duration }
            return
        }
        close()
        self.key = key
        self.duration = duration
        self.config = config
        self.make = make
    }

    /// The finger is at `time` (nil: it lifted).
    func update(_ time: Double?) {
        guard let time else { end(); return }
        guard make != nil, duration > 0, !gaveUp else { image = nil; return }
        idleTask?.cancel()
        let b = Self.bucket(time, duration: duration)
        let moved = b != wanted
        wanted = b
        if let hit = cache.image(b) {
            image = hit
            settleTask?.cancel()
            return
        }
        image = cache.nearest(to: b, within: nearbyBuckets)?.image
        if moved { schedule() }
    }

    /// The finger lifted: the frame goes; a torrent's decode stops and its stream is let go.
    private func end() {
        wanted = nil
        image = nil
        dragMisses = 0
        settleTask?.cancel()
        settleTask = nil
        if config.parkOnEnd {
            inFlight?.task.cancel()
            source?.park()
        }
        idleClose()
    }

    /// Lets go of the decoder and every frame (the player closing, the app leaving).
    func close() {
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        settleTask?.cancel()
        settleTask = nil
        idleTask?.cancel()
        idleTask = nil
        source?.close()
        source = nil
        cache.removeAll()
        missedUntil.removeAll()
        wanted = nil
        image = nil
        dragMisses = 0
        failuresInRow = 0
        hadFrame = false
        gaveUp = false
        key = nil
        make = nil
        duration = 0
    }

    /// Low memory: the frames go (the decoder stays for the next drag).
    func trim() {
        cache.removeAll()
        if wanted == nil { image = nil }
    }

    // MARK: decoding

    private func missed(_ b: Int) -> Bool {
        guard let until = missedUntil[b] else { return false }
        if ProcessInfo.processInfo.systemUptime < until { return true }
        missedUntil[b] = nil
        return false
    }

    private var budgetSpent: Bool {
        if let budget = config.missBudget { return dragMisses >= budget }
        return false
    }

    /// The bucket to decode next, if any: the finger's, when it has no frame, has not just failed, and the
    /// drag still has tries.
    private var next: Int? {
        guard let b = wanted, !gaveUp, !cache.contains(b), !missed(b), !budgetSpent else { return nil }
        return b
    }

    private func schedule() {
        guard inFlight == nil, next != nil else { return }
        settleTask?.cancel()
        guard config.settle > 0 else { start(); return }
        let gen = generation
        settleTask = Task { [weak self, settle = config.settle] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.settleTask = nil
            self.start()
        }
    }

    private func start() {
        guard inFlight == nil, let b = next else { return }
        if source == nil { source = make?() }
        guard let src = source else { gaveUp = true; image = nil; return }
        let t = Self.time(of: b, duration: duration)
        let gen = generation
        let timeout = config.timeout
        decodesStarted += 1
        let task = Task { [weak self] in
            let frame = await Self.frame(from: src, at: t, timeout: timeout)
            let cancelled = Task.isCancelled
            self?.landed(b, frame, cancelled: cancelled, generation: gen)
        }
        inFlight = (b, task)
    }

    /// The source's frame, or nil after `timeout` (the decode is then cancelled).
    nonisolated static func frame(from source: ScrubFrameSource, at time: Double, timeout: Double) async -> CGImage? {
        await withTaskGroup(of: CGImage?.self) { group -> CGImage? in
            group.addTask { await source.frame(at: time) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            // Whichever ends first: the frame, or the timeout (nil); the other is cancelled.
            let first: CGImage?? = await group.next()
            group.cancelAll()
            guard let done = first, let image = done else { return nil }
            return image
        }
    }

    private func landed(_ b: Int, _ frame: CGImage?, cancelled: Bool, generation gen: Int) {
        guard gen == generation else { return }
        inFlight = nil
        if let frame {
            cache.insert(frame, bucket: b)
            hadFrame = true
            failuresInRow = 0
            if let w = wanted {
                image = cache.image(w) ?? cache.nearest(to: w, within: nearbyBuckets)?.image
            }
        } else if !cancelled {
            missedUntil[b] = ProcessInfo.processInfo.systemUptime + config.missFor
            if wanted != nil { dragMisses += 1 }
            failuresInRow += 1
            if let limit = config.giveUpAfter, !hadFrame, failuresInRow >= limit {
                gaveUp = true
                source?.close()
                source = nil
            }
        }
        if wanted != nil {
            schedule()
        } else {
            if config.parkOnEnd { source?.park() }
            idleClose()
        }
    }

    private func idleClose() {
        idleTask?.cancel()
        guard source != nil else { return }
        let gen = generation
        idleTask = Task { [weak self, wait = config.idleClose] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.generation == gen, self.wanted == nil, self.inFlight == nil else { return }
            self.source?.close()
            self.source = nil
        }
    }
}

// MARK: the plate

/// Over the bar while it drags: the preview frame in a rounded glass plate with the time under it, or the
/// time alone in a glass capsule while there is no frame. Its bottom sits just over the bar at `x`, kept
/// inside the bar's `width`.
struct PhoneScrubPlate: View {
    @ObservedObject var preview: PhoneScrubPreview
    let time: Double
    let x: CGFloat
    let width: CGFloat

    static let frameWidth: CGFloat = 160

    /// The frame's height at 160 pt wide, between 4:3 and 2.4:1 (about 16:9 for most films).
    static func frameHeight(_ image: CGImage) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return frameWidth * 9 / 16 }
        let aspect: CGFloat = min(2.4, max(4.0 / 3.0, CGFloat(image.width) / CGFloat(image.height)))
        return (frameWidth / aspect).rounded()
    }

    var body: some View {
        let half: CGFloat = preview.image != nil ? Self.frameWidth / 2 + 6 : 36
        Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: .bottom) { content.fixedSize() }
            .position(x: min(max(x, half), max(half, width - half)), y: -8)
            .allowsHitTesting(false)
    }

    private var label: some View {
        Text(verbatim: PlayerClock.fmt(time))
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .accessibilityIdentifier("player-scrub-time")
    }

    @ViewBuilder private var content: some View {
        if let image = preview.image {
            VStack(spacing: 5) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.frameWidth, height: Self.frameHeight(image))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                label
            }
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 5)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player-scrub-preview")
        } else {
            label
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
