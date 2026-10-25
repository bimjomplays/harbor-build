import AVFoundation
import CoreGraphics
import Foundation
import Libmpv
import UIKit

/// The scrub preview's decoders (PhoneScrubPreview): each opens the stream on its own, apart from the
/// engine that plays, and makes small frames (320 px wide at most).
/// - mpv: a second, silent mpv handle (no picture output, no audio, no subtitles, no cache) that seeks to
///   the keyframe before the spot and takes the frame with `screenshot-raw`. Plays anything mpv plays,
///   torrents through Harbor's local stream included.
/// - AVPlayer: AVAssetImageGenerator on an asset of its own (files AVFoundation opens; not HLS).
/// - Fixtures: the demo's still, panned by time.

/// Hands an async caller one result: the first resume wins, later ones (a late decode after a cancel)
/// are dropped.
final class ScrubOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var done = false

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if done, let value = early {
            early = nil
            lock.unlock()
            c.resume(returning: value)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(returning: value)
        } else {
            early = value
            lock.unlock()
        }
    }
}

enum ScrubFrames {
    static let maxWidth = 320

    /// `image` at most `maxWidth` wide, in memory of its own (no tie to the decoder's buffer).
    static func owned(_ image: CGImage, maxWidth: Int = maxWidth) -> CGImage? {
        let scale: Double = min(1, Double(maxWidth) / Double(max(1, image.width)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The HLS check NativePlayerController makes: AVAssetImageGenerator gives no frames for HLS.
    static func isHLS(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("m3u8") || lower.contains("/playlist/")
    }

    /// The user agent the engines send (the stream's own, or VLC's, as both engines do).
    static func userAgent(_ headers: [String: String]) -> String {
        headers.first { $0.key.lowercased() == "user-agent" }?.value ?? "VLC/3.0.20 LibVLC/3.0.20"
    }

    static func otherHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.lowercased() != "user-agent" }
    }
}

// MARK: mpv

/// A second mpv handle that only decodes: paused, no picture output, no audio, no subtitles, no cache,
/// hardware decoding (copied back), scaled to 320 px before the frame is taken. The first frame loads the
/// file at the spot; later ones seek to the keyframe before it. All of it runs on its own serial queue at
/// utility priority; a newer request or a cancel ends the wait for the one before (checked every 0.1 s).
final class MPVScrubFrameSource: ScrubFrameSource, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "harbor.scrub-preview.mpv", qos: .utility)
    private let lock = NSLock()
    /// The request that may run (lock); an older one is cancelled.
    private var current = 0
    // The queue's own.
    private var handle: OpaquePointer?
    private var loadIssued = false
    private var loaded = false

    /// A seek that lands further than this from the spot is a stale one (an older seek finishing).
    static let staleAfter: Double = 30

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    deinit {
        if let h = handle {
            DispatchQueue.global(qos: .utility).async { mpv_terminate_destroy(h) }
        }
    }

    func frame(at time: Double) async -> CGImage? {
        let id: Int = lock.withLock {
            current += 1
            return current
        }
        let once = ScrubOnce<CGImage?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                once.set(c)
                queue.async { once.resume(self.decode(time, id: id)) }
            }
        } onCancel: {
            self.lock.withLock { if self.current == id { self.current += 1 } }
            once.resume(nil)
        }
    }

    func park() {
        queue.async { self.stop() }
    }

    func close() {
        lock.withLock { current += 1 }
        queue.async { self.destroy() }
    }

    // MARK: on the queue

    private func live(_ id: Int) -> Bool { lock.withLock { current == id } }

    private func open() -> OpaquePointer? {
        if let handle { return handle }
        guard let h = mpv_create() else { return nil }
        let options: [(String, String)] = [
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("input-default-bindings", "no"), ("osd-level", "0"),
            ("vo", "null"), ("ao", "null"), ("aid", "no"), ("sid", "no"), ("sub-auto", "no"), ("audio-file-auto", "no"),
            ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"), ("hr-seek", "no"),
            ("cache", "no"), ("demuxer-max-bytes", "8MiB"), ("demuxer-max-back-bytes", "0"), ("demuxer-readahead-secs", "1"),
            ("network-timeout", "8"),
            ("hwdec", "videotoolbox-copy"), ("vd-lavc-threads", "2"), ("vd-lavc-skiploopfilter", "all"), ("vd-lavc-fast", "yes"),
            ("vf", "lavfi=[scale=\(ScrubFrames.maxWidth):-2]"),
            ("screenshot-sw", "yes"), ("screenshot-high-bit-depth", "no"),
            ("user-agent", ScrubFrames.userAgent(headers)),
        ]
        for (name, value) in options { mpv_set_option_string(h, name, value) }
        let rest = ScrubFrames.otherHeaders(headers)
        if !rest.isEmpty {
            // A comma list: escaped as MPVPlayerController.load does.
            let fields = rest.map { "\($0.key): \($0.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,"))" }
                .joined(separator: ",")
            mpv_set_option_string(h, "http-header-fields", fields)
        }
        guard mpv_initialize(h) >= 0 else {
            mpv_terminate_destroy(h)
            return nil
        }
        handle = h
        loadIssued = false
        loaded = false
        return h
    }

    private func destroy() {
        guard let h = handle else { return }
        handle = nil
        loadIssued = false
        loaded = false
        mpv_terminate_destroy(h)
    }

    /// Lets the stream go (its connection closes); the handle stays.
    private func stop() {
        guard let h = handle, loadIssued else { return }
        _ = command(h, ["stop"])
        loadIssued = false
        loaded = false
        let until = Date().addingTimeInterval(1)
        while Date() < until {
            guard let e = mpv_wait_event(h, 0.1)?.pointee else { continue }
            if e.event_id == MPV_EVENT_END_FILE || e.event_id == MPV_EVENT_IDLE { break }
        }
    }

    private enum Note { case none, failed, shutdown }

    /// Keeps the file's state from an event; END_FILE with an error means the stream failed.
    private func note(_ e: mpv_event) -> Note {
        switch e.event_id {
        case MPV_EVENT_FILE_LOADED:
            loaded = true
        case MPV_EVENT_END_FILE:
            loaded = false
            if let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(e.data)), ef.pointee.reason == MPV_END_FILE_REASON_ERROR {
                loadIssued = false
                return .failed
            }
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            break
        }
        return .none
    }

    private func decode(_ t: Double, id: Int) -> CGImage? {
        guard live(id), let h = open() else { return nil }
        // Events from before this request (an older seek, a cancelled load) are read first.
        while let e = mpv_wait_event(h, 0)?.pointee, e.event_id != MPV_EVENT_NONE {
            if note(e) == .shutdown { destroy(); return nil }
        }
        let spot = String(format: "%.3f", max(0, t))
        if !(loaded && command(h, ["seek", spot, "absolute+keyframes"])) {
            mpv_set_property_string(h, "start", spot)
            let target = url.isFileURL ? url.path : url.absoluteString
            guard command(h, ["loadfile", target, "replace"]) else { return nil }
            loadIssued = true
            loaded = false
        }
        let giveUp = Date().addingTimeInterval(20)
        while live(id), Date() < giveUp {
            guard let e = mpv_wait_event(h, 0.1)?.pointee else { continue }
            if e.event_id == MPV_EVENT_NONE { continue }
            if e.event_id == MPV_EVENT_PLAYBACK_RESTART {
                guard loaded else { continue }
                var pos: Double = 0
                if mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &pos) >= 0, abs(pos - t) > Self.staleAfter { continue }
                return grab(h)
            }
            switch note(e) {
            case .failed: return nil
            case .shutdown: destroy(); return nil
            case .none: break
            }
        }
        return nil
    }

    private func command(_ h: OpaquePointer, _ words: [String]) -> Bool {
        var cargs: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return mpv_command(h, &cargs) >= 0
    }

    /// The decoded frame (no subtitles, no OSD) as FrameGrab.mpvFrame takes it, copied into a small image.
    private func grab(_ h: OpaquePointer) -> CGImage? {
        let words: [String] = ["screenshot-raw", "video"]
        var cargs: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var result = mpv_node()
        guard mpv_command_ret(h, &cargs, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list,
              let keys = list.pointee.keys, let values = list.pointee.values else { return nil }
        var width = 0
        var height = 0
        var stride = 0
        var format = "bgr0"
        var bytes: UnsafeMutableRawPointer?
        var size = 0
        for i in 0..<Int(list.pointee.num) {
            guard let keyPtr = keys[i] else { continue }
            let value: mpv_node = values[i]
            switch String(cString: keyPtr) {
            case "w": if value.format == MPV_FORMAT_INT64 { width = Int(value.u.int64) }
            case "h": if value.format == MPV_FORMAT_INT64 { height = Int(value.u.int64) }
            case "stride": if value.format == MPV_FORMAT_INT64 { stride = Int(value.u.int64) }
            case "format": if value.format == MPV_FORMAT_STRING, let s = value.u.string { format = String(cString: s) }
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let ba = value.u.ba {
                    bytes = ba.pointee.data
                    size = Int(ba.pointee.size)
                }
            default: break
            }
        }
        guard let base = bytes, width > 0, height > 0, stride >= width * 4, size >= stride * height else { return nil }
        let info: UInt32
        switch format {
        case "bgr0", "bgra": info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        case "rgb0", "rgba": info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        default: return nil
        }
        // The node's bytes go with it: the frame is drawn into an image of its own before the defer frees them.
        guard let provider = CGDataProvider(dataInfo: nil, data: UnsafeRawPointer(base), size: stride * height, releaseData: { _, _, _ in }),
              let frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return ScrubFrames.owned(frame)
    }
}

