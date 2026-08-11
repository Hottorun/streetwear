// ImageViewer.swift
// A photograph, as large as the screen allows, and closer than that.
//
// Storefront originals are 2000–3000px and the app has been deliberately asking for a
// 400px rendition, because that is all a feed card draws. But the reason to look at a
// product photograph at all is often the detail — the weave, the stitching, how worn the
// wash is, whether the logo is embroidered or printed — and none of that survives at
// tile size. The catalogue is already carrying that resolution; there just was no way to
// reach it.
//
// So: tap a photograph, get it full-screen on black, pinch to zoom, drag to pan, and
// swipe between the rest. Three decisions carry it:
//
// - **A bigger rendition is fetched only here.** `ImageRendition` is asked for a wide
//   width the moment the viewer opens, so the pixels are actually there to zoom into.
//   Doing that in the feed would undo the whole reason renditions exist.
// - **Zoom is per photograph and resets on page.** Arriving at the next image already
//   magnified and panned to a corner is disorienting, and nobody means it.
// - **Panning is bounded to the image.** Free panning lets you drag a picture entirely
//   off-screen and then wonder where it went.

import StreetwCore
import SwiftUI

struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss

    let urls: [URL]
    var initialIndex: Int = 0

    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                    // Identity keyed to the URL so paging away genuinely tears the zoom
                    // state down rather than carrying it to the next photograph.
                    ZoomablePhotograph(url: url, onDismiss: { dismiss() })
                        .id(url)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack(spacing: 14) {
                if urls.count > 1 {
                    Text("\(index + 1)/\(urls.count)")
                        .font(.data(11, .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
        }
        .statusBarHidden()
        .onAppear {
            index = min(max(initialIndex, 0), max(urls.count - 1, 0))
            // Every photograph at full width, not just the one landed on: the reason to
            // be here is to compare details, and paging is the whole point of the count
            // in the corner.
            ImageLoader.shared.prefetch(urls, width: Self.zoomWidth)
        }
    }

    /// What to ask the CDN for once someone is actually looking closely. Deliberately far
    /// above the feed's 400 — there is no point offering a 3× zoom into a 400px file.
    static let zoomWidth = 1600
}

/// One photograph that can be magnified and moved.
private struct ZoomablePhotograph: View {
    let url: URL
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero

    private static let maxScale: CGFloat = 5

    private var live: CGFloat { scale * pinch }

    var body: some View {
        GeometryReader { geometry in
            CachedImage(url: url, width: ImageViewer.zoomWidth) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            } failure: {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(live)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        scale = min(max(scale * value.magnification, 1), Self.maxScale)
                        pinch = 1
                        offset = bounded(offset, in: geometry.size)
                    }
            )
            .simultaneousGesture(
                // Only while zoomed in. At 1× a horizontal drag belongs to the pager, and
                // claiming it here would make the gallery impossible to page through.
                DragGesture()
                    .onChanged { if live > 1.01 { drag = $0.translation } }
                    .onEnded { value in
                        guard live > 1.01 else { return }
                        offset = bounded(
                            CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            ),
                            in: geometry.size
                        )
                        drag = .zero
                    }
            )
            .onTapGesture(count: 2) {
                // The gesture people actually reach for. Toggling rather than stepping,
                // because a double-tap is a request to see it big or see it whole.
                withAnimation(.easeOut(duration: 0.22)) {
                    if scale > 1.01 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = 2.5
                    }
                }
            }
            .onTapGesture { if scale <= 1.01 { onDismiss() } }
            .animation(.easeOut(duration: 0.18), value: scale)
        }
    }

    /// Keeps the photograph overlapping the screen. A magnified image can be moved by
    /// however much of it is off-screen and no further, so it can never be flung into the
    /// void and lost.
    private func bounded(_ proposed: CGSize, in canvas: CGSize) -> CGSize {
        let slackX = max((canvas.width * live - canvas.width) / 2, 0)
        let slackY = max((canvas.height * live - canvas.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }
}
