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
import Vision

struct SimilarItems: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(\.modelContext) private var context

    private let subject: BrandUpdate

    /// The answer, worked out once after the page is on screen.
    ///
    /// This was a `@Query` with **no predicate and no limit** — every event ever synced,
    /// materialised and then scanned in `body`, faulting each row's brand relationship and
    /// running two classifiers over it. On a store a few weeks old that is thousands of
    /// rows, and it ran *before the push could draw its first frame*, then twice more:
    /// `ProductDetailView` marks the item seen and `StockRefresh` stamps it, and each save
    /// invalidated the query. That is the lag on opening a product.
    ///
    /// Nothing about this row needs to be live. It is a suggestion about the item on
    /// screen, so it is computed once per subject, after the transition, out of a bounded
    /// fetch — and the page appears immediately with the row filling in behind it.
    @State private var found: [BrandUpdate] = []

    /// Below this the match is coincidence — two products that happen to share the word
    /// "cotton" are not alternatives, and a row of those is worse than no row.
    private static let minimumScore = 2.0
    private static let limit = 8

    /// How far back a candidate may be. "More like this" is an argument to act now, so a
    /// jacket from three seasons ago is not a useful answer even when it scores well —
    /// which makes the bound honest rather than merely cheap.
    private static let window: TimeInterval = 180 * 24 * 3_600
    /// A ceiling on the scan, whatever the window admits. A brand mid-season publishes
    /// hundreds of products in a sweep and eight of them are going to be shown.
    private static let candidateLimit = 600

    init(to update: BrandUpdate) {
        self.subject = update
    }

    private func score(
        _ candidate: BrandUpdate,
        against terms: Set<String>,
        slot: GarmentSlot,
        fingerprint: FeaturePrintObservation?
    ) -> Double {
        var score = 0.0
        // The strongest single signal: a jacket is an alternative to a jacket. It is not
        // enough on its own, or this becomes "other outerwear".
        if slot != .unknown, candidate.garmentSlot == slot { score += 1.5 }
        score += Double(terms.intersection(candidate.matchTerms).count)
        // A tie-break, not a driver. Something from the same brand is more likely to be a
        // genuine variant of what you are looking at, but a page full of one brand is a
        // catalogue rather than a suggestion.
        if candidate.brand?.id == subject.brand?.id { score += 0.5 }
        if let fingerprint {
            score += resemblance(of: candidate, to: fingerprint)
        }
        return score
    }

    /// How much the two actually *look* alike, worth up to two points.
    ///
    /// Everything else here matches vocabulary, which is blind in both directions: it
    /// cannot see that two jackets resemble each other when their merchandisers filed them
    /// under different words, and it happily proposes two unrelated products because both
    /// are tagged "cotton". `VisualReading` stores a perceptual fingerprint per analysed
    /// item and this is what it is for.
    ///
    /// **Added to the text score rather than replacing it**, and capped so it cannot carry
    /// a match on its own. Only saved items are ever analysed — `ImageTagger` deliberately
    /// does not walk the catalogue — so on most pairs one side has no fingerprint and this
    /// contributes nothing. A term that only *sometimes* exists must not be able to
    /// outrank the one that always does, or the ranking would reorder itself as the
    /// analysis backlog drained.
    private func resemblance(of candidate: BrandUpdate, to subject: FeaturePrintObservation) -> Double {
        guard let distance = VisualReading.distance(
            subject,
            candidate.visionFeaturePrint
        ) else { return 0 }
        // Vision's distance is unbounded and small numbers mean "alike". Anything past the
        // horizon is simply a different garment and scores nothing, rather than scoring
        // negatively — this is evidence for a match, never against one.
        guard distance < Self.resemblanceHorizon else { return 0 }
        return (1 - distance / Self.resemblanceHorizon) * 2
    }

    /// Past this, two photographs have nothing to say about each other. Chosen so the term
    /// is a strong nudge among plausible candidates rather than a filter — it is added to
    /// scores that start at 1.5 for a matching slot.
    private static let resemblanceHorizon = 1.1

    private func matches() -> [BrandUpdate] {
        let profile = sizes.profile
        let slot = subject.garmentSlot
        let terms = Set(subject.matchTerms)
        guard !terms.isEmpty || slot != .unknown else { return [] }

        // Narrowed by the store rather than by walking it — the same correction `FeedView`
        // made. SQLite answers the date bound from an index and hands back the newest few
        // hundred rows instead of the catalogue.
        let cutoff = Date().addingTimeInterval(-Self.window)
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.publishedAt >= cutoff },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.candidateLimit
        let candidates = (try? context.fetch(descriptor)) ?? []
        // Decoded once, not once per candidate — see `VisualReading.fingerprint`.
        let fingerprint = VisualReading.fingerprint(subject.visionFeaturePrint)

        var scored: [(update: BrandUpdate, score: Double)] = []
        for candidate in candidates {
            guard candidate.id != subject.id else { continue }
            guard candidate.kind != .collection else { continue }
            // Cheapest and most selective first: `followed` rejects whole brands, where the
            // photograph test rejects almost nothing and used to build a `URL` to do it.
            guard candidate.brand?.followed == true else { continue }
            guard candidate.hasPhotograph else { continue }
            guard candidate.passes(profile) else { continue }

            let value = score(candidate, against: terms, slot: slot, fingerprint: fingerprint)
            if value >= Self.minimumScore { scored.append((candidate, value)) }
        }

        scored.sort { a, b in
            // Newest wins a tie: a suggestion is worth more while it is still buyable.
            a.score == b.score ? a.update.publishedAt > b.update.publishedAt : a.score > b.score
        }
        return scored.prefix(Self.limit).map(\.update)
    }

    var body: some View {
        content
            // Keyed on the subject, so paging from one product to another recomputes and
            // nothing else does. `ProductDetailView` saves twice on appearance and neither
            // of those may cost this scan again.
            .task(id: subject.id) { found = matches() }
    }

    @ViewBuilder
    private var content: some View {
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
