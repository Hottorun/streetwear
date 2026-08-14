// BrandPreviewSheet.swift
// Looking at a brand before deciding to follow it.
//
// A suggestion used to be three thumbnails and a Follow button, and there was nothing
// behind it — the card was the whole of what the app would ever tell you about a brand you
// hadn't followed. Following is the only way to find out more, which is backwards: it is
// the commitment, not the way to browse. So the card opens this instead, and Follow lives
// at the bottom of it.
//
// Everything here comes from data the recommendation already carried — the vector, the
// preview images, the affinity — plus the same taste comparison the ranking used. No extra
// request, and nothing about the person crosses the wire to produce it.

import StreetwCore
import SwiftUI

/// Choosing which of a brand's photographs are worth showing.
///
/// The judgement itself lives in `PreviewImages`, in the shared core, because the server
/// applies it when deciding what to put on the wire and this end applies it again over
/// whatever a server too old to know about it sent. Two copies of the vocabulary would
/// drift, and the symptom would be a delivery banner that one screen shows and another
/// hides.
enum BrandPreview {
    static func images(from strings: [String], limit: Int) -> [URL] {
        // No titles at this end — the wire carries images only — so this is the file-name
        // pass alone. It catches what it can; the server's pass, which has the product
        // names, is the one that does the real work.
        let rows = strings.map { (title: "", imageURL: Optional($0)) }
        return PreviewImages.pick(from: rows, limit: limit).compactMap(URL.init(string:))
    }
}

struct BrandPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: PopularBrand
    var reason: [String] = []
    let onFollow: () async -> Void
    var onDismiss: () -> Void = {}

    @State private var isFollowing = false

    private var images: [URL] {
        BrandPreview.images(from: item.previewImageURLs, limit: 12)
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    masthead
                    traits
                    if !images.isEmpty { grid }
                }
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle(item.brand.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The negative signal, where somebody who has just looked properly is
                    // most likely to want it.
                    Button("Not for me", systemImage: "hand.thumbsdown") { onDismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .safeAreaInset(edge: .bottom) { followBar }
        }
        .tint(.ink)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                BrandMonogram(
                    name: item.brand.name,
                    logoURL: item.brand.logoURL.flatMap(URL.init(string:)),
                    size: 56
                )
                VStack(alignment: .leading, spacing: 5) {
                    Wordmark(name: item.brand.name, size: 16)
                    if let host = item.brand.website.flatMap({ URL(string: $0)?.host() }) {
                        DataLabel(text: host.uppercased(), size: 10)
                    }
                }
                Spacer(minLength: 0)
            }
            Rule()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    /// Why this is here, and what the brand actually makes.
    ///
    /// Set as a run of facts rather than a sentence: this is the same material the ranker
    /// used, and dressing it up as prose would imply a confidence the numbers don't have.
    private var traits: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !reason.isEmpty {
                labelled("WHY THIS", reason.map { $0.capitalized }.joined(separator: " · "))
            }
            if let makes = topCategories {
                labelled("MAKES", makes)
            }
            if let price = priceBand {
                labelled("PRICES", price)
            }
            if Double(item.followers) >= Popularity.meaningfulFollowers {
                labelled("WATCHED BY", "\(item.followers) people")
            }
            if reason.isEmpty, topCategories == nil, priceBand == nil {
                // A brand that tags nothing usable. Saying so is better than an empty
                // column, and better than inventing a reason it was suggested.
                DataLabel(text: "NOT MUCH ON RECORD YET — THE PHOTOGRAPHS ARE THE BEST GUIDE")
            }
        }
        .padding(.horizontal, 20)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            DataLabel(text: label, size: 10)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.editorial(15))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The two or three garment types the catalogue is mostly made of.
    private var topCategories: String? {
        guard let vector = item.vector else { return nil }
        let named = vector.categories
            .filter { $0.key != GarmentSlot.unknown.rawValue && $0.value >= 0.12 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { GarmentSlot(rawValue: $0.key)?.label }
        return named.isEmpty ? nil : named.joined(separator: " · ")
    }

    /// Where the brand sits against everything else in the catalog, in words.
    ///
    /// Words rather than an amount, because `pricePercentile` is a *rank* — brands store
    /// their own currency and there are no exchange rates anywhere in this system. Printing
    /// a number here would be inventing one.
    private var priceBand: String? {
        guard let percentile = item.vector?.pricePercentile else { return nil }
        switch percentile {
        case ..<0.25: return "Among the cheaper brands here"
        case ..<0.5: return "Below the middle"
        case ..<0.75: return "Above the middle"
        default: return "Among the dearest here"
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule().padding(.horizontal, 20)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(images, id: \.self) { url in
                    UpdateImage(url: url, aspect: 1, drawnWidth: 200, mark: item.brand.name)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var followBar: some View {
        VStack(spacing: 0) {
            Rule()
            HStack {
                FollowButton(isWorking: $isFollowing, action: {
                    await onFollow()
                    dismiss()
                }, width: 120)
                Spacer()
                DataLabel(text: "YOU CAN UNFOLLOW ANY TIME", size: 10)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.paper)
    }
}
