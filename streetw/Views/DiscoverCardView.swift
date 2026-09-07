// DiscoverCardView.swift
// One card, one screen, in one of three voices.
//
// The structure is the same whichever voice it speaks in, and that is what makes the feed
// scan: **who** at the top, **what** in the middle, **why** at the bottom. Only the
// contents change.
//
//     ┌──────────────────────────────────┐
//     │ [mark]  BRAND NAME       FOLLOW  │  who — always, and always here
//     │                                  │
//     │        photograph, or a          │  what — a garment, or a body of work
//     │        mosaic of the brand       │
//     │                                  │
//     │  ┌ [·] GOES WITH ──────┐         │  the anchor, on a pairing card only
//     │  └ YOUR KITH LAWSON TEE ┘        │
//     │ ──────────────────────────────── │
//     │ BRAND YOU MIGHT LIKE             │  why — the voice, said plainly
//     │ North Field                      │
//     │ Utility fabrics, garment-dyed…   │
//     │ 128 US$ · S M L XL               │
//     │ NOT FOR ME                  VIEW │
//     └──────────────────────────────────┘
//
// **A card is one continuous ground, light where the garment is and dark where the reading
// is.** It used to be two flat panels — a sweep for the photograph, `Color.paper` for the
// text — and the seam between them was the loudest line on the screen, on the one page in the
// app that is a picture first. A single gradient removes it: the photograph sits on studio
// sweep, the ground falls away underneath it, and the reading is set in paper on near-black.
//
// This reverses a note that stood here for a long time — *nothing is white-on-dark* — and the
// reversal is narrower than it looks. What that note was written against is a **scrim laid
// over a photograph**, and it was right: the earlier attempt put the text over the bottom
// third of every garment and cropped the picture to fill the frame. Neither is true here. The
// photograph is still `.fit`, still uncropped, and still finishes **above** the dark; the
// gradient is the card's own ground rather than something drawn on top of the artwork. The
// rest of the app is unchanged — this is the one screen that is a poster.
//
// Two things it still deliberately does *not* do.
//
// **The photograph is never cropped.** A feed like this wants to fill the frame edge to
// edge, and that works beautifully on the lookbook photography a mockup is drawn with. Real
// streetwear catalogues are packshots on a studio sweep, and filling a tall frame with a
// shoe photographed side-on cuts both ends off it.
//
// **The garment never reaches the dark.** Most catalogue photography is a JPEG with a white
// sweep baked into its pixels, so a picture drawn over the falling ground would show as a
// bright rectangle sitting on grey — the "lightbox in a dark tile" `Color.sweep` exists to
// prevent. The pager is inset above the fade for exactly that reason, and that inset is why
// the picture is smaller here than in a mockup drawn with cut-out illustrations.

import StreetwCore
import SwiftUI

struct DiscoverCardView: View {
    @Environment(DiscoveryAnalysis.self) private var analysis: DiscoveryAnalysis

    let entry: DeckCard
    /// The wardrobe, keyed by `pairingID`, so a `Garment` the ranking chose can be drawn.
    ///
    /// Built once by the feed rather than queried per card: a `@Query` here would put every
    /// card on screen on the `SavedItem` table, and three are realised at a time in a paging
    /// scroll.
    var wardrobe: [String: BrandUpdate] = [:]
    let onFollow: () async -> Void
    var onDismiss: () -> Void = {}
    var onSave: () -> Void = {}
    /// Opens the whole outfit this card's pairing is the start of. Only ever offered on a
    /// card that has an anchor to build one around.
    var onOpenFit: () -> Void = {}
    /// Opens the brand. Every card names one at the top, and until now that line was inert:
    /// the only thing you could do with a shop you had never heard of was follow it, which
    /// is the commitment rather than the way to look.
    var onOpenBrand: () -> Void = {}
    /// Opens the garment. What the photograph does, and what `VIEW` used to half-do by
    /// throwing you out to Safari — see `DiscoverProductSheet`.
    var onOpenProduct: () -> Void = {}
    /// Whether this garment is already in the collection, so the save control can say so
    /// rather than pretending every tap is the first.
    var isSaved = false
    /// Clears this garment out of the feed's unread queue. Only ever offered on a card from a
    /// brand they follow, because only those have a row in the store to clear — see
    /// `FollowedSupply` and `actions`.
    var onMarkRead: () -> Void = {}

    @State private var isFollowing = false
    /// Whether the reader has cleared this one. Held here rather than read back off the row,
    /// because the card deliberately holds no row — and the deck keeps a card that has been
    /// scrolled past exactly where it was, so the control has to be able to say it is spent.
    @State private var markedRead = false
    /// The brief mark a double-tap leaves. Purely feedback — the save is already done and
    /// confirmed by the toast — but a gesture with no visible response reads as a miss.
    @State private var savedFlash = false

    private var card: DiscoverCard { entry.card }

    /// How much room the confirmation toast has to leave at the foot of this screen.
    ///
    /// The same obligation `ProductDetailView` has with its buy bar: the toast is anchored
    /// above the tab bar, which is right everywhere except the screens that put a control
    /// there.
    static let actionsHeight: CGFloat = 56

