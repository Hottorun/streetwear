// CachedImage.swift
// Loading a photograph reliably, which `AsyncImage` does not do.
//
// Three separate faults produced the same symptom — images that sometimes never appear:
//
// 1. **`AsyncImage` treats cancellation as failure.** Scrolling a `LazyVGrid` tears down
//    off-screen rows, which cancels their in-flight loads. `AsyncImage` resolves those to
//    `.failure` and renders the error branch permanently; scrolling back shows a broken
//    tile for an image that was merely interrupted. There is no retry and no way to ask
//    for one.
// 2. **No retry of any kind.** A single dropped connection on a phone is normal and
//    ordinary, and left the tile empty until the view was rebuilt from scratch.
// 3. **Full-resolution originals.** Storefront product shots are 2000–3000px and several
//    megabytes; the feed draws them at 120–350pt and pulls seven per brand spread. That
//    is slow enough to make (1) and (2) fire constantly, so the sizing is not a separate
//    optimisation — it is most of the fix.
//
// Everything still goes through `URLCache.shared`, which `Net.configureSharedCache` sets
// up at launch, so a second sight of an image is free.

import OSLog
import StreetwCore
import SwiftUI

/// A photograph at a fixed aspect ratio, full width.
///
/// Sized by a transparent spacer with `.fit`, not by putting `.aspectRatio(_:.fill)` on
/// the image itself: with `.fill`, a flexible placeholder has no height to fill *to* and
/// grows without bound — one un-loaded lead image took over the entire screen.
struct UpdateImage: View {
    let url: URL?
    var kind: BrandUpdate.Kind = .product
    var aspect: CGFloat = 1
    /// `.fit` shows the whole garment on the wash, never cropped — right for a lead,
    /// where the object *is* the argument. `.fill` keeps a grid of thumbnails on a
    /// consistent rhythm, which matters more than seeing every shoelace.
    var contentMode: ContentMode = .fill
    /// Roughly how wide this will be drawn, in points. Decides which CDN rendition is
    /// requested; the ladder in `ImageRendition` snaps nearby values together so a grid
    /// tile and a slightly different grid tile still share one cache entry.
    var drawnWidth: Int = 400
    /// What sits behind the photograph — which for a `.fit` image is the letterboxing
    /// around it, and for a transparent PNG is everything the garment isn't.
    ///
    /// `wash` by default, which is adaptive and correct for the feed: a card there is a
    /// notice, and it should belong to whatever appearance the phone is in. The collection
    /// is the other case — a wall of photographs, which do not invert — and passes
    /// `sweep`. See `Color.sweep` for why that one is fixed.
    var backdrop: Color = .wash
    /// What to set in place of a photograph that will never arrive.
    ///
    /// Some products genuinely have none: Palace's sitemap publishes entries with no
    /// `<image:loc>`, so those rows hold an empty image array permanently. They were
    /// drawing the loading-ish `kind` symbol — a small grey sparkle on a blank tile —
    /// which is indistinguishable from an image that is still coming, so a brand page sat
    /// there apparently loading forever. A wordmark is a statement instead of a wait: it
    /// says *this is the thing, we just have no picture of it*.
    var mark: String?

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                CachedImage(url: url, width: drawnWidth) { image in
                    image.resizable().aspectRatio(contentMode: contentMode)
                } placeholder: {
                    Color.clear
                } failure: {
                    fallback
                }
            }
            .background(backdrop)
            .clipped()
    }

    @ViewBuilder
    private var fallback: some View {
        if let mark, !mark.isEmpty {
            Wordmark(name: mark, size: 10, color: .muted)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color.muted)
        }
    }
}

/// Loads an image, retrying transient failures and asking the CDN for a sensible size.
struct CachedImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL?
    var width: Int = 400
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded(UIImage)
        /// Genuinely failed after exhausting retries — a 404, a malformed image. Distinct
        /// from cancellation, which is not a failure at all and stays in `.loading`.
        case failed
    }

    /// The requested URL is what identifies this load. Keying the task on it means a
    /// recycled row in a `LazyVGrid` starts the new image rather than keeping the old
    /// one's result.
    private var resolved: URL? {
        url.map { ImageRendition.sized($0, width: width) }
    }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let image): content(Image(uiImage: image))
            case .loading: placeholder()
            case .failed: failure()
            }
        }
        .task(id: resolved) { await load() }
    }

    private func load() async {
        guard let resolved else {
            phase = .failed
            return
        }

        // A cached response makes this synchronous in practice, so don't flash a
        // placeholder over an image we already have.
        if let cached = ImageLoader.shared.cached(resolved) {
            phase = .loaded(cached)
            return
        }

        phase = .loading
        do {
            let image = try await ImageLoader.shared.load(resolved, width: width)
            phase = .loaded(image)
        } catch is CancellationError {
            // Scrolled away. Emphatically *not* a failure: leaving it in `.loading` means
            // scrolling back re-runs the task and the image appears, where `AsyncImage`
            // would have latched a broken tile forever.
        } catch {
            phase = .failed
        }
    }
}