// MARK: AVPlayer

/// AVAssetImageGenerator on an asset of its own, with the user agent and headers NativePlayerController
/// sends; the nearest frame within a few seconds (a keyframe, quick), at most 320 px.
final class AVScrubFrameSource: ScrubFrameSource, @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(url: URL, headers: [String: String]) {
        var options: [String: Any] = ["AVURLAssetHTTPUserAgentKey": ScrubFrames.userAgent(headers)]
        let rest = ScrubFrames.otherHeaders(headers)
        if !rest.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = rest }
        let asset = AVURLAsset(url: url, options: options)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ScrubFrames.maxWidth, height: ScrubFrames.maxWidth)
        let tolerance = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    func frame(at time: Double) async -> CGImage? {
        let once = ScrubOnce<CGImage?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<CGImage?, Never>) in
                once.set(c)
                generator.generateCGImageAsynchronously(for: CMTime(seconds: max(0, time), preferredTimescale: 600)) { image, _, _ in
                    once.resume(image.flatMap { ScrubFrames.owned($0) })
                }
            }
        } onCancel: {
            self.generator.cancelAllCGImageGeneration()
            once.resume(nil)
        }
    }

    func park() { generator.cancelAllCGImageGeneration() }
    func close() { generator.cancelAllCGImageGeneration() }
}

