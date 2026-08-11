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

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                CachedImage(url: url, width: drawnWidth) { image in
                    image.resizable().aspectRatio(contentMode: contentMode)
                } placeholder: {
                    Color.clear
                } failure: {
                    symbol
                }
            }
            .background(Color.wash)
            .clipped()
    }

    private var symbol: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 15, weight: .light))
            .foregroundStyle(Color.muted)
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
            let image = try await ImageLoader.shared.load(resolved)
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

    /// One attempt, then two retries. Beyond that it is not a blip, and a phone on a bad
    /// connection should not keep paying for the same photograph.
    private static let attempts = 3

    private var inFlight: [URL: Task<UIImage, any Error>] = [:]

    /// Decoded images, keyed by the exact URL requested. `URLCache` holds the bytes, but
    /// re-decoding a 400px JPEG on every cell reuse is the other half of scroll cost.
    private let decoded = NSCache<NSURL, UIImage>()

    private init() {
        decoded.countLimit = 220
    }

    nonisolated func cached(_ url: URL) -> UIImage? {
        decoded.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async throws -> UIImage {
        if let hit = decoded.object(forKey: url as NSURL) { return hit }

        // A grid can ask for the same URL from several cells at once — a product's
        // colourways often share a photograph. One request, many awaiters.
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<UIImage, any Error> {
            try await Self.fetch(url)
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let image = try await task.value
        decoded.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func fetch(_ url: URL) async throws -> UIImage {
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

                guard let image = UIImage(data: data) else { throw ImageError.notAnImage }
                return image
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
