// FitStudio.swift
// "Wear it with", opened out into the whole outfit.
//
// `GoesWith` prints the four things in your wardrobe that would go with the garment on
// screen, and that row answers the question it was built for — *is this worth keeping* —
// and then stops. It cannot answer the one that follows it, which is the whole reason
// somebody reads the row in the first place: **what is the actual fit?** Four tiles side by
// side are four separate suggestions, not one outfit; two of them are tops and only one of
// them can be worn.
//
// So the row expands into this. The subject is fixed, every other position on the body is
// filled with the best thing the wardrobe has for it, and each of those is one tap away
// from becoming something else — with the alternatives ranked and each one saying why. The
// arrangement is live: change the trousers and the picture above changes with it.
//
// Three rules it inherits rather than reinvents, because a second copy of any of them would
// drift from the row this was opened from:
//
// - **The judgement is `Pairing`'s**, in the shared core, exactly as `GoesWith` and
//   `FitSuggestions` use it. This screen adds no vocabulary of its own.
// - **The order never moves under a thumb.** Candidates are ranked once, against the
//   *subject*, and swapping a piece does not re-sort the rows — the same property
//   `FeedView` learned the hard way and `FitSuggestions` is written around. What the
//   selection does change is the picture, which is the thing you asked to change.
// - **A fit is made of things you kept.** `Fit.items` is `[SavedItem]` and has to be, so
//   saving one that includes a garment nobody has kept keeps it first — the same reading
//   `StyleView.keep` gives the same tap, and the honest one: saving the fit is the moment
//   you decided you wanted the piece.
//
// Everything here is local. No request is made to open this screen, nothing about the
// wardrobe leaves the phone, and the arrangement it writes is the same structure the canvas
// edits — so a fit built here can be picked up and moved around by hand afterwards.

import StreetwCore
import SwiftData
import SwiftUI

/// The garment a fit is being built around, which is **not always something in the store**.
///
/// The studio opened from a product page has a `BrandUpdate` to work with. The one opened from
/// a discovery card does not, and must not be given one on the way in: the deck's whole
/// no-pollution rule is that a card from an unfollowed brand writes no row until somebody keeps
/// it (`FeedView` queries `!isSeen`, so a stored discovery page would empty thousands of
/// products into the unread feed). So the subject is an enum, and the row is minted at exactly
/// one moment — when the fit is saved, which is the moment the garment has been chosen.
enum FitSubject: Identifiable {
    /// Something the store already holds: a save, or a row from a followed brand's catalogue.
    case product(BrandUpdate)
    /// A card from the discovery feed, with whatever `DiscoveryAnalysis` has measured of its
    /// photograph. The sticker and the reading are passed in rather than looked up, because
    /// that measurement lives on the feed's analysis object and this sheet is presented from
    /// there.
    case discovery(
        DiscoverCard,
        sticker: UIImage?,
        reading: VisualReading.Reading?,
        packshot: URL?
    )

    var id: String {
        switch self {
        case .product(let update): return update.externalID
        case .discovery(let card, _, _, _): return card.productExternalID
        }
    }

    var title: String {
        switch self {
        case .product(let update): return update.title
        case .discovery(let card, _, _, _): return card.title
        }
    }

    /// The subject in the terms `Pairing` reasons about.
    ///
    /// For a discovery card the measured colour is folded in where there is one. It is often
    /// nil — analysis runs only over the cards at the viewport, and Vision does not run in the
    /// Simulator at all — and `Pairing` scores a nil colour as **neutral rather than badly**,
    /// which is what lets the fit rank before a single photograph has been decoded.
    var garment: Garment {
        switch self {
        case .product(let update):
            return update.garment
        case .discovery(let card, _, let reading, _):
            return Garment(
                id: card.productExternalID,
                title: card.title,
                productType: card.productType,
                tags: card.tags,
                color: reading?.color,
                secondaryColor: reading?.secondaryColor,
                busyness: reading?.busyness ?? 0,
                textCoverage: reading?.textCoverage ?? 0
            )
        }
    }