/// AVAssetImageGenerator first (AVPlayer plays this stream); if it gives no frame twice before its first,
/// mpv takes over for good.
final class FallbackScrubFrameSource: ScrubFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var primary: ScrubFrameSource?
    private var secondary: ScrubFrameSource?
    private let makeSecondary: () -> ScrubFrameSource
    private var failures = 0
    private var frames = 0
    static let switchAfter = 2

    init(primary: ScrubFrameSource, secondary: @escaping () -> ScrubFrameSource) {
        self.primary = primary
        makeSecondary = secondary
    }

    private var active: (ScrubFrameSource, Bool)? {
        lock.withLock {
            if let s = secondary { return (s, false) }
            if let p = primary { return (p, true) }
            return nil
        }
    }

    func frame(at time: Double) async -> CGImage? {
        guard let pick = active else { return nil }
        let image = await pick.0.frame(at: time)
        guard pick.1 else { return image }
        let dropped: ScrubFrameSource? = lock.withLock {
            if image != nil { frames += 1; return nil }
            failures += 1
            guard frames == 0, failures >= Self.switchAfter, secondary == nil else { return nil }
            secondary = makeSecondary()
            let old = primary
            primary = nil
            return old
        }
        dropped?.close()
        return image
    }

    func park() { lock.withLock { secondary ?? primary }?.park() }
    func close() { lock.withLock { secondary ?? primary }?.close() }
}