    /// How much of the top of a card is chrome: the screen's own filter bar, and then this
    /// card's brand line under it.
    ///
    /// Published so the artwork can start *below* it. A contact sheet drawn from the very top
    /// spends its first whole row behind an opaque header — which is not a layout anybody
    /// chose, it is a row of photographs nobody can see.
    static let chromeTop: CGFloat = 134

    /// How far the artwork stays clear of the foot of the hero, where the ground is turning
    /// dark. See the header: a white-backed JPEG drawn over the fade is a lightbox on grey.
    ///
    /// **Retuned down from 104.** Together with the band below, the two put roughly a third
    /// of the card between the bottom of the garment and the first line of the reading — and
    /// because the fade is deliberately imperceptible for its first half, what that space
    /// reads as is not a fade but a hole. The clearance still has to exist and still has to
    /// be measured in points rather than in a fraction of the hero, so this is a smaller
    /// number rather than a different idea.
    static let chromeBottom: CGFloat = 84

    /// How tall the fade itself is. **Longer than the inset above, on purpose.** A ramp that
    /// darkens over the same distance the artwork is held clear of reads as a hard edge with
    /// a blur on it; a long fall that is still almost nothing where the artwork ends reads as
    /// light leaving the room. The curve carries that — see `fade`.
    ///
    /// Shortened with `chromeBottom` and by the same proportion, so the artwork's bottom edge
    /// still lands just under halfway down the band — where the gradient is at three
    /// hundredths and a white packshot has nothing to pick up.
    private static let fadeHeight: CGFloat = 156

    /// The card's ground, top and bottom. **Fixed in both appearances**, like the collection
    /// wall and for the same reason: what a photograph sits on cannot invert when the
    /// photograph does not. The top is the studio sweep every packshot is already shot on, so
    /// a white-background JPEG has nothing to sit against; the bottom is the app's ink, which
    /// is what the reading is set against everywhere else, only inverted.
    static let groundTop = Color.sweep
    static let groundBottom = Color(uiColor: UIColor(red: 0.055, green: 0.055, blue: 0.047, alpha: 1))
    /// Type set on the dark half.
    static let groundInk = Color(uiColor: UIColor(red: 0.961, green: 0.961, blue: 0.941, alpha: 1))

    // MARK: - What there is to draw

    /// The garment's photographs, promotional rows already refused on both ends.
    private var images: [URL] {
        BrandPreview.images(from: card.imageURLs, limit: 8)
    }

    /// The garments in a release — the only photographs it has, since a collection row
    /// carries none of its own.
    private var members: [URL] {
        BrandPreview.images(from: card.members, limit: 12)
    }

    /// The brand's range. Its lead shot is dropped where that shot is already the hero:
    /// repeating the photograph directly above wastes the row that exists to show breadth.
    ///
    /// **As many as the wire carries, which is now eighteen.** Six was the number a nine-tile
    /// grid cut down to when it insisted on whole rows, and six garments is not a brand — it
    /// is a shelf. The one question a card headlined with a wordmark has to answer is *what
    /// does this label make*, and it was being answered with less than a page of a catalogue
    /// holding hundreds.
    private var spread: [URL] {
        let lead = entry.presentation == .brand ? nil : card.imageURLs.first
        return BrandPreview.images(from: card.spread.filter { $0 != lead }, limit: 18)
    }

    /// The wardrobe piece this card was matched against.
    ///
    /// One, not three. The old row showed the garment plus two of yours and read as a
    /// shopping basket; what makes the sentence land is naming **the** thing it goes with,
    /// which is also all the sentence itself claims.
    private var anchor: BrandUpdate? {
        guard !entry.isExploration, entry.presentation == .pairing else { return nil }
        return entry.pairs.first.flatMap { wardrobe[$0.id] }
    }

    // MARK: - Body

