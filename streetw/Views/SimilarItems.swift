// SimilarItems.swift
// "More like this", from brands you already follow.
//
// A product page ended at the storefront button — the one control that sends you *out* of
// the app. Everything the app knows about the thing you are looking at (its tags, its
// type, its slot, its brand) was already stored and read by nothing at the moment it was
// most useful, which is while you are deciding.
//
// Deliberately drawn from what is already followed rather than from the whole catalog.
// That keeps it a **local** computation over rows the phone already holds — no request,
// nothing about what you are browsing leaving the device — and it is the more useful
// answer anyway: a similar piece from a brand you have already chosen to watch is one you
// can act on, where one from a brand you have never heard of is a second decision.

import StreetwCore
import SwiftData
import SwiftUI

struct SimilarItems: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Query private var everything: [BrandUpdate]

    private let subject: BrandUpdate

    /// Below this the match is coincidence — two products that happen to share the word
    /// "cotton" are not alternatives, and a row of those is worse than no row.
    private static let minimumScore = 2.0
    private static let limit = 8

    init(to update: BrandUpdate) {
        self.subject = update
    }

    private func score(_ candidate: BrandUpdate, against terms: Set<String>, slot: GarmentSlot) -> Double {
        var score = 0.0
        // The strongest single signal: a jacket is an alternative to a jacket. It is not
        // enough on its own, or this becomes "other outerwear".
        if slot != .unknown, candidate.garmentSlot == slot { score += 1.5 }
        score += Double(terms.intersection(candidate.matchTerms).count)
        // A tie-break, not a driver. Something from the same brand is more likely to be a
        // genuine variant of what you are looking at, but a page full of one brand is a
        // catalogue rather than a suggestion.
        if candidate.brand?.id == subject.brand?.id { score += 0.5 }
        return score
    }

    private var matches: [BrandUpdate] {
        let profile = sizes.profile
        let slot = subject.garmentSlot
        let terms = Set(subject.matchTerms)
        guard !terms.isEmpty || slot != .unknown else { return [] }

        var scored: [(update: BrandUpdate, score: Double)] = []
        for candidate in everything {
            guard candidate.id != subject.id else { continue }
            guard candidate.kind != .collection else { continue }
            guard candidate.primaryImageURL != nil else { continue }
            guard candidate.brand?.followed == true else { continue }
            guard candidate.passes(profile) else { continue }

            let value = score(candidate, against: terms, slot: slot)
            if value >= Self.minimumScore { scored.append((candidate, value)) }
        }

        scored.sort { a, b in
            // Newest wins a tie: a suggestion is worth more while it is still buyable.
            a.score == b.score ? a.update.publishedAt > b.update.publishedAt : a.score > b.score
        }
        return scored.prefix(Self.limit).map(\.update)
    }

    var body: some View {
        let found = matches
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Rule().padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 5) {
                    Text("More like this")
                        .font(.editorial(19))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: "FROM BRANDS YOU FOLLOW")
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(found) { item in
                            SimilarTile(update: item)
                                .productLink(item)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
    }
}

private struct SimilarTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 200,
                mark: update.brand?.name
            )
            .frame(width: 132)

            Text(update.title)
                .font(.editorial(13))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 132, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let price = update.priceText {
                DataLabel(text: price, size: 10)
            }
        }
    }
}