/// The shared loader. Retries, and collapses duplicate in-flight requests for one URL.
actor ImageLoader {
    static let shared = ImageLoader()

    nonisolated private static let log = Logger(
        subsystem: "com.kern.functional.streetw",
        category: "images"
    )

    /// One attempt, then two retries. Beyond that it is not a blip, and a phone on a bad
    /// connection should not keep paying for the same photograph.
    private static let attempts = 3

    private var inFlight: [URL: Task<UIImage, any Error>] = [:]

    /// **Only successes used to be remembered, and that is what made a dead URL expensive.**
    ///
    /// A load that fails is retried twice with a backoff between (see `fetch`), and then the
    /// result is thrown away — so the *next* appearance of the same tile starts the same
    /// three attempts and the same 1.2 seconds of sleeping, forever. That is invisible while
    /// everything resolves and loud the moment one host does not: a brand whose domain is
    /// blocked by a DNS filter, or a `BrandMark.fallback` guess at `/favicon.ico` that the
    /// storefront 404s, burned a dozen requests in a single session and re-entered the
    /// backoff on every scroll back to the same row.
    ///
    /// So a refusal is now remembered for a while. Not forever: the reason the retries exist
    /// in the first place is that a phone in a tunnel is not a broken photograph, and an
    /// entry that never expired would turn one bad minute into a permanently empty tile —
    /// exactly the `AsyncImage` behaviour this whole type exists to avoid.
    private var refusals: [URL: Refusal] = [:]

    private struct Refusal {
        var until: Date
        /// Consecutive failures for this URL. Only the network-level class escalates on it;
        /// a 404 is a 404 at any count.
        var strikes: Int
    }

    /// How long a settled answer — a 4xx, or bytes that will not decode — is believed.
    /// Re-checking one of those costs a request per URL per half hour, which is nothing,
    /// and it is what lets a storefront that fixes its icon be picked up without a relaunch.
    private static let refusalWindow: TimeInterval = 30 * 60

    /// How long the *first* network-level failure is believed, doubling per consecutive
    /// failure up to `refusalWindow`. Short at the start because this is the class a retry
    /// genuinely fixes; longer each time because a host that has refused four times running
    /// is not having a moment.
    private static let wobbleWindow: TimeInterval = 60

    /// Refusals held at once. A cap rather than none because the keys are arbitrary URLs and
    /// this actor lives for the whole session; forgetting one costs a single request.
    private static let refusalLimit = 512

    /// Decoded images, keyed by the exact URL requested. `URLCache` holds the bytes, but
    /// re-decoding a 400px JPEG on every cell reuse is the other half of scroll cost.
    private let decoded = NSCache<NSURL, UIImage>()

    private init() {
        // **Bounded by bytes, not by count.** A count limit is meaningless when the entries
        // span three orders of magnitude: this one cache holds 130pt feed tiles, 400pt
        // leads and the 1600px renditions `ImageViewer` asks for, and 220 of the large ones
        // is well over a gigabyte. Now that the images arriving here are genuinely
        // rasterised rather than lazy wrappers, that is a real gigabyte — it would draw a
        // memory warning, `NSCache` would drop everything, and every visible photograph
        // would be fetched and decoded again. The churn reads as the whole app getting
        // slower the longer it is used.
        //
        // A fraction of physical memory rather than a fixed number, so the budget is one an
        // older phone can actually honour. The count limit stays as a backstop for a screen
        // full of very small images.
        decoded.totalCostLimit = min(160 << 20, Int(ProcessInfo.processInfo.physicalMemory / 16))
        decoded.countLimit = 400
    }

    nonisolated func cached(_ url: URL) -> UIImage? {
        decoded.object(forKey: url as NSURL)
    }

    /// Loads images that are about to be needed, with nobody waiting on the result.
    ///
    /// A paged gallery creates each page only as it is reached, so the load for photo *n*
    /// starts at the moment you arrive on it — which is why every swipe landed on an empty
    /// frame and then filled in. Warming the neighbours turns that into an image that is
    /// simply already there.
    ///
    /// Deliberately fire-and-forget, and deliberately unstructured: a prefetch started
    /// from a view's `.task` must **not** die when that task is cancelled, or paging
    /// quickly — exactly when this matters most — would cancel each warm-up on its way to
    /// the next one. It joins `inFlight`, so a page that catches up with its own prefetch
    /// awaits the same request rather than starting a second.
    nonisolated func prefetch(_ urls: [URL], width: Int) {
        let resolved = urls.map { ImageRendition.sized($0, width: width) }
        Task.detached(priority: .utility) { await self.enqueue(resolved, width: width) }
    }

    /// **One drain, with a bounded queue.**
    ///
    /// `prefetch` used to start its own detached task per call, and it is called per card:
    /// `BrandFeedView` fires one from every `GalleryCard` and another on every gallery page
    /// change. Scrolling a brand's whole output therefore spawned hundreds of independent
    /// serial queues which — since `URLSession` caps connections per host — collapsed into
    /// one unbounded, unordered FIFO. The photograph somebody is looking at *now* queued
    /// behind three hundred images they had already scrolled past.
    ///
    /// Newest wins: a prefetch is a guess about where attention is going, and the most
    /// recent guess is the best one. Older entries are dropped rather than queued, which is
    /// the whole point — an unbounded queue of stale guesses is worse than no prefetch.
    private var queue: [(url: URL, width: Int)] = []
    private var isDraining = false
    private static let queueDepth = 12

    private func enqueue(_ urls: [URL], width: Int) async {
        // A refused URL is skipped rather than queued: the queue is twelve deep and holds
        // guesses about where attention is going, and a guess that is known to fail would
        // displace one that might not.
        for url in urls
        where decoded.object(forKey: url as NSURL) == nil && inFlight[url] == nil && !isResting(url) {
            queue.removeAll { $0.url == url }
            queue.append((url, width))
        }
        if queue.count > Self.queueDepth {
            queue.removeFirst(queue.count - Self.queueDepth)
        }
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        // One at a time. The photograph the user is actually looking at is competing for the
        // same connection, and parallel prefetches would slow down the one load that
        // somebody is waiting on.
        while !queue.isEmpty {
            let next = queue.removeLast()
            guard decoded.object(forKey: next.url as NSURL) == nil else { continue }
            _ = try? await load(next.url, width: next.width)
        }
    }

    /// - Parameter width: the width in **points** this will be drawn at. It decides how far
    ///   the photograph is downsampled on the way in — see `decode`. It is passed rather
    ///   than inferred from the URL because the URL often does not say: `ImageRendition`
    ///   leaves unknown hosts alone, and those are the ones publishing the largest files.
    func load(_ url: URL, width: Int = 400) async throws -> UIImage {
        if let hit = decoded.object(forKey: url as NSURL) { return hit }

        // Asked for recently and refused. Failing here rather than on the wire is the whole
        // point: the caller gets the same answer it would have got, without three requests
        // and the backoff between them.
        if isResting(url) { throw ImageError.refused }

        // A grid can ask for the same URL from several cells at once — a product's
        // colourways often share a photograph. One request, many awaiters.
        if let existing = inFlight[url] { return try await existing.value }

        let maxPixel = ImageRendition.pixels(for: width)
        let task = Task<UIImage, any Error> {
            try await Self.fetch(url, maxPixel: maxPixel)
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let image: UIImage
        do {
            image = try await task.value
        } catch is CancellationError {
            // Scrolled away, not refused. Recording this would mean a fast scroll taught the
            // loader that every photograph it passed is broken.
            throw CancellationError()
        } catch {
            rest(url, after: error)
            throw error
        }
        // It answered, so whatever it did before is history — a host that was unreachable
        // for a minute must not stay on an escalating window once it is back.
        refusals[url] = nil
        decoded.setObject(image, forKey: url as NSURL, cost: image.byteCost)
        return image
    }

    /// Whether this URL is inside the window of a refusal, clearing the entry when it is not.
    private func isResting(_ url: URL) -> Bool {
        guard let refusal = refusals[url] else { return false }
        guard refusal.until > Date() else {
            refusals[url] = nil
            return false
        }
        return true
    }

    /// Records a refusal and works out how long to believe it.
    private func rest(_ url: URL, after error: any Error) {
        let strikes = (refusals[url]?.strikes ?? 0) + 1
        refusals[url] = Refusal(
            until: Date().addingTimeInterval(Self.window(after: error, strikes: strikes)),
            strikes: strikes
        )
        guard refusals.count > Self.refusalLimit else { return }
        let now = Date()
        refusals = refusals.filter { $0.value.until > now }
        // Still over: drop the lot rather than grow without bound. The cost of forgetting is
        // one request per URL, which is precisely what this table is saving.
        if refusals.count > Self.refusalLimit { refusals.removeAll() }
    }

    private static func window(after error: any Error, strikes: Int) -> TimeInterval {
        if let known = error as? ImageError {
            switch known {
            // A 5xx after three attempts is the host under load, not the photograph being
            // gone — it belongs with the timeouts below.
            case .badStatus(let code) where code >= 500: break
            case .badStatus, .notAnImage, .refused: return refusalWindow
            }
        }
        return min(wobbleWindow * pow(2, Double(strikes - 1)), refusalWindow)
    }

    /// Turns downloaded bytes into a photograph that is **already rasterised**.
    ///
    /// This was `UIImage(data:)`, and that is the single most expensive line the app had.
    /// `UIImage(data:)` parses the container header and wraps a data provider — it produces
    /// no pixels. The bitmap decode is deferred until CoreAnimation needs the layer
    /// contents, which happens **on the main thread, inside the commit**, at the moment the
    /// image is first drawn. So every photograph in the app was decoded on the main thread
    /// no matter how carefully the download was moved off it.
    ///
    /// The scale of it: `drawnWidth: 400` asks for a 1200px rendition, which is a 5.7MB
    /// bitmap and 15–40ms of JPEG decode. A brand spread commits seven of those in one
    /// frame. And `ImageRendition.sized` leaves an unrecognised host's URL alone, so a
    /// brand shipping 3200² PNGs — Palace does — was decoding 41MB bitmaps in the commit,
    /// hundreds of milliseconds each.
    ///
    /// Two keys carry the fix. `kCGImageSourceShouldCacheImmediately` forces the
    /// rasterisation to happen *here*, on the cooperative pool, rather than later on the
    /// main thread. `kCGImageSourceThumbnailMaxPixelSize` caps it at the size actually being
    /// drawn, which is what protects the hosts `sized` cannot rewrite. The transform key is
    /// not optional: `UIImage(cgImage:)` carries no orientation, so without it an EXIF
    /// -rotated photograph would draw on its side where `UIImage(data:)` had quietly
    /// corrected it.
    ///
    /// Alpha is preserved, which is load-bearing — a transparent PNG showing the app's own
    /// backdrop through the garment is the whole reason `UpdateImage` takes a `backdrop`.
    /// `decode`, for a caller that does its own fetching and wants nil rather than a throw.
    ///
    /// `ImageTagger` is the one: it needs to tell a dead URL from a dead network, so it
    /// cannot hand the download to `load` — but it wants exactly this decode, and was doing
    /// `UIImage(data:)` instead. Everything in the doc comment below is why that mattered.
    nonisolated static func decoded(_ data: Data, maxPixel: Int) -> UIImage? {
        try? decode(data, maxPixel: maxPixel)
    }

    /// The same decode, **guaranteed** not to run on the caller's actor.
    ///
    /// `decoded` is `nonisolated`, which is often read as "runs off the main thread" and does
    /// not mean that: a `nonisolated` synchronous function runs wherever it is called from.
    /// `ImageLoader`'s own callers are fine because it is an `actor` — but `ImageTagger` and
    /// `DiscoveryAnalysis` are `@MainActor` types that do their own fetching, so
    /// `await URLSession.data` resumed on the main actor and the full rasterisation happened
    /// there, in a loop that drains a whole backlog. Which is precisely the fault the comment
    /// on `decode` says was fixed for everything else.
    ///
    /// Detached rather than a structured child so it cannot be cancelled by whatever scroll
    /// or `.task(id:)` the caller happens to be inside, and at utility priority because this
    /// is background measurement and the frame being drawn outranks it.
    nonisolated static func decodedOffActor(_ data: Data, maxPixel: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            decoded(data, maxPixel: maxPixel)
        }.value
    }

    nonisolated private static func decode(_ data: Data, maxPixel: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageError.notAnImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Anything ImageIO cannot thumbnail, `UIImage` will not do better with. Falling
            // back keeps a format nobody anticipated drawing rather than showing a hole.
            guard let image = UIImage(data: data) else { throw ImageError.notAnImage }
            return image
        }
        return UIImage(cgImage: cgImage)
    }

    private static func fetch(_ url: URL, maxPixel: Int) async throws -> UIImage {
        var lastError: (any Error)?

        for attempt in 0..<attempts {
            // Cancellation is checked explicitly rather than left to `URLSession`, so a
            // scrolled-away load exits as `CancellationError` instead of being retried
            // twice on its way out.
            try Task.checkCancellation()

            do {
                var request = URLRequest(url: url)
                request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)

                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // A 404 will still be a 404 in a second; only server-side wobbles are
                    // worth another attempt.
                    guard http.statusCode >= 500 else { throw ImageError.badStatus(http.statusCode) }
                    lastError = ImageError.badStatus(http.statusCode)
                    try await backOff(attempt)
                    continue
                }

                do {
                    return try decode(data, maxPixel: maxPixel)
                } catch {
                    // **ImageIO names no URL.** A 200 carrying something that is not a
                    // picture — an error page served as HTML, a truncated body, a format with
                    // no decoder — surfaces as a bare `Error -17102 decompressing image` in
                    // the console with nothing to say which photograph it was, so it reads as
                    // background noise rather than as one identifiable tile that will never
                    // draw. The size is worth having with it: a few hundred bytes is a
                    // redirect or an error page, a megabyte is a real image this OS cannot
                    // read, and those have different fixes.
                    log.info(
                        "not an image (\(data.count, privacy: .public) bytes): \(url.absoluteString, privacy: .public)"
                    )
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImageError {
                throw error
            } catch {
                // Network-level: timeouts, dropped connections, DNS. Exactly the class
                // that a retry fixes and that used to leave a permanent hole in the grid.
                lastError = error
                try await backOff(attempt)
            }
        }

        throw lastError ?? ImageError.notAnImage
    }

    /// 300ms, then 900ms. Short enough that a recovered image still arrives while the
    /// user is looking at the same screen.
    private static func backOff(_ attempt: Int) async throws {
        guard attempt < attempts - 1 else { return }
        try await Task.sleep(for: .milliseconds(300 * NSDecimalNumber(decimal: pow(3, attempt)).intValue))
    }

    private enum ImageError: Error {
        case badStatus(Int)
        case notAnImage
        /// This URL failed recently and its window has not run out — thrown without asking
        /// the network at all. A failure to the caller, which is what it would have got.
        case refused
    }
}