    /// **One ground, falling from sweep to ink**, rather than two flat panels with a seam
    /// between them. See the file header for what that reverses and why the reversal is
    /// narrower than it sounds.
    ///
    /// The gradient lives on the hero rather than on the whole card, so the point at which
    /// the ground turns is measured from the *bottom of the artwork* — which is where it has
    /// to be, because the reading's height varies with the title and a fraction of the whole
    /// card would put the turn in a different place on every product.
    var body: some View {
        VStack(spacing: 0) {
            hero
            reading
        }
        .background(Self.groundBottom)
        // Measured only when it is actually being looked at: a fetch, a decode and two
        // Vision requests per card, on a screen built to be scrolled past.
        .task(id: card.productExternalID) { await analysis.analyse(card) }
        // **`@State` belongs to the position, not to the card.** A card here is a view
        // *description* in a `LazyVStack`, and SwiftUI keeps the instance and its state when
        // the description at that position changes — which is exactly what a re-rank does. So
        // a spent "MARKED READ" would be inherited by whatever garment arrived next and its
        // control would sit there disabled about something nobody had touched. Same fact
        // `ImageGallery.localIndex` resets on, met on a different card.
        .onChange(of: card.productExternalID) { markedRead = false }
        .contentShape(.rect)
        // The discoverable version of a gesture this deliberately does not have — see
        // `DiscoverFeedView` for why refusing is a button and never a flick.
        // Suppressed on a followed brand for the same reason the button is — see `actions`.
        // A long press that offers to permanently refuse a shop sitting in somebody's own
        // brand rail is worse than the button, because it is the one nobody meant to press.
        .contextMenu {
            if !entry.isFollowed {
                Button("Not for me", systemImage: "hand.thumbsdown") { onDismiss() }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            switch entry.presentation {
            case .release, .brand:
                // Both of these are cards about a body of work rather than one garment, so
                // both are drawn as a wall of it. The difference is what the wall *is*: a
                // release shows its own contents, a brand shows its range.
                //
                // **A transparent layer carrying the save gesture is safe here** and only
                // here: a grid has no gesture of its own to lose.
                DiscoverMosaic(
                    urls: entry.presentation == .release ? members : spread,
                    mark: card.brand.name,
                    topInset: Self.chromeTop,
                    bottomInset: Self.chromeBottom
                )
                .overlay {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { flashSave() }
                        // A wall of a label's work is about the label, so that is where a
                        // tap on it goes.
                        .onTapGesture { onOpenBrand() }
                }
            case .pairing:
                // **The double tap is handed to the pager rather than laid over it, and that
                // is the whole of why the photographs could not be swiped.**
                //
                // A `Color.clear` with a `contentShape` and a tap gesture on top of a paging
                // `TabView` is not a passive layer: it becomes the hit-test result for every
                // touch in the frame, so the page controller's own pan recogniser was never
                // reached. A `TapGesture` cannot recognise a drag, so nothing happened at
                // all — the swipe was swallowed rather than lost to a competing gesture,
                // which is why it looked like the pager was simply broken. The rules under
                // the photograph still counted five pictures with no way to reach four of
                // them.
                //
                // Inside a page the two do not compete: a scroll view's pan delays taps and
                // wins a drag on its own, which is the arrangement every photo viewer uses.
                DiscoverPhotos(
                    urls: images,
                    mark: card.brand.name,
                    // **The garment starts below the brand line rather than behind it.**
                    // Letterboxing centres the photograph in the whole hero, so on anything
                    // close to the frame's own proportions its top edge arrived under the
                    // wordmark — a head cropped by a caption, which reads as the picture
                    // being cut off. Inset, it is always wholly in the clear, and the
                    // mosaic has done this since it was built.
                    topInset: Self.chromeTop,
                    bottomInset: Self.chromeBottom,
                    onDoubleTap: flashSave,
                    onTap: onOpenProduct
                )
            }

            identity

            if savedFlash {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Color.sweepInk.opacity(0.8))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **The fade is a band of fixed height at the foot, not a fraction of the hero**, and
        // that is the only way it can line up with the artwork. The artwork is inset by
        // `chromeBottom`; a proportional gradient turns at a point that moves with the hero's
        // height, so on a mosaic — which fills its region rather than letterboxing inside it —
        // the bottom two rows of photographs ended up sitting on grey, each with its own white
        // packshot backdrop. Anchored to the bottom at exactly the inset, the ground is flat
        // sweep everywhere there is a picture and starts falling the moment there is not.
        .background(alignment: .bottom) {
            Self.groundTop.overlay(alignment: .bottom) { Self.fade }
        }
        .clipped()
        // **The app's own save control, in the app's own place for it.** `SaveAction` is a
        // bookmark in a paper circle on the corner of the photograph, on the feed cards and
        // on the product page alike; a bordered square down among the text was this screen
        // inventing a second vocabulary for the commonest action in the app. It cannot *be*
        // `SaveAction` — that one takes a `BrandUpdate` and a discovery card has no row —
        // so it matches it exactly instead, vermilion once kept, and the two must stay in
        // step.
        .overlay(alignment: .topTrailing) {
            if entry.presentation == .pairing {
                Button(action: flashSave) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSaved ? Color.signal : Color.sweepInk)
                        .frame(width: 34, height: 34)
                        // `SaveAction` uses `Color.paper` because it sits on adaptive
                        // ground. This one sits on the card's own fixed sweep, so it is a
                        // tint of the ink instead — a chip you can see over a photograph
                        // without introducing a third colour to the screen.
                        .background(Color.sweepInk.opacity(0.08), in: Circle())
                }
                .buttonStyle(.borderless)
                .sensoryFeedback(.selection, trigger: isSaved)
                .accessibilityLabel("Save")
                .padding(.trailing, 16)
                .padding(.top, 100)
            }
        }
    }