    /// The save this stands for, creating the row and the save if neither exists yet.
    ///
    /// Called **only from `save`**, never on the way in. For a discovery card this is
    /// `DiscoverSave.save`, which is the one place that knows how to write a card from an
    /// unfollowed brand — keyed `shopify:<id>` with `productExternalID` beside it, and already
    /// marked seen, so a later follow merges rather than minting a second card.
    @MainActor
    func materialise(in context: ModelContext) -> SavedItem? {
        switch self {
        case .product(let update):
            if let existing = update.saves.first { return existing }
            let created = SavedItem(update: update, type: .inspiration)
            context.insert(created)
            return created
        case .discovery(let card, _, _, _):
            guard let update = DiscoverSave.save(card, in: context) else { return nil }
            return update.saves.first
        }
    }
}

struct FitStudio: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    /// The garment the fit is being built around. Never swappable — it is what was on screen
    /// when the row was tapped, and a builder that lets you replace its own subject is just
    /// the canvas with extra steps.
    let subject: FitSubject

    /// The wardrobe piece the screen that opened this was already naming, by `pairingID`.
    ///
    /// **The two must agree.** A discovery card says "Goes with your Kith Mesh Donovan
    /// Jersey" and the studio then computed its own opening arrangement — greedy, over every
    /// slot, scored against everything chosen so far — so it could perfectly reasonably open
    /// on a different jacket with a different name at the top. That reads as the app
    /// contradicting itself one tap apart, which is worse than either answer being wrong: the
    /// card made a claim and the screen it opens is the demonstration of that claim. So the
    /// named piece is pinned into its own position first and the rest of the fit is built
    /// around it. Nil from `GoesWith`, which names nothing in particular.
    var anchor: String?

    /// Which candidate is in each position, by `Option.id`. Nil for a position deliberately
    /// left empty: a three-piece fit that works beats a four-piece fit with a wrong shoe in
    /// it, which is the same answer `FitSuggestions.accompaniment` gives by returning nil.
    ///
    /// Keyed on `FitPosition` rather than `GarmentSlot`, and that is what lets a fit hold a
    /// tee under a hoodie: a dictionary keyed by slot can hold one top, so the studio went on
    /// proposing a full-zip hoodie with nothing beneath it for as long as it did.
    @State private var picked: [FitPosition: String] = [:]
    /// The first arrangement is computed once, from the wardrobe, and then belongs to the
    /// person. Recomputing it per `body` would undo every swap.
    @State private var didArrange = false
    /// Set when a saved fit is handed on to the canvas to be arranged by hand.
    @State private var arranging: Fit?
    /// The ground the outfit is composed against, chosen here and carried into the fit. See
    /// `FitBackground` — fixed colours, so the preview, the render and the canvas agree.
    @State private var background: FitBackground = .base

    // MARK: - What there is to choose from

    /// One candidate for one position on the body.
    private struct Option: Identifiable {
        var piece: FitPiece
        /// The line `Pairing` gave for this against the subject. Nil is a real state — the
        /// verdict has nothing to say until a photograph has been measured — and prints
        /// nothing rather than filler, the same contract `PairingTile` holds.
        var reason: String?
        var score: Double

        var id: String { piece.id }
        var update: BrandUpdate { piece.update }
    }

    /// Everything the wardrobe offers, by position, ranked once.
    private struct Rack {
        var positions: [FitPosition] = []
        var options: [FitPosition: [Option]] = [:]
        /// The garments, built once and keyed by the option's id. `BrandUpdate.garment` runs
        /// two classifiers and builds a vocabulary set, and this screen asks about the same
        /// pieces once per candidate per position.
        var garments: [String: Garment] = [:]

        func garment(_ option: Option) -> Garment {
            garments[option.id] ?? option.update.garment
        }
    }

    /// Past this a row stops being a choice and starts being the collection. The wardrobe is
    /// reachable in full on the canvas; this is the shortlist.
    private static let perSlot = 12

    /// Built once per `body` and threaded down — the pattern `FeedView.Feed` and
    /// `FitCanvas.buildTray` both use, and needed for the same reason: this classifies every
    /// save and scores it, and a computed property in a SwiftUI view has no memory.
    private func buildRack() -> Rack {
        let anchor = subject.garment

        // The wardrobe, or everything kept when nothing has been filed as owned — the same
        // fallback `GoesWith` and `StyleView` use, because most people never split the two
        // axes and insisting on `.wardrobe` would leave this permanently empty. A save with
        // no photograph is excluded outright: there is nothing to draw and nothing to lift a
        // cutout from.
        let kept = saves.filter { $0.update?.imageURLStrings.isEmpty == false }
        let owned = kept.filter { $0.type == .wardrobe }
        let wardrobe = owned.isEmpty ? kept : owned

        var options: [FitPosition: [Option]] = [:]
        var garments: [String: Garment] = [:]
        for save in wardrobe {
            guard let update = save.update else { continue }
            let garment = update.garment
            guard garment.slot != .unknown, garment.id != anchor.id else { continue }

            // **The subject's position is excluded by *position*, not by slot.** Excluding
            // the whole `.top` slot meant a fit built around a hoodie could never be given a
            // tee to wear under it — the one thing a hoodie needs — because the tee is a top
            // and so is the hoodie. `Pairing`'s gate has the same shape and the same
            // exception, which is why the two are asked in this order.
            let position = FitArrangement.position(for: garment, splittingTops: true)
            let anchorPosition = FitArrangement.position(for: anchor, splittingTops: true)
            guard position != anchorPosition else { continue }

            // A layered pair is the one same-slot combination that is an outfit rather than a
            // mistake, so `Pairing` — which refuses same-slot pairs by design — is not asked
            // about it. Everything else goes through the gate untouched.
            let verdict = Outfit.isLayeredPair(anchor, garment)
                ? Pairing.Verdict(score: 0.6, reason: "Under it")
                : Pairing.score(anchor, with: garment, statement: statement.statement)
            guard !verdict.isRefused else { continue }

            garments[FitPiece(update: update, save: save).id] = garment
            options[position, default: []].append(
                Option(
                    piece: FitPiece(update: update, save: save),
                    reason: verdict.reason,
                    score: verdict.score
                )
            )
        }

        // Ties break on the id, so the shortlist is the same one on every render and across
        // relaunches. An unmeasured wardrobe scores everything identically, which makes this
        // the common case rather than the edge.
        for position in options.keys {
            options[position] = Array(
                (options[position] ?? [])
                    .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
                    .prefix(Self.perSlot)
            )
        }

        return Rack(
            positions: options.keys.sorted { $0.order < $1.order },
            options: options,
            garments: garments
        )
    }

    // MARK: - The fit as it currently stands

    /// What has been picked from the wardrobe, head down, with the position each occupies.
    /// The subject is **not** in here — it may have no row at all yet (see `FitSubject`), so
    /// it is drawn and saved separately.
    private func pieces(_ rack: Rack) -> [(position: FitPosition, piece: FitPiece)] {
        rack.positions
            .compactMap { position -> (FitPosition, FitPiece)? in
                guard let id = picked[position],
                      let piece = rack.options[position]?.first(where: { $0.id == id })?.piece
                else { return nil }
                return (position, piece)
            }
            .sorted { $0.0.order < $1.0.order }
    }

    /// The subject's own position, which is not chosen and cannot be swapped.
    private var subjectPosition: FitPosition {
        FitArrangement.position(for: subject.garment, splittingTops: true)
    }

    /// Every position in the fit as it stands, subject included — what decides whether the
    /// base layer is drawn tucked under a mid layer or takes the top spot on its own.
    private func positions(_ rack: Rack) -> [FitPosition] {
        [subjectPosition] + pieces(rack).map(\.position)
    }

    // MARK: - Body

    var body: some View {
        let rack = buildRack()

        return NavigationStack {
            Group {
                if rack.positions.isEmpty {
                    EditorialEmptyState(
                        title: "Nothing to put with it yet",
                        action: "KEEP A FEW MORE THINGS — A FIT IS BUILT OUT OF YOUR OWN COLLECTION"
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            preview(rack)
                            Rule()
                            ForEach(rack.positions) { position in
                                positionRow(position, rack: rack)
                            }
                            arrangeAction(rack)
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.paper)
            .navigationTitle("Build a fit")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(rack, thenArrange: false) }
                        .font(.data(13, .semibold))
                        // One garment is not a fit. The subject is always there, so this is
                        // the same bar the canvas holds at two placements.
                        .disabled(picked.isEmpty)
                }
            }
            // Arranged once, from the wardrobe, and never again — see `didArrange`.
            .onAppear {
                guard !didArrange else { return }
                didArrange = true
                picked = firstArrangement(rack)
            }
            .sheet(item: $arranging) { FitCanvas(fit: $0) }
        }
        .tint(.ink)
    }

    // MARK: - The picture

    /// The fit as it stands, drawn the way it will be stored.
    ///
    /// Square, and the same geometry `FitCanvasSurface` uses, so the preview is not an
    /// impression of the outfit — it is the outfit, at a smaller size.
    private func preview(_ rack: Rack) -> some View {
        let placed = pieces(rack)
        // Whether the base layer is drawn tucked under a mid layer or takes the top spot on
        // its own. Computed from the whole fit, subject included, so the preview and the
        // saved placements can only ever agree — see `FitArrangement`.
        let layered = FitArrangement.isLayered(positions(rack))

        return VStack(spacing: 0) {
            // **Squared by a flexible spacer, not by putting `.aspectRatio` on the reader.**
            // A `GeometryReader` is greedy in both axes and inside a scroll it settled at
            // full width and *some other* height — so `min(width, height)` was the height,
            // every piece was drawn against a different scale than the 900px square render
            // uses, and the promise this preview makes ("what you see is what is saved") was
            // quietly false. `UpdateImage` has always sized itself this way for the same
            // reason.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .background(background.color)
                .overlay {
                    GeometryReader { geometry in
                        let canvas = min(geometry.size.width, geometry.size.height)
                        ZStack {
                            // The subject, at its own position. Separate from the loop
                            // because it may not be a `FitPiece` at all yet — a discovery
                            // card has no row until the fit is kept.
                            place(
                                FitSubjectImage(subject: subject),
                                at: subjectPosition,
                                layered: layered,
                                canvas: canvas,
                                in: geometry.size
                            )

                            ForEach(placed, id: \.piece.id) { entry in
                                place(
                                    FitPieceImage(update: entry.piece.update),
                                    at: entry.position,
                                    layered: layered,
                                    canvas: canvas,
                                    in: geometry.size
                                )
                            }
                        }
                    }
                }
                .clipped()

            FitGroundPicker(selection: $background)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)

            // The subject, named. Everything else on this screen can be swapped, and without
            // saying which piece is fixed the picture is just a collage of four garments.
            HStack(spacing: 8) {
                DataLabel(text: "BUILT AROUND", size: 10, color: .signal)
                Text(subject.title)
                    .font(.editorial(13))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .padding(.top, 4)
    }

    /// One piece on the preview canvas, at the size and position its slot is stored with.
    ///
    /// Framed rather than scaled, matching `PlacedPiece` and `FitCanvasSurface` — a scale
    /// effect would enlarge the rendered tile rather than the drawing.
    private func place(
        _ content: some View,
        at position: FitPosition,
        layered: Bool,
        canvas: CGFloat,
        in size: CGSize
    ) -> some View {
        let spot = FitArrangement.spot(for: position, layered: layered)
        let side = canvas * 0.42 * spot.scale
        return content
            .frame(width: side, height: side)
            .position(x: spot.x * size.width, y: spot.y * size.height)
    }

    // MARK: - One position on the body

    private func positionRow(_ position: FitPosition, rack: Rack) -> some View {
        let options = rack.options[position] ?? []
        let chosen = picked[position]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(position.label)
                    .font(.editorial(17))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 0)
                // What is in this position right now, said in words as well as in the
                // picture — the row scrolls, and the chosen tile is often off screen.
                DataLabel(
                    text: chosen == nil
                        ? "NOT IN THIS FIT"
                        : (options.first { $0.id == chosen }?.update.title ?? "").uppercased(),
                    size: 10,
                    color: chosen == nil ? .muted : .ink
                )
                .lineLimit(1)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(options) { option in
                        Button {
                            // Tapping the one already in the fit takes it out. Leaving a
                            // position empty is a real answer, and it is the only way to say
                            // "no jacket" without hunting for a control that says so.
                            picked[position] = picked[position] == option.id ? nil : option.id
                        } label: {
                            OptionTile(
                                update: option.update,
                                reason: option.reason,
                                isChosen: chosen == option.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    /// The way out to the canvas, for when the arrangement itself is the point.
    ///
    /// This screen chooses *what* is in the fit; the canvas decides how it sits. Saving first
    /// is deliberate — the canvas edits a stored `Fit`, and handing it a draft would mean a
    /// second, quieter definition of what a fit is.
    private func arrangeAction(_ rack: Rack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule().padding(.top, 22)

            Button {
                save(rack, thenArrange: true)
            } label: {
                HStack(spacing: 8) {
                    Text("Save and arrange it by hand")
                        .font(.editorial(15))
                        .foregroundStyle(Color.ink)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muted)
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(picked.isEmpty)

            DataLabel(text: "MOVE, SCALE AND LAYER THE PIECES ON THE CANVAS")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    // MARK: - Arranging

    /// The opening proposal: the best thing the wardrobe has for each essential position,
    /// chosen against everything already in the fit rather than against the subject alone.
    ///
    /// Greedy and deterministic, and the scoring is `FitSuggestions.accompaniment`'s: the
    /// **worst** of a candidate's scores against the pieces already chosen, not the average,
    /// because a jacket that goes with the trousers and fights the shirt is not a good jacket
    /// for this outfit and an average lets one strong agreement hide one real clash.
    ///
    /// Only the essential positions are filled. Headwear and accessories are offered — they
    /// are in the rack, and putting a cap on is exactly the sort of thing this screen is for
    /// — but proposing them unasked turns a fit into a costume.
    ///
    /// **Anything that needs a layer under it gets one**, which is the rule
    /// `FitSuggestions.build` has had for a while and this screen did not: a full-zip hoodie
    /// was proposed over bare skin, one tap away from a row that would never have offered it.
    /// It runs last, so the tee is chosen against the finished outfit rather than deciding it.
    private func firstArrangement(_ rack: Rack) -> [FitPosition: String] {
        var chosen: [Garment] = [subject.garment]
        var result: [FitPosition: String] = [:]

        // The piece the card already named goes in first, and everything else is chosen
        // around it — see `anchor`. It is looked up rather than trusted: a wardrobe changes
        // between the card being drawn and the sheet being opened, and a named garment that
        // no longer qualifies should quietly fall back to the ordinary arrangement.
        // Matched on `pairingID`, which is what a `Garment` carries and what the card was
        // naming — `Option.id` is the save's identifier and the two are different strings.
        if let anchor,
           let position = rack.positions.first(where: {
               rack.options[$0]?.contains { $0.update.pairingID == anchor } == true
           }),
           let pinned = rack.options[position]?.first(where: { $0.update.pairingID == anchor }) {
            result[position] = pinned.id
            chosen.append(rack.garment(pinned))
        }

        // One garment per *slot*, so the two top positions are filled by the better of the
        // two rather than both — a fit opens as an outfit, and the layering rule below is
        // what adds a second top when the first one needs one.
        for slot in GarmentSlot.essential {
            let positions = rack.positions.filter { $0.slot == slot }
            guard !positions.isEmpty,
                  !positions.contains(where: { result[$0] != nil })
            else { continue }

            let pool = positions.flatMap { position in
                (rack.options[position] ?? []).map { (position: position, option: $0) }
            }
            guard let best = best(of: pool.map(\.option), against: chosen, rack: rack),
                  let position = pool.first(where: { $0.option.id == best.id })?.position
            else { continue }
            result[position] = best.id
            chosen.append(rack.garment(best))
        }

        // Nothing goes out with nothing under it. Only when the wardrobe can actually answer
        // — the rule completes a fit and must not empty one, which is the same line
        // `FitSuggestions` draws.
        let base = FitPosition(.top, .base)
        if chosen.contains(where: \.needsBaseLayer),
           result[base] == nil,
           let options = rack.options[base], !options.isEmpty,
           let under = best(of: options, against: chosen, rack: rack) {
            result[base] = under.id
        }

        return result
    }

    private func best(of options: [Option], against chosen: [Garment], rack: Rack) -> Option? {
        var best: (option: Option, score: Double)?
        for option in options {
            let garment = rack.garment(option)
            var worst = Double.greatestFiniteMagnitude
            var refused = false
            for piece in chosen {
                // A stated pairing carries a clash the wheel would refuse — the one input
                // here that was not inferred from something. See `StyleStatement`.
                let stated = statement.statement.statedPairing(between: piece, and: garment)
                if !stated, ColorHarmony.isClash(piece.color, garment.color) {
                    refused = true
                    break
                }
                // A layered pair is the one same-slot combination that is an outfit, so the
                // gate is not asked about it — see `buildRack`. It is still *scored*, on the
                // one axis that still applies to two tops: skipping it outright left `worst`
                // at `.greatestFiniteMagnitude`, which the guard below reads as "no
                // comparison, discard". So a hoodie with a wardrobe of tees (or the reverse)
                // picked nothing at all — every candidate was the exempted pair, every
                // candidate was thrown away, and the studio opened on a full row of options
                // with none chosen and Save disabled.
                if Outfit.isLayeredPair(piece, garment) {
                    worst = min(worst, ColorHarmony.score(piece.color, garment.color).score)
                    continue
                }
                let verdict = Pairing.score(piece, with: garment, statement: statement.statement)
                if verdict.isRefused {
                    refused = true
                    break
                }
                worst = min(worst, verdict.score)
            }
            guard !refused, worst < .greatestFiniteMagnitude else { continue }
            if let current = best,
               current.score > worst || (current.score == worst && current.option.id <= option.id) {
                continue
            }
            best = (option, worst)
        }
        return best?.option
    }

    // MARK: - Keeping it

    /// Turns the arrangement into a stored `Fit`.
    ///
    /// **Anything in it that has not been kept is kept first.** A `Fit` holds `SavedItem`s —
    /// that is what makes an outfit a list of things you own, and what lets "one of these came
    /// back in stock" mean anything later — so a fit built around a garment from a product
    /// page cannot be written as it stands. Saving it is the honest reading of the tap, not a
    /// workaround: the subject is the thing you were looking at when you decided to build an
    /// outfit around it. Filed as inspiration rather than wardrobe, because you have not
    /// bought it — the same call `StyleView.keep` makes.
    private func save(_ rack: Rack, thenArrange: Bool) {
        let composed = pieces(rack)
        guard !composed.isEmpty else { return }

        var arranged: [(position: FitPosition, itemID: UUID)] = []
        var items: [SavedItem] = []

        // The subject first, and this is where a discovery card becomes a row in the store —
        // never on the way in. See `FitSubject.materialise`.
        if let anchor = subject.materialise(in: context) {
            items.append(anchor)
            arranged.append((subjectPosition, anchor.id))
        }

        for entry in composed {
            let save = entry.piece.save ?? {
                let created = SavedItem(update: entry.piece.update, type: .inspiration)
                context.insert(created)
                return created
            }()
            items.append(save)
            arranged.append((entry.position, save.id))
        }

        // What the app makes of the finished arrangement, in the one sentence it can say
        // about the whole thing — which is what the card under it prints when nobody has
        // named the fit. See `Fit.verdict`: the garment titles this replaced were long
        // enough that two different outfits truncated to the same string.
        let assembled = [subject.garment]
            + composed.map { rack.garments[$0.piece.id] ?? $0.piece.update.garment }
        let fit = Fit(
            items: items,
            verdict: Outfit.score(assembled, statement: statement.statement).reason
        )
        // The same table the preview above was drawn from, so what is saved is what was
        // agreed to — see `FitArrangement`.
        fit.placements = FitArrangement.placements(for: arranged)
        fit.backgroundName = background.rawValue
        context.insert(fit)
        try? context.save()

        // The render is written after the fact and only when every piece actually decoded —
        // `ImageRenderer` draws one frame synchronously, so an unwarmed canvas comes out as a
        // stack of empty rectangles and that file would be what the fit looked like for as
        // long as it existed. Nothing waits on it.
        Task {
            guard await FitRender.warm(fit) else { return }
            fit.renderFile = await FitRender.write(fit)
            try? context.save()
        }

        if thenArrange {
            arranging = fit
        } else {
            dismiss()
        }
    }
}

/// The subject, drawn as whatever the app actually has of it.
///
/// A `BrandUpdate` goes through `FitPieceImage`, which is what every other surface uses. A
/// discovery card has no row and therefore no cutout file — but `DiscoveryAnalysis` lifts a
/// sticker in memory for the cards at the viewport, so where that ran the subject lands on the
/// canvas cut out, exactly like the wardrobe pieces beside it. Where it did not — the
/// photograph is still decoding, or this is the Simulator, where Vision's subject lifting does
/// not run at all — it degrades to the photograph, which is what `FitPieceImage` does too.
///
/// **The fallback is the packshot, not the lead shot**, for the same reason `FitPieceImage`
/// prefers `packshotURL`. A gallery's order is a merchandising decision: Stüssy leads with four
/// model shots, so falling back to the first frame drops a whole person in trousers and boots
/// into somebody's outfit as a stand-in for a t-shirt. `DiscoveryAnalysis` has already answered
/// which frame has nobody in it; this only has to use the answer. The *card* still shows the
/// lead — on a model is how the brand wants the garment seen.
private struct FitSubjectImage: View {
    let subject: FitSubject

    var body: some View {
        switch subject {
        case .product(let update):
            FitPieceImage(update: update)
        case .discovery(let card, let sticker, _, let packshot):
            if let sticker {
                Image(uiImage: sticker).resizable().scaledToFit()
            } else {
                UpdateImage(
                    url: packshot ?? card.imageURLs.first.flatMap(URL.init(string:)),
                    aspect: 1,
                    contentMode: .fit,
                    drawnWidth: FitPieceImage.drawnWidth,
                    backdrop: .clear,
                    mark: card.brand.name
                )
            }
        }
    }
}

/// One candidate, and why it is in the running.
///
/// The reason is the line `Pairing` actually used, never a restatement of the title — the
/// same contract `PairingTile` and `SuggestedBrandCard` hold, and for the same reason: a
/// suggestion nobody can account for is indistinguishable from a shuffle.
private struct OptionTile: View {
    let update: BrandUpdate
    let reason: String?
    let isChosen: Bool

    private static let side: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The cutout where there is one, exactly as the canvas draws it — these are the
            // pieces that will be on it, so a tile that looks different from the thing it
            // places is a small lie about what you are choosing.
            FitPieceImage(update: update)
                .frame(width: Self.side, height: Self.side)
                .background(Color.sweep)
                .overlay {
                    if isChosen {
                        Rectangle().stroke(Color.signal, lineWidth: 1.5)
                    }
                }

            Text(update.title)
                .font(.editorial(12))
                .foregroundStyle(isChosen ? Color.ink : Color.muted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: Self.side, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let reason {
                DataLabel(text: reason.uppercased(), size: 9)
                    .frame(width: Self.side, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}