extension UIImage {
    /// What this occupies once rasterised, which is what a cache budget has to be measured
    /// in. `NSCache` has no idea how big a `UIImage` is and will happily hold a gigabyte of
    /// them under a count limit.
    nonisolated var byteCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Images the app wrote itself — cutouts and fit renders — read once instead of per frame.
///
/// `BrandUpdate.cutoutURL` carried a comment arguing the opposite: that a cutout should be
/// read as a file each time *because* `UIImage(contentsOfFile:)` decodes lazily. That has
/// it backwards. Lazy decoding is the reason to cache, not the reason not to: each call
/// mints a **fresh** `UIImage` with a fresh data provider, so CoreAnimation can never reuse
/// a rasterisation it has already paid for, and a 900² RGBA fit render is decoded again on
/// the main thread every time the card is drawn.
///
/// Two call sites made that expensive rather than merely wasteful. `FitCard` read the same
/// render twice per body — once to draw and once to build the share item — in a
/// horizontally scrolling row. And `FitPieceImage.cutout` is read from `FitCanvas`, whose
/// body re-evaluates on every frame of a drag, for a dozen pieces: a dozen `open(2)` calls
/// and a dozen decodes at 120Hz.
///
/// Decoded eagerly on insertion so the cost is paid once and explicitly, and budgeted by
/// bytes for the same reason `ImageLoader`'s cache is.
@MainActor
enum LocalImage {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    static func load(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = url.path(percentEncoded: false) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: key as String) else { return nil }
        // Rasterise now rather than leaving it to the first draw, which would be inside a
        // CoreAnimation commit. `preparingForDisplay` can decline, in which case the lazy
        // image is still better cached than re-read.
        let ready = image.preparingForDisplay() ?? image
        cache.setObject(ready, forKey: key, cost: ready.byteCost)
        return ready
    }

    /// Drops an entry whose file has been rewritten underneath it.
    ///
    /// A fit render is named after the fit, so editing one overwrites the same path — and a
    /// cache keyed on the path would go on showing the previous arrangement for the rest of
    /// the session. Cutouts are named per lift and never rewritten, but forgetting one on
    /// deletion costs nothing.
    static func forget(_ url: URL?) {
        guard let url else { return }
        cache.removeObject(forKey: url.path(percentEncoded: false) as NSString)
    }
}

extension CachedImage where Placeholder == Color, Failure == Color {
    init(url: URL?, width: Int = 400, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(
            url: url,
            width: width,
            content: content,
            placeholder: { Color.clear },
            failure: { Color.clear }
        )
    }
}