    /// The ground leaving the room.
    ///
    /// Eased rather than linear, and taller than the artwork's inset. The first two thirds of
    /// the band are almost clear, so the picture can end well inside it without picking up a
    /// tint, and almost all of the darkening happens in the last third — which is where the
    /// reading is about to begin anyway. A straight ramp over the inset alone gave a visible
    /// grey wedge under every garment.
    private static var fade: some View {
        LinearGradient(
            stops: [
                .init(color: groundBottom.opacity(0), location: 0),
                .init(color: groundBottom.opacity(0.03), location: 0.45),
                .init(color: groundBottom.opacity(0.45), location: 0.76),
                .init(color: groundBottom, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: fadeHeight)
    }

    // MARK: - Who

    /// The brand, at the top of every card whatever it is about — **and nothing else.**
    ///
    /// It used to carry a 32pt monogram, the wordmark and a filled black FOLLOW slab, with the
    /// pairing chip under it: a hundred and eighty points of furniture laid over the top fifth
    /// of the photograph. On a packshot that sits on empty sweep and costs nothing, which is
    /// why it survived; on a full-bleed model shot the wordmark was across somebody's forehead
    /// and the slab across their shoulder. A tab whose cards are photographs cannot spend its
    /// best screens covering them.
    ///
    /// So what is left here is the *caption* — who made this — set small over a short fade, and
    /// every control has moved into the reading, which is flat sweep with room in it. Follow is
    /// not demoted by the move: it leads the action row and is the only filled thing on the
    /// card, which is more prominence than it had competing with a photograph.
    /// **And it is a way in.** A card headlined with a wordmark, on the one tab whose whole
    /// job is introducing shops, had nothing behind that wordmark: the only thing you could
    /// do about a brand you had never heard of was Follow it, which is the decision rather
    /// than the way to make it. `BrandPreviewSheet` exists precisely to answer "should I
    /// follow this" and was reachable from the recommendation block and nowhere else.
    ///
    /// The chevron is the smallest mark that says a line is a control; a filled button here
    /// would be the furniture this row was stripped of in the first place.
    private var identity: some View {
        Button(action: onOpenBrand) {
            HStack(spacing: 9) {
                BrandMonogram(
                    name: card.brand.name,
                    logoURL: card.brand.logoURL.flatMap(URL.init(string:)),
                    size: 24
                )
                Wordmark(name: card.brand.name, size: 12, color: .sweepInk)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.sweepInk.opacity(0.45))
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        // Clears the status bar *and* the feed's filter bar by hand: the feed ignores safe
        // areas so a card and a page are exactly one screen, which leaves every overlay to
        // inset itself.
        .padding(.top, 104)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        // No scrim any more. The card's ground is already flat sweep this far up — that is
        // what the gradient's first stop is for — so the wordmark has something to sit on
        // without a second layer being drawn to give it one. The mosaic is the exception and
        // insets itself instead; see `chromeTop`.
    }

    /// "Goes with your Kith Mesh Donovan Jersey" — **and it opens the outfit.**
    ///
    /// Two changes from the chip this replaces, and they are the same change twice.
    ///
    /// It has come **off the photograph**. A line of text claiming a match is a claim and the
    /// same line with your own jacket beside it is checkable at a glance — that argument was
    /// right and it did not require the panel to be laid over the picture. Down here it sits
    /// on flat sweep next to the headline it belongs with, and the garment is uncovered.
    ///
    /// And it is now a **way in** rather than a caption. The card says this piece goes with
    /// something you own; the next question is always *what would the whole thing look like*,
    /// and until now the answer was nowhere — `FitStudio` existed only behind a product page
    /// two taps away, on a garment from a brand you would have had to follow first. This is
    /// the shortest honest route to it: the chip that makes the claim opens the fit that
    /// demonstrates it.
    ///
    /// It replaces the context label rather than sitting under it, because "GOES WITH WHAT YOU
    /// OWN" above "Goes with your Kith Mesh Donovan Jersey" is the same sentence twice; the
    /// reason the ranking actually used is carried on the small line instead.
    private func anchorRow(_ item: BrandUpdate) -> some View {
        Button(action: onOpenFit) {
            HStack(spacing: 10) {
                // **On its own light ground, and bigger than it was.** A cutout is a garment
                // with everything else erased, so at 32pt on a near-black row a black jacket
                // was a caption with nothing above it — the same fact `Color.sweep` is
                // written down for, met on a new surface. It is a photograph, so it gets the
                // ground photographs get, fixed in both appearances like the wall.
                DiscoverSticker(
                    image: LocalImage.load(item.cutoutURL),
                    fallback: FitPieceImage.source(for: item),
                    mark: item.brandLabel ?? item.title,
                    side: 42
                )
                .padding(3)
                .background(Color.sweep)
                VStack(alignment: .leading, spacing: 2) {
                    DataLabel(text: contextLabel, size: 9, color: .signal)
                        .lineLimit(1)
                    Text("Goes with your \(item.title)")
                        .font(.editorial(13))
                        .foregroundStyle(Self.groundInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    DataLabel(text: "SEE THE FIT", size: 9, color: Self.groundInk.opacity(0.6))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Self.groundInk.opacity(0.6))
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            // A lifted panel rather than a bordered box: it sits astride the turn in the
            // ground, where a hard rectangle would read as a join in the gradient. Rounded
            // and translucent, so what is behind it still shows through and it belongs to
            // the picture rather than to the text block.
            .background(Self.groundInk.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Self.groundInk.opacity(0.16), lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Why

    private var reading: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No rule. The ground turning from sweep to ink is the division, and a hairline
            // drawn across a gradient is a second answer to a question already answered.

            // The voice, said plainly rather than left to be inferred from the layout. On a
            // pairing card the anchor row says it *and* shows the garment it is about, which
            // is the same statement with the evidence attached — so the plain label is for
            // the two voices that have no anchor to show.
            // **Where it came from, on the one kind of card that needs saying.** Everything
            // else in this tab is by construction a brand nobody here follows, so provenance
            // is the tab itself and printing it would be noise. A garment from a shop they
            // already follow is the exception — without this line it is indistinguishable
            // from an introduction to a label they have had for months, which reads as the
            // feed having lost track of what they follow.
            //
            // It sits *above* the anchor row rather than replacing it: the pairing is the
            // argument and the chip is the way into the fit, and neither is worth giving up
            // to say where the garment came from.
            if entry.isFollowed {
                DataLabel(
                    text: "NEW FROM \(card.brand.name.uppercased())",
                    size: 10,
                    color: Self.groundInk.opacity(0.55)
                )
                .padding(.bottom, anchor == nil ? 7 : 9)
            }

            if let anchor {
                anchorRow(anchor).padding(.bottom, 13)
            } else if !entry.isFollowed {
                DataLabel(text: contextLabel, size: 10, color: Self.groundInk.opacity(0.55))
                    .padding(.bottom, 7)
            }

            // **The title is a way in too.** On a pairing card the headline names a garment,
            // and a name that opens the thing it names is how every other list in this app
            // behaves. On the other two the headline is the *brand*, so it opens that
            // instead — the destination follows the subject rather than the position.
            Button(action: entry.presentation == .pairing ? onOpenProduct : onOpenBrand) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline)
                        .font(.editorial(entry.presentation == .pairing ? 21 : 25))
                        .foregroundStyle(Self.groundInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subline {
                        Text(subline)
                            .font(.editorial(14))
                            .foregroundStyle(Self.groundInk.opacity(0.62))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)

            if !metaTokens.isEmpty {
                metaRow.padding(.top, 12)
            }

            actions.padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        // Clears the floating tab bar. Without enough of it the controls are unreachable —
        // see the note on the feed's safe-area handling.
        .padding(.bottom, 96)
    }

    /// What kind of card this is, in the app's own words.
    private var contextLabel: String {
        switch entry.presentation {
        case .release:
            let count = card.memberCount
            return count > 0 ? "NEW COLLECTION · \(count) PIECES" : "NEW COLLECTION"
        case .pairing:
            // The verdict's own sentence where there is one — `Pairing` returns none until a
            // photograph has been read, and inventing one would be a claim we cannot back.
            return (entry.reason ?? "Goes with what you own").uppercased()
        case .brand:
            return entry.isExploration ? "NEW TO YOU" : "BRAND YOU MIGHT LIKE"
        }
    }

    /// A release and a brand card are *about* the label, so the label is the headline. Only a
    /// pairing is about a particular garment.
    private var headline: String {
        switch entry.presentation {
        case .release: return card.title
        case .pairing: return card.title
        case .brand: return card.brand.name
        }
    }

    /// One line of prose, and every version of it is either the storefront's own words or a
    /// statement of measured fact. Nothing here is written *about* a brand by this app.
    private var subline: String? {
        switch entry.presentation {
        case .release:
            // A season's page usually says what the season is, and it is the only sentence in
            // this whole system a human actually wrote.
            return card.summary?.condensed
        case .pairing:
            return card.summary?.condensed ?? makesLine
        case .brand:
            // **Only the reading of the catalogue, never the product blurb.** The headline
            // here is the *brand*, and `summary` is the storefront's description of the one
            // garment that happened to carry the card — so the fallback printed "The NY
            // Yankees Fire Curve Logo Tee features oversized lettering…" directly under
            // "Billionaire Boys Club", describing a company with a sentence about a t-shirt.
            // Exactly the same mistake the price and the size run were making on this card,
            // and the same fix: a line that describes a garment belongs only on the card
            // that is about one. Nothing is the honest answer when a brand has not been
            // vectorised yet — the mosaic above is already saying what the label makes.
            return makesLine
        }
    }

    /// What the catalogue is mostly made of, and where it sits on price. The same reading
    /// `BrandPreviewSheet` prints off the same vector, so two screens cannot disagree about
    /// one shop.
    private var makesLine: String? {
        guard let vector = card.vector else { return nil }
        let named = vector.categories
            .filter { $0.key != GarmentSlot.unknown.rawValue && $0.value >= 0.12 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { GarmentSlot(rawValue: $0.key)?.label.lowercased() }
        guard !named.isEmpty else { return nil }

        var line = named.joined(separator: ", ")
        if let band = priceBand { line += " · \(band)" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Words rather than an amount, because `pricePercentile` is a *rank*: brands store their
    /// own currency and there are no exchange rates anywhere in this system.
    private var priceBand: String? {
        switch card.vector?.pricePercentile {
        case .some(..<0.25): return "among the cheaper here"
        case .some(..<0.5): return "below the middle"
        case .some(..<0.75): return "above the middle"
        case .some: return "among the dearest here"
        case nil: return nil
        }
    }

    /// **A price and a size run describe a garment, so only a garment card carries them.**
    /// They were on all three, which put "44 US$" and a vermilion L under a card whose
    /// headline was *Gymshark US* — pricing a company at the cost of whichever product
    /// happened to carry the card. A brand card names where to find it instead.
    private var metaTokens: [String] {
        switch entry.presentation {
        case .pairing:
            return card.priceText.map { [$0] } ?? []
        case .brand:
            return card.brand.website
                .flatMap { URL(string: $0)?.host() }
                .map { [$0.replacingOccurrences(of: "www.", with: "")] } ?? []
        case .release:
            return []
        }
    }

    /// **No size run.** It was here because every other product surface has one, and this is
    /// not one of those surfaces: a discovery card is an argument for a *brand*, made in a
    /// scroll nobody is shopping in yet. Six tokens of a size ladder — most of them for a
    /// garment somebody has not decided they want, from a shop they have not decided to
    /// follow — is the most detailed thing on a card whose point is the photograph, and it
    /// spent the app's one accent colour saying "in your size" about something two taps away
    /// from anywhere you could buy it. The size run belongs on the product page, which is
    /// where VIEW goes and where it already is.
    private var metaRow: some View {
        HStack(spacing: 9) {
            ForEach(Array(metaTokens.enumerated()), id: \.offset) { index, token in
                if index > 0 {
                    Circle()
                        .fill(Self.groundInk.opacity(0.35))
                        .frame(width: 3, height: 3)
                }
                Text(token)
                    .font(.data(13, .semibold))
                    .foregroundStyle(Self.groundInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Everything you can do with the card, in one row on the reading's flat ground.
    ///
    /// Follow leads it. It used to sit at the top-right, over the photograph, on the argument
    /// that the action a card is *for* belongs beside the brand it applies to — which was
    /// right about the ranking and wrong about the ground: a filled black slab is the heaviest
    /// object in the app and it was being laid across somebody's shoulder. Here it is still
    /// the only filled control on the card and it is first in reading order, which is more
    /// prominence than it had while competing with a picture.
    ///
    /// **Save is not here.** It was, briefly, as a bordered square beside Follow — which is a
    /// vocabulary this screen invented for the commonest action in the app. `SaveAction` has
    /// always been a bookmark in a paper circle on the corner of the photograph, on the feed
    /// cards and on the product page alike, so that is where it is now; see `hero`.
    private var actions: some View {
        HStack(spacing: 10) {
            // **A brand they follow is offered neither of the two verdicts**, because both
            // have already been given. Follow would be a control that either does nothing or
            // quietly re-does what is already true, and "not for me" writes a `BrandDismissal`
            // — a permanent refusal that also demotes every label resembling it — about a shop
            // sitting in their own brand rail. Offering a decision somebody has already made
            // is the app failing to remember them.
            //
            // What replaces them is the one thing a card from a followed brand can do that a
            // stranger's cannot: clear it. These garments are unread rows in the feed, so
            // reading one here should read it there — otherwise the tab is a second copy of a
            // queue you then have to empty twice. It never removes the card (see
            // `DiscoverDeck.adopt`) — the list must not shorten under the thumb that tapped —
            // so the control says it is spent instead.
            if entry.isFollowed {
                Button {
                    markedRead = true
                    onMarkRead()
                } label: {
                    DataLabel(
                        text: markedRead ? "MARKED READ" : "MARK READ",
                        size: 11,
                        color: Self.groundInk.opacity(markedRead ? 0.3 : 0.55)
                    )
                    .frame(height: 34)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(markedRead)
                .sensoryFeedback(.success, trigger: markedRead)

                Spacer(minLength: 8)
                // Nothing else. The garment is reached from the photograph and the title, and
                // the save is the bookmark on the picture — the same two routes every other
                // card here has.
            } else {
            // Light on dark, and a capsule. The filled black slab this used to be is
            // invisible on the ground it now sits on, and the shape follows: a pill is what
            // a single affirmative control looks like when it is the only one on a dark
            // field. `FollowButton` carries the variant so the two screens that draw it
            // still cannot disagree about what it does.
            FollowButton(isWorking: $isFollowing, action: onFollow, width: 96, onDark: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                DataLabel(text: "NOT FOR ME", size: 11, color: Self.groundInk.opacity(0.55))
                    .frame(height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)

            // **`VIEW` is gone.** It was an underlined word in the corner that left the app
            // for Safari — the *last* step of a decision offered as the only one, on a card
            // that had deliberately been stripped of the size run and everything else
            // somebody would want before taking that step. Worse, it made the photograph
            // above it inert: the one gesture everybody tries on a full-screen picture did
            // nothing, while a small word did the drastic thing.
            //
            // The garment has a page now (`DiscoverProductSheet`) and the photograph, the
            // title and the save all lead to it; the storefront link is pinned at the foot
            // of that page, where every other product page in this app keeps it.
            }
        }
    }

    private func flashSave() {
        onSave()
        withAnimation(.easeOut(duration: 0.18)) { savedFlash = true }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeIn(duration: 0.25)) { savedFlash = false }
        }
    }
}

private extension String {
    /// A storefront description as one readable line.
    ///
    /// These arrive as `body_html` — tags, entities and newlines — and a card has room for a
    /// sentence. Nil rather than empty when there is nothing left, so the caller prints one
    /// less line instead of an empty one.
    ///
    /// **Two faults, and they were both visible on the same screen.** This stripped tags to
    /// spaces with a private regex of its own, so a spec list came out as one unpunctuated
    /// run — *"Oversized, boxy fit crewneck fleece sweatshirt Sun faded effect Heavyweight
    /// 14.75oz cotton blend Stüssy l…"* — and then SwiftUI's `.lineLimit(2)` cut it wherever
    /// the second line happened to end, which is mid-word. On the app's most designed surface
    /// the only prose was unedited HTML, clipped at a letter.
    ///
    /// So: `ShopifySource.plainText`, which is the app's one answer to "HTML into a line" and
    /// already knows that `</li>` and a line-broken capital are boundaries — a second
    /// implementation of the same job is how the two drift. Then a cap of our own, ended on a
    /// **word**, because a truncation the layout performs cannot be told where to stop.
    var condensed: String? {
        let text = ShopifySource.plainText(from: self)
        guard !text.isEmpty else { return nil }
        return text.truncated(to: 150)
    }

    /// Cut to at most `limit` characters, on the last word boundary before it.
    ///
    /// Returns the string unchanged when it already fits, and falls back to a hard cut for a
    /// single word longer than the limit — which is a URL or a hash rather than prose, and
    /// there is no better place to break one.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        let clipped = prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > limit / 2
        else { return clipped.trimmingCharacters(in: .whitespaces) + "…" }
        return clipped[..<lastSpace]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ·,;:"))
            + "…"
    }
}

/// A wall of a brand's work — a release's contents, or a label's range.
///
/// **A collection row carries no photograph**, and a brand is not one garment either, so both
/// of these cards are drawn out of many. A mosaic rather than a strip because both are about
/// plurality: a row of three suggests three things where there are sixty, and the count in
/// the caption says the real number.
/// **It fills the frame, and that is the whole redesign.**
///
/// It used to be a square nine-up grid centred with a `Spacer` above and below, cut down to
/// whole rows — which on eight photographs is six tiles, floated in the middle of a
/// full-screen card with a band of empty sweep over them and another under. Two separate
/// things were wrong with that and they compounded: the card looked unfinished, and six
/// garments is not enough of a catalogue to answer the only question it is asking.
///
/// So the tiles are sized to the space rather than the space being left over from the tiles:
/// three across, as many whole rows as fit, each tile as tall as the row it is in. Fifteen
/// garments edge to edge reads as a body of work; six squares floating in cream reads as a
/// page that failed to load.
private struct DiscoverMosaic: View {
    let urls: [URL]
    let mark: String
    /// Where the card's own chrome ends. The grid starts below it, so no row is spent behind
    /// the header — see `DiscoverCardView.chromeTop`.
    var topInset: CGFloat = 0
    /// Where the ground starts turning dark. See `DiscoverCardView.chromeBottom`.
    var bottomInset: CGFloat = 0

    /// Three across. Two reads as a comparison and four is a contact sheet; at three a
    /// garment is still large enough to want.
    private static let columns = 3
    private static let gutter: CGFloat = 2
    /// Past this the tiles stop being garments and start being swatches. Six rows of three
    /// is eighteen, which is what the wire carries.
    private static let maxRows = 6

    var body: some View {
        if urls.isEmpty {
            Wordmark(name: mark, size: 15, color: .sweepInk.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                // Whole rows only, still: a half-filled last row leaves a hole in the corner
                // that reads as a tile stuck loading rather than as the end of the wall. On
                // fewer than three photographs the row narrows instead, which is the one
                // case where a partial grid is the honest shape.
                let columns = urls.count < Self.columns ? max(1, urls.count) : Self.columns
                let rows = max(1, min(urls.count / columns, Self.maxRows))
                let shown = Array(urls.prefix(rows * columns))
                let gutters = Self.gutter * CGFloat(columns - 1)
                let tileWidth = (geometry.size.width - gutters) / CGFloat(columns)
                let tileHeight =
                    (geometry.size.height - Self.gutter * CGFloat(rows - 1)) / CGFloat(rows)

                VStack(spacing: Self.gutter) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: Self.gutter) {
                            ForEach(0..<columns, id: \.self) { column in
                                UpdateImage(
                                    url: shown[row * columns + column],
                                    aspect: 1,
                                    // `.fill` here, unlike a single garment. A mosaic's job
                                    // is the rhythm of the grid — tiles each letterboxing to
                                    // a different shape reads as a broken layout rather than
                                    // as a collection. The garment is shown whole on its own
                                    // card.
                                    contentMode: .fill,
                                    drawnWidth: 400,
                                    backdrop: .sweep,
                                    mark: mark
                                )
                                .frame(width: tileWidth, height: tileHeight)
                                .clipped()
                            }
                        }
                    }
                }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
    }
}

/// A full-bleed pager over one garment's photographs.
///
/// **Not `ImageGallery`.** That component is hardcoded to `aspect: 1, contentMode: .fit` — a
/// square on a wash — which is right for a feed card sitting in a column of other notices,
/// and wrong for a card that *is* the screen. Adding an aspect and a content mode there would
/// have reached five other callers to serve one.
///
/// What is carried over are the two behaviours that were bugs there first: the index resets
/// on `urls` (a card in a lazy stack is a view *description*, so a stale index opened the next
/// garment on its seventh frame, or on no frame at all), and neighbours are warmed (a
/// `TabView` builds a page only when reached, so every swipe arrived on an empty frame).
private struct DiscoverPhotos: View {
    let urls: [URL]
    let mark: String
    /// Where the card's own chrome ends, so the garment starts below the brand line rather
    /// than behind it. See the call site.
    var topInset: CGFloat = 0
    /// Where the card's ground starts turning dark. The garment stops above it — a JPEG's
    /// baked-in white sweep drawn over the fade is a lightbox on grey.
    var bottomInset: CGFloat = 0
    /// The save gesture, taken here rather than on a layer above.
    ///
    /// It has to be inside the pager. A transparent view over a `TabView` is the hit-test
    /// result for the whole frame, so the page controller's pan never sees the touch and the
    /// photographs cannot be swiped at all — which is a far worse loss than a double tap
    /// would have been. A tap attached to the page's own content competes with nothing: a
    /// scroll view delays taps and claims drags by itself.
    var onDoubleTap: () -> Void = {}
    /// A single tap opens the garment, which is what a photograph does everywhere else in
    /// the app. Attached *after* the double tap on the same view, which is the order that
    /// makes SwiftUI wait for the second tap before firing this one.
    var onTap: () -> Void = {}

    @State private var index = 0

    /// Not the original: Palace ships 3200² PNGs, which decode to a 41MB bitmap, and
    /// `ImageRendition` snaps to a ladder so nearby widths share one cache entry.
    private static let drawnWidth = 1200

    private var neighbours: [URL] {
        [index + 1, index + 2, index - 1]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
    }

    private var clamped: Binding<Int> {
        // Clamped on the way out: `onChange` resets a reused pager, but it runs *after* the
        // body that first sees the new photographs.
        Binding(
            get: { min(max(index, 0), max(urls.count - 1, 0)) },
            set: { index = $0 }
        )
    }

    /// What `scrollPosition` writes into. Optional because a scroll view reports nil while it
    /// is between two pages — which is precisely the state this pager could previously be
    /// left in, and now only passes through.
    private var position: Binding<Int?> {
        Binding(
            get: { clamped.wrappedValue },
            set: { if let value = $0 { index = value } }
        )
    }

    var body: some View {
        Group {
            if urls.isEmpty {
                Wordmark(name: mark, size: 15, color: .sweepInk.opacity(0.4))
            } else if urls.count == 1 {
                photo(urls[0])
            } else {
                // **A paging `ScrollView`, not a `TabView`, and the difference is whether it
                // settles.**
                //
                // A page-styled `TabView` is a `UIPageViewController`, and its pan is a
                // different gesture system from the vertical paging scroll this card lives
                // inside. When the outer scroll claimed a drag that the pager had already
                // started, the pager was left part-way between two photographs and stayed
                // there — a card showing three quarters of one picture and a sliver of the
                // next, with nothing to tell you which one you were on.
                //
                // Two scroll views of the *same* kind compose properly: the axes are
                // separate, the inner one owns horizontal, and `.scrollTargetBehavior(.paging)`
                // guarantees it comes to rest on a page rather than wherever the finger left
                // it. It also builds pages on demand exactly as the `TabView` did, so the
                // warming below is still what stops a swipe arriving on an empty frame.
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                            photo(url)
                                .containerRelativeFrame(.horizontal)
                                .id(position)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: position)
                .task(id: clamped.wrappedValue) {
                    ImageLoader.shared.prefetch(neighbours, width: Self.drawnWidth)
                }
                // **A printed count, exactly as `ImageGallery` prints one.** This had a
                // segmented progress bar across the foot of the photograph, which is a
                // control the app uses nowhere else — and the gallery's own note already
                // settled the question the other way: a count "says how many there are,
                // which dots only imply, and it matches the mono metadata everywhere else".
                // A second vocabulary for paging, on the one screen that is nothing but
                // photographs, was the card arguing with the rest of the app.
                // The capsule is gone with the panel it was protecting the count from: the
                // artwork is inset above this corner now, so the count sits on flat sweep
                // and a chip behind it would be a shape drawn for no reason.
                .overlay(alignment: .bottomTrailing) {
                    DataLabel(
                        text: "\(clamped.wrappedValue + 1) / \(urls.count)",
                        size: 11,
                        color: .sweepInk.opacity(0.55)
                    )
                    .padding(.trailing, 18)
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .onChange(of: urls) { _, _ in index = 0 }
    }

    /// **`.fit`, not `.fill`, and this one is measured rather than taste.** Filling looks
    /// right on a model shot and destroys a packshot: Allbirds photographs its shoes wide and
    /// side-on, so filling a tall frame cropped both ends off the shoe while leaving a band of
    /// empty sweep above it. Fitting letterboxes instead, which is the same choice the
    /// collection wall makes — *the wall never crops*.
    private func photo(_ url: URL) -> some View {
        CachedImage(url: url, width: Self.drawnWidth) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.sweep
        } failure: {
            Wordmark(name: mark, size: 14, color: .sweepInk.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(perform: onTap)
    }
}

/// One garment, cut out where that was possible and honest where it wasn't.
///
/// The fallback is why this is a view rather than an `Image`. Subject lifting declines often
/// and for good reasons — a flat-lay has no single subject, a light garment on a light sweep
/// cannot be separated from it by construction, and **Vision does not run in the Simulator at
/// all**. A refused lift degrades to the photograph, which is what `FitPieceImage` already
/// does on the fit canvas; a missing photograph degrades to the wordmark, which is what
/// `UpdateImage.mark` does everywhere else. Each step says less; none says nothing.
private struct DiscoverSticker: View {
    let image: UIImage?
    let fallback: URL?
    let mark: String
    let side: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let fallback {
                CachedImage(url: fallback, width: Int(side * 3)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.clear
                } failure: {
                    Wordmark(name: mark, size: 8, color: .sweepInk.opacity(0.4))
                        .minimumScaleFactor(0.6)
                }
            } else {
                Wordmark(name: mark, size: 8, color: .sweepInk.opacity(0.4))
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: side, height: side)
    }
}