// MARK: fixtures

/// The fixtures' stand-in film: under `--phone-player-demo` the demo's still (panned and zoomed by
/// time, so each spot looks its own), else (and until the still has come) a colour for the time; a
/// little decode delay like a real one.
final class FixtureScrubFrameSource: ScrubFrameSource, @unchecked Sendable {
    private let duration: Double
    private let lock = NSLock()
    private var still: CGImage?

    init(duration: Double, still: URL?) {
        self.duration = duration
        guard let still else { return }
        URLSession.shared.dataTask(with: still) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data)?.cgImage else { return }
            self.lock.withLock { self.still = image }
        }.resume()
    }

    func frame(at time: Double) async -> CGImage? {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return nil }
        return Self.render(time: time, duration: duration, still: lock.withLock { still })
    }

    func park() {}
    func close() {}

    static func render(time: Double, duration: Double, still: CGImage?) -> CGImage? {
        let w = 320
        let h = 180
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        let f: Double = duration > 0 ? min(1, max(0, time / duration)) : 0
        if let still {
            // A window 70 % of the still's size, sliding left to right (and a little down) over the film.
            let cw = Double(still.width) * 0.7
            let ch = cw * 9 / 16
            let x = (Double(still.width) - cw) * f
            let y = max(0, (Double(still.height) - ch)) * (0.3 + 0.4 * f)
            if let crop = still.cropping(to: CGRect(x: x, y: y, width: cw, height: min(ch, Double(still.height)))) {
                ctx.interpolationQuality = .medium
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
        }
        let top = UIColor(hue: CGFloat(f), saturation: 0.55, brightness: 0.75, alpha: 1).cgColor
        let bottom = UIColor(hue: CGFloat(fmod(f + 0.15, 1)), saturation: 0.7, brightness: 0.35, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        return ctx.makeImage()
    }
}

// MARK: picking one

extension PhoneScrubPreview {
    /// The decoder for a stream: the fixtures' stand-in; mpv for a torrent (careful: it waits for the
    /// finger and lets go fast) and whenever mpv plays; AVAssetImageGenerator when AVPlayer plays a file
    /// it can open (not HLS), mpv after it fails.
    static func plan(url: URL, headers: [String: String], engine: PlayerEngineKind, duration: Double)
        -> (key: String, config: ScrubPreviewConfig, make: () -> ScrubFrameSource?) {
        let key = "\(engine.rawValue)|\(url.absoluteString)"
        if PlayerFixtures.standInEngine(for: url) {
            let still: URL? = PhoneLaunch.playerDemo ? PhoneFixtureEngine.demoPicture : nil
            return (key, .local, { FixtureScrubFrameSource(duration: duration, still: still) })
        }
        if TorrentEngine.streamRef(url) != nil {
            return (key, .torrent, { MPVScrubFrameSource(url: url, headers: headers) })
        }
        let config: ScrubPreviewConfig = url.isFileURL ? .local : .http
        if engine == .native, !ScrubFrames.isHLS(url) {
            return (key, config, {
                FallbackScrubFrameSource(primary: AVScrubFrameSource(url: url, headers: headers),
                                         secondary: { MPVScrubFrameSource(url: url, headers: headers) })
            })
        }
        return (key, config, { MPVScrubFrameSource(url: url, headers: headers) })
    }
}
