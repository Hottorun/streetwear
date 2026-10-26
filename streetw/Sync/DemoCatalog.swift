// DemoCatalog.swift
// Dev affordance for App Store screenshots: `-demoCatalog http://127.0.0.1:8765` fills the
// store with fictional brands and garments whose photographs are served from that address.
//
// **Every name here is invented, on purpose.** App Review flags screenshots that show real
// third-party brands, and a set shot from live storefronts (the 1.0 set showed Kith, a
// Yankees licence and an adidas collaboration) is exactly that. The photographs are generated
// packshots of unbranded garments; they live in `AppStore/demo/catalog/` and are served by
// `AppStore/demo/shoot.sh`, which is also what launches the app with this flag.
//
// While the flag is set nothing polls: the sources below name storefronts that do not
// exist, and a sync would stamp every brand with a failure. See the guard in `SyncEngine`.
//
// **It holds every shape the feed draws**, because the Phase 1 feed is judged by what its
// cards look like: single products, a restock in the reader's size and one not, a markdown
// with its "was", a release of six pieces (`Alpine Capsule`, which absorbs its garments into
// one card), a brand-wide sale with a code, and a date written down for tomorrow so the line
// above the feed has something to say. Everything arrives as news when it was published, so
// `-feedLastVisitHours 5` puts the line through the middle of it.

import Foundation
import StreetwCore
import SwiftData

