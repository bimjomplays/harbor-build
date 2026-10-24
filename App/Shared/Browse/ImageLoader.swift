import SwiftUI
import UIKit
import ImageIO

/// Poster/backdrop loading with a memory cache on top of URLCache in the Caches folder.
/// Both are purgeable; a miss only costs a refetch.
///
/// Images are decoded downsampled (ImageIO thumbnails) to the size they are drawn at,
/// or to a 1920 px long edge when the caller gives no size: a full-size 4K backdrop is ~33 MB
/// decoded and Apple TV HD has 2 GB of RAM for everything. The decode happens here, off the main
/// thread, instead of lazily at first draw.
actor ImageLoader {
    static let shared = ImageLoader()

    /// The pixel box an image is drawn in; `fit` for `.fit` content, else `.fill`.
    struct Target: Hashable, Sendable {
        var width: Int
        var height: Int
        var fit: Bool = false
        /// Never decode above the source's own pixels. ImageIO's thumbnail
        /// call can scale a small source UP to the asked size (a w780 backdrop asked for 2665 px
        /// became ~16 MB decoded instead of ~1.3 MB); the TV leaves this off and decodes as before.
        var capToSource: Bool = false
    }

    /// Long edge for callers that give no size (a full-screen backdrop on a 1080p screen).
    static let defaultMaxPixel = 1920
    /// Long edge a sized request can reach (a full-screen backdrop at 2x on Apple TV 4K).
    static let sizedMaxPixel = 3840

    private let session: URLSession
    private let urlCache: URLCache
    /// NSCache is thread-safe, so `cached(for:target:)` reads it straight from the main actor.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    /// One fetch + decode per key, shared by every caller asking for it.
    /// `waiters` counts the callers still waiting; when the last one is cancelled (its RemoteImage
    /// scrolled off screen, or its URL or size changed) the download and decode are cancelled too.
    /// They used to run to the end regardless, so a fast scroll through a long grid queued every
    /// poster it passed (6 downloads per host at a time) ahead of the ones actually on screen.
    private struct Flight {
        let id: Int
        let task: Task<UIImage?, Never>
        var waiters: Int
    }
    private var inflight: [String: Flight] = [:]
    private var nextFlight = 0
    private static let urlCacheMemory = 32 << 20

    init() {
        let cfg = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("harbor-images")
        let cache = URLCache(memoryCapacity: Self.urlCacheMemory, diskCapacity: 400 << 20, directory: dir)
        urlCache = cache
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        memory.countLimit = 600
        // 1/16 of the device's RAM, 48...160 MB (128 MB on a 2 GB Apple TV HD).
        let ram = ProcessInfo.processInfo.physicalMemory
        memory.totalCostLimit = Int(min(UInt64(160 << 20), max(UInt64(48 << 20), ram / 16)))
    }

    private static func cacheKey(_ url: URL, _ target: Target?) -> String {
        let raw = url.absoluteString
        return target.map { "\(raw)#\($0.width)x\($0.height)\($0.fit ? "f" : "c")\($0.capToSource ? "n" : "")" } ?? raw
    }

    /// The decoded bitmap when it is already in memory, with no actor hop:
    /// a poster scrolled back into view draws its art on its first frame instead of a plate and a fade.
    nonisolated func cached(for url: URL, target: Target? = nil) -> UIImage? {
        memory.object(forKey: Self.cacheKey(url, target) as NSString)
    }

    func image(for url: URL, target: Target? = nil) async -> UIImage? {
        let keyString = Self.cacheKey(url, target)
        let key = keyString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        // A caller that is already cancelled (a cell that scrolled past) starts nothing.
        if Task.isCancelled { return nil }
        let flight: Flight
        if var joined = inflight[keyString] {
            joined.waiters += 1
            inflight[keyString] = joined
            flight = joined
        } else {
            let session = self.session, req = URLRequest(url: url)
            // Detached: fetches and decodes run side by side, not one at a time on this actor.
            let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
                guard let (data, resp) = try? await session.data(for: req),
                      (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
                if Task.isCancelled { return nil }
                return ImageLoader.decode(data, target: target)
            }
            nextFlight += 1
            flight = Flight(id: nextFlight, task: task, waiters: 1)
            inflight[keyString] = flight
        }
        let flightId: Int = flight.id
        let task: Task<UIImage?, Never> = flight.task
        let img: UIImage? = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(keyString, flightId: flightId) }
        }
        // The first caller back finishes the flight: it caches the bitmap and clears the entry.
        if inflight[keyString]?.id == flightId {
            inflight[keyString] = nil
            if let img { memory.setObject(img, forKey: key, cost: Self.cost(of: img)) }
        }
        return img
    }

    /// A caller stopped waiting (its task was cancelled); the last one out cancels the fetch.
    private func leave(_ keyString: String, flightId: Int) {
        guard var flight = inflight[keyString], flight.id == flightId else { return }
        flight.waiters -= 1
        if flight.waiters > 0 {
            inflight[keyString] = flight
            return
        }
        inflight[keyString] = nil
        flight.task.cancel()
    }

    /// On a memory warning: drop every decoded bitmap and the URL cache's RAM
    /// copy. The files on disk stay, so art shown again is a decode, not a download, and views keep
    /// the images they are drawing (only the cache lets go of its references).
    func purgeMemory() {
        memory.removeAllObjects()
        urlCache.memoryCapacity = 0
        urlCache.memoryCapacity = Self.urlCacheMemory
    }

    /// Poster-service urls (RemoteImage `url` with a `fallback`) that failed while their
    /// fallback loaded. A failed load is never cached, so with a bad or rate-limited RPDB key every
    /// poster tile scrolled back into view asked RPDB again and sat on the bare plate for that round
    /// trip before its plain poster came back: the art blinked on every return. Session only, bounded.
    private var deadPrimaries = Set<String>()

    func isDead(_ raw: String) -> Bool { deadPrimaries.contains(raw) }

    func markDead(_ raw: String) {
        if deadPrimaries.count >= 4096 { deadPrimaries.removeAll() }
        deadPrimaries.insert(raw)
    }

    /// Decoded bytes of the bitmap (what the cache limit is about).
    private static func cost(of img: UIImage) -> Int {
        if let cg = img.cgImage { return cg.bytesPerRow * cg.height }
        return Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    /// Decode `data` no larger than needed: for a target box, the size at which the image covers
    /// (fill) or fits (fit) that box; never above the caps, never upscaled (ImageIO thumbnails
    /// only shrink).
    static func decode(_ data: Data, target: Target?) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0 else {
            return UIImage(data: data)
        }
        var maxPixel = defaultMaxPixel
        if let target, target.width > 0, target.height > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            // EXIF orientations 5-8 are a quarter turn: the drawn width is the stored height.
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
            let sx = Double(target.width) / w, sy = Double(target.height) / h
            let s = target.fit ? min(sx, sy) : max(sx, sy)
            let edge = (max(w, h) * s).rounded(.up)
            maxPixel = edge.isFinite ? min(sizedMaxPixel, max(1, Int(edge))) : defaultMaxPixel
            if target.capToSource { maxPixel = min(maxPixel, Int(max(w, h).rounded(.up))) }
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}
