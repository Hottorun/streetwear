// ImageGallery.swift
// A product's photographs, paged.
//
// Storefronts publish eight to twelve shots of a garment: front, back, detail, on-body.
// The catalogue already hands them over and `imageURLStrings` already stores them; for a
// long time the app only ever showed the first. Showing the rest costs no extra fetching and
// is the difference between a listing and a lookbook.

import StreetwCore
import SwiftUI

/// A horizontally paged set of photographs.
///
/// **Horizontal swipe belongs to photographs, and only to them.** It was claimed twice —
/// paging, and the feed's quick-save swipe to file or mark read — and settled by region: the
/// picture paged, the caption under it dragged. Phase 1's feed is a grid of half-width cards
/// with no unread state to clear, so the quick-save swipe went with it, and nothing competes
/// with a gallery for the direction any more. See *Gestures* in `CLAUDE.md`.
struct ImageGallery: View {
    let urls: [URL]
    var kind: BrandUpdate.Kind = .product
    /// Off for a single image, and off where the caller wants the lead photograph alone.
    var isPagingEnabled: Bool = true
    var drawnWidth: Int = 400
    /// Whether tapping opens the full-screen viewer. Off wherever a tap on the photograph
    /// belongs to something else — going full-screen from a scrolling list would hijack the
    /// commonest tap in the app.
    var isZoomable: Bool = false
    /// What sits behind each photograph. The collection passes `sweep`, which is fixed, so
    /// a saved item looks the same opened as it does on the wall — see `Color.sweep`.
    var backdrop: Color = .wash
    /// Set in place of a photograph that does not exist — see `UpdateImage.mark`. A
    /// gallery with an empty `urls` still renders one frame, and on the products whose
    /// source published no image at all that frame was the whole tile.
    var mark: String?
    /// Driven from outside when something else on the page decides which photograph is
    /// being talked about — selecting a colourway, above all. Nil keeps the gallery's own
    /// state, which is what every caller that only pages by hand wants.
    var selection: Binding<Int>?

    @State private var localIndex = 0
    @State private var isZoomed = false

    /// One index, owned in one of two places. Written as a computed binding rather than by
    /// syncing two properties: the gallery and the colourway row would otherwise each
    /// write the other's copy, and a swipe would fight the selection that caused it.
    ///
    /// Clamped on the way out. `onChange` resets a reused gallery, but it runs *after* the
    /// body that first sees the new photographs — so for one frame a stale index can point
    /// past the end of a shorter set, and a `TabView` with no page for its selection draws
    /// an empty rectangle. Clamping costs nothing and removes the flash.
    private var index: Binding<Int> {
        if let selection { return selection }
        return Binding(
            get: { min(max(localIndex, 0), max(urls.count - 1, 0)) },
            set: { localIndex = $0 }
        )
    }

    /// What to warm, in the order it is most likely to be wanted: forwards first, because
    /// that is how a gallery is read, and one back so returning is instant too.
    private var neighbours: [URL] {
        [index.wrappedValue + 1, index.wrappedValue + 2, index.wrappedValue - 1]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
    }

    var body: some View {
        gallery
            // **A gallery belongs to a garment, and this one is reused by the next.**
            //
            // The card in a `LazyVStack` is a view *description*; SwiftUI keeps the
            // underlying instance and its `@State` when the description at that position
            // changes. So swiping to the seventh photograph of a jacket and then marking the
            // brand read — which removed that card and pulled the next one up — left the
            // index at 7, and the shirt that arrived opened on its seventh frame. Worse when
            // the next product has fewer photographs than the last: the `TabView` has no
            // page with that tag and draws nothing at all, which reads as an image that
            // failed to load.
            //
            // Keyed on `urls` rather than on an id the gallery does not have: the set of
            // photographs *is* the identity of what is being paged through, and a caller
            // that legitimately swaps them (a colourway on its own handle) wants the same
            // reset. An externally owned `selection` is left alone — that binding belongs to
            // a page that knows when its own subject changed.
            .onChange(of: urls) { _, _ in localIndex = 0 }
            .fullScreenCover(isPresented: $isZoomed) {
                ImageViewer(urls: urls, initialIndex: index.wrappedValue)
            }
    }

    /// A tap opens the viewer, and only where the caller asked for it. Attached with
    /// `contentShape` so the transparent letterboxing around a `.fit` photograph is part
    /// of the target — otherwise tapping the white margin of a product shot does nothing,
    /// which reads as the gesture being unreliable rather than as a miss.
    @ViewBuilder
    private var zoomTap: some View {
        if isZoomable {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { isZoomed = true }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if urls.count <= 1 || !isPagingEnabled {
            UpdateImage(
                url: urls.first,
                kind: kind,
                aspect: 1,
                contentMode: .fit,
                drawnWidth: drawnWidth,
                backdrop: backdrop,
                mark: mark
            )
            .overlay { zoomTap }
        } else {
            TabView(selection: index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                    UpdateImage(
                        url: url,
                        kind: kind,
                        aspect: 1,
                        contentMode: .fit,
                        drawnWidth: drawnWidth,
                        backdrop: backdrop
                    )
                    .overlay { zoomTap }
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(1, contentMode: .fit)
            // A `TabView` builds each page as it is reached, so the load for the next
            // photograph began at the moment you landed on it — every swipe arrived on an
            // empty frame and then filled in. Warming the neighbours instead means the
            // page is already drawn by the time it is on screen.
            //
            // Keyed on `index` rather than run once: a gallery can be eight photographs,
            // and fetching all of them the instant a card scrolls past is a lot of
            // bandwidth spent on pictures nobody asked to see.
            .task(id: index.wrappedValue) { ImageLoader.shared.prefetch(neighbours, width: drawnWidth) }
            .overlay(alignment: .bottomTrailing) {
                // A printed count rather than dots: it says how many there are, which
                // dots only imply, and it matches the mono metadata everywhere else.
                DataLabel(text: "\(index.wrappedValue + 1)/\(urls.count)", size: 10, color: .ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.paper.opacity(0.92), in: Capsule())
                    .padding(12)
            }
        }
    }
}