@MainActor
enum DemoCatalog {
    /// Where the photographs are served from, or nil when the flag is absent.
    static var imageBase: String? {
        guard let raw = UserDefaults.standard.string(forKey: "demoCatalog"), !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static var isActive: Bool { imageBase != nil }

    private struct Label {
        let name: String
        let host: String
        let blurb: String
    }

    private struct Piece {
        let brand: Int
        let file: String
        let title: String
        let type: String
        let price: Double
        let kind: UpdateKind
        let hoursAgo: Double
        /// Saved to the wardrobe, and therefore already read.
        var owned = false
        var sizes: [String] = ["S", "M", "L", "XL"]
        var soldOut: Set<String> = []
        var restocked: [String] = []
        var was: Double?
        var summary: String?
        var tags: [String] = []
    }

    private static let labels = [
        Label(name: "Halden Works", host: "haldenworks.shop", blurb: "Workwear in canvas and leather."),
        Label(name: "Velmar Studio", host: "velmarstudio.shop", blurb: "Quiet tailoring, heavy basics."),
        Label(name: "Ondo Club", host: "ondoclub.shop", blurb: "Skate-adjacent graphics."),
        Label(name: "Paper Moth", host: "papermoth.shop", blurb: "Hand-finished knitwear."),
        Label(name: "Rivet & Lowe", host: "rivetlowe.shop", blurb: "Selvedge denim."),
        Label(name: "Ashgrove", host: "ashgrove.shop", blurb: "Technical outerwear.")
    ]

    private static let shoes = ["8", "8.5", "9", "9.5", "10", "10.5", "11", "12"]
    private static let waists = ["28", "30", "32", "34", "36"]

    private static let pieces: [Piece] = [
        Piece(brand: 5, file: "ashgrove-shell", title: "Storm Shell Jacket — Ember", type: "Jacket",
              price: 285, kind: .product, hoursAgo: 2.5,
              summary: "Three-layer waterproof shell with taped seams and a helmet-compatible hood."),
        Piece(brand: 0, file: "halden-chore-jacket", title: "Canvas Chore Coat — Olive", type: "Jacket",
              price: 210, kind: .restock, hoursAgo: 1.2, sizes: ["S", "M", "L", "XL"],
              soldOut: ["S", "XL"], restocked: ["M", "L"],
              summary: "12oz cotton canvas, cord collar, three patch pockets."),
        Piece(brand: 2, file: "ondo-wave-hoodie", title: "Undertow Hoodie — Cobalt", type: "Hoodie",
              price: 135, kind: .product, hoursAgo: 0.4,
              summary: "Heavyweight fleece with a hand-drawn wave print across the back."),
        Piece(brand: 1, file: "velmar-pleated-trouser", title: "Double Pleat Trouser — Black", type: "Pants",
              price: 168, kind: .priceDrop, hoursAgo: 3.1, sizes: waists, soldOut: ["28"], was: 240,
              summary: "Wide-leg wool trouser with a deep double pleat."),
        Piece(brand: 2, file: "ondo-skate-shoe", title: "Kickflip Low — Forest Suede", type: "Shoes",
              price: 98, kind: .restock, hoursAgo: 4.6, sizes: shoes, soldOut: ["8", "12"],
              restocked: ["10", "10.5"], summary: "Suede low-top on a gum cupsole."),
        Piece(brand: 4, file: "rivet-trucker", title: "Type III Trucker — Bleach Wash", type: "Jacket",
              price: 195, kind: .product, hoursAgo: 6,
              summary: "Vintage-washed 13oz denim, cut boxy."),
        Piece(brand: 1, file: "velmar-overshirt", title: "Boiled Wool Overshirt — Ecru", type: "Shirt",
              price: 220, kind: .product, hoursAgo: 9,
              summary: "Dense boiled wool with horn buttons."),
        Piece(brand: 2, file: "ondo-ringer-tee", title: "Ringer Tee — Washed Red", type: "T-Shirt",
              price: 48, kind: .product, hoursAgo: 14, summary: "Garment-dyed jersey, contrast rib."),
        Piece(brand: 4, file: "rivet-western-shirt", title: "Western Shirt — Faded Black", type: "Shirt",
              price: 145, kind: .product, hoursAgo: 7, summary: "Overdyed 10oz denim with pearl snaps."),
        Piece(brand: 3, file: "papermoth-breton", title: "Breton Crew — Navy and Cream", type: "Sweater",
              price: 120, kind: .product, hoursAgo: 20, summary: "Hand-linked cotton knit."),

        // The rest of Ashgrove's Alpine Capsule, shelved in the same poll as the Storm Shell
        // above — a second apart, the way a storefront writes a drop.
        Piece(brand: 5, file: "ashgrove-fleece", title: "High-Pile Fleece Half-Zip — Heather", type: "Fleece",
              price: 165, kind: .product, hoursAgo: 2.5 + 1 / 3600, summary: "Deep-pile recycled fleece with a stand collar."),
        Piece(brand: 5, file: "ashgrove-trail-runner", title: "Ridge Trail Runner — Granite", type: "Shoes",
              price: 150, kind: .product, hoursAgo: 2.5 + 2 / 3600, sizes: shoes, summary: "Lugged trail shoe on a rock plate."),
        Piece(brand: 5, file: "ashgrove-sling", title: "Packable Sling Bag — Black", type: "Bag",
              price: 78, kind: .product, hoursAgo: 2.5 + 3 / 3600, sizes: ["One Size"]),
        Piece(brand: 5, file: "ashgrove-cap", title: "Nylon Five-Panel Cap — Mustard", type: "Hat",
              price: 45, kind: .product, hoursAgo: 2.5 + 4 / 3600, sizes: ["One Size"]),
        Piece(brand: 5, file: "ashgrove-beanie", title: "Ribbed Wool Beanie — Rust", type: "Hat",
              price: 38, kind: .product, hoursAgo: 2.5 + 5 / 3600, sizes: ["One Size"]),

        Piece(brand: 0, file: "halden-cargo-pant", title: "Ripstop Cargo Pant — Tan", type: "Pants",
              price: 150, kind: .product, hoursAgo: 60, owned: true, sizes: waists),
        Piece(brand: 1, file: "velmar-heavy-tee", title: "Heavy Boxy Tee — Off White", type: "T-Shirt",
              price: 65, kind: .product, hoursAgo: 72, owned: true),
        Piece(brand: 4, file: "rivet-raw-denim", title: "Straight Raw Selvedge — Indigo", type: "Jeans",
              price: 180, kind: .product, hoursAgo: 90, owned: true, sizes: waists),
        Piece(brand: 0, file: "halden-work-boot", title: "Lug Work Boot — Tobacco", type: "Boots",
              price: 260, kind: .product, hoursAgo: 110, owned: true, sizes: shoes),
        Piece(brand: 3, file: "papermoth-cardigan", title: "Mohair Cardigan — Cocoa", type: "Cardigan",
              price: 240, kind: .product, hoursAgo: 130, owned: true),
        Piece(brand: 1, file: "velmar-loafer", title: "Penny Loafer — Black Calf", type: "Shoes",
              price: 310, kind: .product, hoursAgo: 150, owned: true, sizes: shoes)
    ]

    /// Fills an empty store. Does nothing once any brand exists, so relaunching for the next
    /// screenshot keeps whatever was read or saved in between.
    static func seedIfRequested(in context: ModelContext) {
        guard let base = imageBase else { return }
        var any = FetchDescriptor<Brand>()
        any.fetchLimit = 1
        guard (try? context.fetch(any))?.isEmpty != false else { return }

        let now = Date()
        let brands = labels.map { label in
            let brand = Brand(name: label.name, websiteURL: URL(string: "https://\(label.host)"),
                              styleDescription: label.blurb)
            brand.currencyCode = "USD"
            brand.sources = [
                BrandSource(kind: .shopify, url: URL(string: "https://\(label.host)/products.json")!,
                            lastCheckedAt: now.addingTimeInterval(-300)),
                BrandSource(kind: .collections, url: URL(string: "https://\(label.host)/collections.json")!,
                            lastCheckedAt: now.addingTimeInterval(-300))
            ]
            brand.lastSyncedAt = now.addingTimeInterval(-300)
            context.insert(brand)
            return brand
        }

        var byFile: [String: BrandUpdate] = [:]
        for (index, piece) in pieces.enumerated() {
            let brand = brands[piece.brand]
            let host = labels[piece.brand].host
            let productID = "shopify:\(910_000 + index)"
            let published = now.addingTimeInterval(-piece.hoursAgo * 3600)
            let variants = piece.sizes.enumerated().map { offset, size in
                VariantInfo(id: "\(910_000 + index)-\(offset)", title: size,
                            available: !piece.soldOut.contains(size),
                            price: String(format: "%.2f", piece.price), size: size)
            }
            let handle = piece.file
            let update = BrandUpdate(
                externalID: piece.kind == .product ? productID : "\(piece.kind.rawValue):\(productID)",
                brand: brand,
                title: piece.title,
                summary: piece.summary,
                linkURL: URL(string: "https://\(host)/products/\(handle)"),
                imageURLStrings: ["\(base)/\(piece.file).jpg"],
                publishedAt: published,
                kind: piece.kind,
                priceText: "$\(Int(piece.price))",
                priceAmount: piece.price,
                isAvailable: true,
                tags: piece.tags,
                productType: piece.type,
                variants: variants
            )
            update.productExternalID = productID
            update.discoveredAt = published
            update.restockedSizes = piece.restocked
            if let was = piece.was {
                update.previousPriceText = "$\(Int(was))"
                update.previousPriceAmount = was
            }
            // News when it was published, read or not — the owned pieces have been seen, and
            // sit below the line with everything else that has.
            update.arrive(at: published)
            update.isSeen = piece.owned
            context.insert(update)
            if brand.lastActivityAt.map({ $0 < published }) ?? true { brand.lastActivityAt = published }
            byFile[piece.file] = update
            installCutout(named: piece.file, from: base, on: update)
        }

        // A release of six pieces: the Storm Shell and the five shelved beside it.
        let capsule = pieces.indices.filter { pieces[$0].brand == 5 }.map { "shopify:\(910_000 + $0)" }
        let released = now.addingTimeInterval(-2.5 * 3600 + 1)
        let release = BrandUpdate(
            externalID: "collection:ashgrove-alpine-capsule",
            brand: brands[5],
            title: "Alpine Capsule",
            summary: "Six pieces for wet trails and cold summits.",
            linkURL: URL(string: "https://\(labels[5].host)/collections/alpine-capsule"),
            publishedAt: released,
            kind: .collection
        )
        release.memberExternalIDs = capsule
        release.arrive(at: released)
        context.insert(release)
        brands[5].noteActivity(released)

        // A brand-wide sale, in the words the announcement-bar detector writes (`SaleBanner`).
        let saleAt = now.addingTimeInterval(-1.8 * 3600)
        let sale = BrandUpdate(
            externalID: "sale:\(labels[1].host)",
            brand: brands[1],
            title: "25% OFF · CODE AUTUMN",
            summary: "25% off everything with code AUTUMN.",
            linkURL: URL(string: "https://\(labels[1].host)"),
            publishedAt: saleAt,
            kind: .sale
        )
        sale.arrive(at: saleAt)
        context.insert(sale)
        brands[1].noteActivity(saleAt)

        // Bookmarked out of the feed, so the Inspiration wall — the tab Saved opens on —
        // is not empty. The rest of what is saved is owned.
        let bookmarked = ["ondo-ringer-tee", "ondo-wave-hoodie", "rivet-trucker",
                          "velmar-overshirt", "ondo-skate-shoe", "velmar-pleated-trouser"]
        var saves: [String: SavedItem] = [:]
        for (offset, file) in bookmarked.enumerated() {
            let save = SavedItem(update: byFile[file], savedAt: now.addingTimeInterval(-Double(offset) * 3600))
            context.insert(save)
            saves[file] = save
        }
        for (offset, piece) in pieces.filter(\.owned).enumerated() {
            let save = SavedItem(update: byFile[piece.file], savedAt: now.addingTimeInterval(-Double(offset) * 86_400),
                                 type: .wardrobe)
            context.insert(save)
            saves[piece.file] = save
        }

        for (offset, outfit) in outfits.enumerated() {
            let pairs = outfit.pieces.compactMap { piece in saves[piece.file].map { (piece, $0) } }
            let fit = Fit(items: pairs.map(\.1), verdict: outfit.verdict)
            fit.name = outfit.name
            fit.backgroundName = outfit.ground
            fit.createdAt = now.addingTimeInterval(-Double(offset) * 7200)
            fit.placements = pairs.map { piece, save in
                FitPlacement(itemID: save.id, x: piece.x, y: piece.y, scale: piece.scale,
                             rotation: piece.tilt, z: piece.z)
            }
            context.insert(fit)
        }

        // Dates written down by hand, so the calendar has something ahead of it — and one
        // tomorrow, inside the two days that earn the line above the feed.
        let calendar = Calendar.current
        let morning = calendar.startOfDay(for: now)
        context.insert(PlannedDrop(brand: brands[2], title: "Summer capsule",
                                   releaseAt: morning.addingTimeInterval(1 * 86_400 + 10 * 3600)))
        context.insert(PlannedDrop(brand: brands[4], title: "Indigo 14oz restock",
                                   releaseAt: morning.addingTimeInterval(4 * 86_400 + 10 * 3600)))
        context.insert(PlannedDrop(brand: brands[0], title: "Fall canvas collection",
                                   releaseAt: morning.addingTimeInterval(13 * 86_400 + 18 * 3600)))
        context.insert(PlannedDrop(brand: brands[5], title: "Alpine shells restock",
                                   releaseAt: morning.addingTimeInterval(6 * 86_400 + 17 * 3600)))

        try? context.save()
    }

    /// One garment on a kept fit's canvas, placed by hand: a flat-lay, not the slot table.
    private struct Placed {
        let file: String
        let x: Double, y: Double, scale: Double, tilt: Double, z: Int
    }

    /// Outfits already kept, arranged the way somebody would in the studio — the top layer
    /// overlapping what is under it, trousers below, shoes in front, nothing quite square.
    private static let outfits: [(name: String, ground: String, verdict: String, pieces: [Placed])] = [
        ("Weekend denim", ground: "clay", verdict: "Light over raw, grounded in leather", [
            Placed(file: "velmar-heavy-tee", x: 0.63, y: 0.27, scale: 1.00, tilt: 0.06, z: 30),
            Placed(file: "rivet-trucker", x: 0.35, y: 0.31, scale: 1.22, tilt: -0.07, z: 40),
            Placed(file: "rivet-raw-denim", x: 0.58, y: 0.66, scale: 1.24, tilt: 0.03, z: 20),
            Placed(file: "halden-work-boot", x: 0.25, y: 0.80, scale: 0.72, tilt: -0.10, z: 50)
        ]),
        ("Soft and sharp", ground: "sage", verdict: "A loose knit against a hard pleat", [
            Placed(file: "velmar-heavy-tee", x: 0.64, y: 0.25, scale: 0.92, tilt: 0.08, z: 30),
            Placed(file: "papermoth-cardigan", x: 0.36, y: 0.31, scale: 1.18, tilt: -0.05, z: 40),
            Placed(file: "velmar-pleated-trouser", x: 0.60, y: 0.66, scale: 1.24, tilt: 0.02, z: 20),
            Placed(file: "velmar-loafer", x: 0.26, y: 0.82, scale: 0.70, tilt: -0.14, z: 50)
        ]),
        ("Cobalt on tan", ground: "mist", verdict: "One loud piece, everything else quiet", [
            Placed(file: "ondo-wave-hoodie", x: 0.38, y: 0.30, scale: 1.24, tilt: -0.05, z: 40),
            Placed(file: "halden-cargo-pant", x: 0.62, y: 0.64, scale: 1.28, tilt: 0.03, z: 20),
            Placed(file: "ondo-skate-shoe", x: 0.27, y: 0.81, scale: 0.78, tilt: -0.12, z: 50)
        ]),
        ("Ecru and indigo", ground: "slate", verdict: "Cream over red, a dark straight leg", [
            Placed(file: "ondo-ringer-tee", x: 0.64, y: 0.26, scale: 0.94, tilt: 0.06, z: 30),
            Placed(file: "velmar-overshirt", x: 0.35, y: 0.31, scale: 1.18, tilt: -0.05, z: 40),
            Placed(file: "rivet-raw-denim", x: 0.59, y: 0.66, scale: 1.24, tilt: 0.02, z: 20),
            Placed(file: "velmar-loafer", x: 0.26, y: 0.83, scale: 0.70, tilt: -0.12, z: 50)
        ])
    ]

    /// Puts a sticker lifted on the Mac (`AppStore/demo/cutout.swift`) where `ImageTagger`
    /// would have written its own, and stamps it current so the pass leaves it alone.
    ///
    /// Vision lifts nothing in the Simulator, and `Seamless` refuses these packshots'
    /// soft vignette — so without this every fit in the screenshots is a stack of grey
    /// rectangles. `analyzedImageURL` is set so the photograph does not read as new (which
    /// would re-cut it); `visionVersion` is left stale so colour and silhouette are still
    /// read from the photograph by the app itself.
    private static func installCutout(named file: String, from base: String, on update: BrandUpdate) {
        guard let source = URL(string: "\(base)/cutouts/\(file).png"),
              let data = try? Data(contentsOf: source) else { return }
        let name = Cutout.name(for: update.id)
        try? FileManager.default.createDirectory(at: Cutout.directory, withIntermediateDirectories: true)
        guard (try? data.write(to: Cutout.url(for: name))) != nil else { return }
        update.cutoutFile = name
        update.cutoutVersion = Cutout.version
        update.analyzedImageURL = update.imageURLStrings.first
    }
}
