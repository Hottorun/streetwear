// SitemapSource.swift
// The fallback for brands that aren't Shopify and don't publish a feed.
//
// A sitemap is a machine-readable list of the product pages a brand has, maintained by the
// brand. New products appear in it as new URLs — and that sentence is now the whole method.
//
// **What is new is decided by what has been seen, not by `<lastmod>`.** This adapter used
// to treat `<lastmod>` as `published_at` and skip any entry without one, which worked for
// the Shopify-generated sitemaps it was written against and for almost nothing else. Of the
// three big retailers it was pointed at, Hollister's US product file carries no `lastmod`
// at all (2,123 URLs, every one skipped), Victoria's Secret stamps all 17,134 with the same
// instant, and only Subdued's is informative. A date that is missing or identical cannot
// say what is new; a URL nobody has seen before can.
//
// So the adapter remembers, in the source's `fingerprint` — the same field a page watch
// keeps its content hash in, and for the same reason: it is this source's memory of what
// it looked like last time (`SitemapMemory`). The first read is a baseline and announces
// nothing (`FetchResult.isBaseline`); every later read announces exactly the URLs the
// memory has not seen. That also makes the 304 path matter, because a 7 MB sitemap is
// read in full on every poll that is not one — see `minimumInterval`.
//
// It still cannot give a product a price. It *can* often give a name and a photograph,
// because most generators emit Google's image extension inside each `<url>`:
//
//     <image:image>
//       <image:loc>https://cdn.shopify.com/…/palace-avirex-jacket-black-1.png</image:loc>
//       <image:title>PALACE AVIREX JACKET BLACK</image:title>
//     </image:image>
//
// **That title is the product's real name and it must be preferred over the slug.**
// Palace randomises its handles until a drop is live — `/products/av1bal6eijz1` — so a
// slug-derived title produced a feed of "E7Anvz3I1Psy" over an empty grey tile, while
// the correct name and the correct photograph were sitting two lines further down the
// same XML. The rest — price, stock, sizes — comes from the product's own page, once, in
// `ProductPage`.

import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SitemapSource: SourceAdapter {
    public var kind: BrandSource.Kind { .sitemap }

    /// Child sitemaps one read may fetch, across every level of the tree. Four covers the
    /// deepest shape seen — Victoria's Secret is index → locale index → product file, two —
    /// with room for a catalogue split into parts, and keeps one brand from turning a poll
    /// into a crawl of somebody's whole site.
    static let maxChildFetches = 4
    /// How many levels of index are followed below the one the source points at.
    static let maxDepth = 3
    /// Entries read from one poll at most. Victoria's Secret's US product file is the largest
    /// seen at 17,134; this is a bound on memory, not a sample.
    static let maxEntries = 50_000
    /// Rows a baseline stores. The baseline is context, not news, and a 17,000-product
    /// retailer does not need 17,000 rows to know what is new tomorrow — the memory does
    /// that. These are the newest, for the brand page and Discover to show something.
    static let baselineItems = 60
    /// New products one read announces. A drop larger than this arrives over the next polls
    /// rather than being lost: the overflow is left out of the memory, so it is still new
    /// next time.
    static let maxNewItems = 250

    /// The shortest interval between two reads of one sitemap, on both ends.
    ///
    /// Sitemaps are regenerated on a schedule, not as products go up — Subdued's file was
    /// last written the night before it was read, Victoria's Secret's at 02:31, Hollister's
    /// is cached at the edge for a day — so reading one every minute inside a drop window
    /// finds nothing a read an hour later would not, and Subdued's is 7.2 MB a time where
    /// there is no validator to make it a 304. An hour is the polite floor.
    public static let minimumInterval: TimeInterval = 3600

    private let http: any HTTPFetching

    public init(http: any HTTPFetching = Net.live) {
        self.http = http
    }

    /// `since` is not used: the memory says what is new, and a date the sitemap may not
    /// publish cannot.
    public func fetch(_ source: BrandSource, since: Date?) async throws -> FetchResult {
        try await read(source, preferring: LocalePreference.of(source.url)).result
    }

    // MARK: - Reading

    /// A read, plus where it settled: the deepest URL reached by choosing between
    /// storefronts, which is what discovery pins the source to.
    struct Reading {
        var result: FetchResult
        var pin: URL
    }

    func read(_ source: BrandSource, preferring preference: LocalePreference) async throws -> Reading {
        let memory = SitemapMemory(fingerprint: source.fingerprint)

        // The root's validator is only worth sending when the root is itself the list of
        // pages. An index that answers 304 has said nothing about its children, which are
        // where products change — so an index is re-read (it is a few kilobytes) and each
        // child carries its own validator instead.
        let rootETag = memory?.rootIsIndex == true ? nil : source.etag
        let root = try await http.get(source.url, etag: rootETag)
        if root.notModified {
            return Reading(result: FetchResult(etag: source.etag, notModified: true), pin: source.url)
        }
        if root.isLocked {
            return Reading(result: FetchResult(isLocked: true, etag: source.etag), pin: source.url)
        }
        try root.requireOK()

        let parsed = SitemapParser().parse(root.data)
        guard !parsed.isEmpty else { throw SourceError.emptyPayload }

        var walk = Walk(
            http: http,
            preference: preference,
            validators: memory?.validators ?? [:],
            pin: source.url
        )
        let rootIsIndex = Self.isIndex(parsed)
        if rootIsIndex {
            await walk.follow(parsed.map(\.location), depth: 1)
            // Every child failed and none was merely unchanged: say so. Returning nothing is
            // the brand row reading "Sitemap", recording no error and delivering nothing,
            // which is the failure this file has had to be rescued from three times.
            if walk.read == 0, walk.unchanged == 0, let failure = walk.failures.first {
                throw failure
            }
        } else {
            walk.collect(parsed, listing: source.url.absoluteString)
        }

        let products = Self.products(in: walk.pages)
        let outcome = memory.map { remember(products, after: $0, walk: walk) }
            ?? baseline(products)
        var result = outcome.result
        result.etag = rootIsIndex ? nil : root.etag

        let updated = SitemapMemory(
            seen: outcome.seen,
            validators: walk.newValidators,
            rootIsIndex: rootIsIndex
        )
        // Handed back only when it moved, so an unchanged sitemap does not rewrite a large
        // text column on every poll — on Postgres each rewrite is a dead tuple.
        result.fingerprint = updated == memory ? nil : updated.fingerprint
        return Reading(result: result, pin: walk.pin)
    }

    /// What a read concluded, before the memory is encoded.
    private struct Outcome {
        var result: FetchResult
        var seen: Set<UInt32>
    }

    /// The first read of a source: everything listed is remembered and nothing is news.
    private func baseline(_ products: [Product]) -> Outcome {
        let informative = Self.hasInformativeDates(products)
        let confirmed = products.filter { !$0.isTentative }
        let items = Self.ranked(confirmed, informative: informative)
            .prefix(Self.baselineItems)
            .map { item(for: $0, publishedAt: informative ? $0.lastModified : nil) }
        return Outcome(
            result: FetchResult(items: Array(items), isBaseline: true),
            seen: Set(products.map(\.digest))
        )
    }

    /// A later read: only what the memory has not seen is offered, and it is offered as
    /// first seen now.
    private func remember(_ products: [Product], after memory: SitemapMemory, walk: Walk) -> Outcome {
        let unseen = products.filter { !memory.seen.contains($0.digest) }

        // **A sitemap that has been rebuilt is not a drop.** A storefront moving to new URLs —
        // a replatform, a locale prefix added — makes its whole catalogue unseen at once, and
        // announcing that would be thousands of "new products" that were on sale yesterday.
        // More than half of what is listed, and more than one read's worth, is that.
        if unseen.count > max(Self.maxNewItems, products.count / 2) {
            return Outcome(
                result: FetchResult(items: [], isBaseline: true),
                seen: memory.seen.union(products.map(\.digest))
            )
        }

        let informative = Self.hasInformativeDates(products)
        let ordered = Self.ranked(unseen, informative: informative)
        let announced = ordered.prefix(Self.maxNewItems)
        let deferred = Set(ordered.dropFirst(Self.maxNewItems).map(\.digest))

        var seen = memory.seen.union(products.map(\.digest).filter { !deferred.contains($0) })
        // The memory only grows while URLs come and go. When it holds far more than is
        // listed, and every file was actually read this time, it is rebuilt from what is
        // listed — a 304'd child's URLs are not in hand, and forgetting them would make them
        // all new the day that file next changes.
        if walk.unchanged == 0, seen.count > 2 * products.count + 1_000 {
            seen = Set(products.map(\.digest).filter { !deferred.contains($0) })
        }

        let items = announced.map { item(for: $0, publishedAt: nil) }
        return Outcome(result: FetchResult(items: Array(items)), seen: seen)
    }

    private func item(for product: Product, publishedAt: Date?) -> FetchedItem {
        FetchedItem(
            externalID: "sitemap:\(product.url.absoluteString)",
            title: Self.title(for: product.entry, url: product.url),
            linkURL: product.url,
            imageURLStrings: product.entry.imageLocation.map { [$0] } ?? [],
            // A baseline row keeps the date the sitemap gave it, when the sitemap's dates
            // mean anything; everything announced later is dated by when it was first seen,
            // the way `UCPSource` dates what it finds.
            publishedAt: publishedAt ?? Date(),
            kind: .product,
            isTentative: product.isTentative
        )
    }

    // MARK: - What is a product

    /// One page the sitemap lists that might be for sale.
    struct Product {
        var entry: Entry
        var url: URL
        /// Whether only the page itself can say this is a product — see `classify`.
        var isTentative: Bool
        var digest: UInt32
        var lastModified: Date?
    }

    /// Every product the listings name, in document order, with what is plainly not a
    /// product removed.
    static func products(in pages: [Walk.Page]) -> [Product] {
        var found: [Product] = []
        var listed: Set<String> = []
        for page in pages {
            guard let verdict = classify(page.entry, inProductListing: page.inProductListing),
                  let url = URL(string: page.entry.location),
                  listed.insert(page.entry.location).inserted
            else { continue }
            found.append(Product(
                entry: page.entry,
                url: url,
                isTentative: verdict == .tentative,
                digest: SitemapMemory.digest(page.entry.location),
                lastModified: page.entry.lastModified.flatMap(DateParsing.any)
            ))
        }

        // **A page that another listed page sits beneath is the parent, not a product.**
        // Victoria's Secret lists every garment twice — `/us/vs/apparel-catalog/1130196700`
        // and, beneath it, one page per colourway with the photographs — and reading both
        // announced each new garment once per colourway plus once more for nothing.
        var parents: Set<String> = []
        for product in found {
            var path = product.url.path
            while let slash = path.lastIndex(of: "/"), slash != path.startIndex {
                path = String(path[..<slash])
                parents.insert((product.url.host() ?? "") + path)
            }
        }
        return found.filter { product in
            let path = product.url.path.hasSuffix("/") ? String(product.url.path.dropLast()) : product.url.path
            return !parents.contains((product.url.host() ?? "") + path)
        }
    }

    enum Verdict { case product, tentative }

    /// Whether an entry is a product, from what the sitemap itself says.
    ///
    /// URL patterns were the whole test once, and they missed two of the three retailers
    /// this was rebuilt against — Subdued's products live at `/us_en/scoop-neck-top-cn01j79`,
    /// which matches nothing. So the evidence is taken in order of strength:
    ///
    /// 1. **The path.** `/products/`, `/p/` and friends, as before.
    /// 2. **The file.** A sitemap named for products (`product-1.xml`, Hollister's
    ///    `…/sitemap/product?…`) lists products; that is what it is for — bar anything under
    ///    a section that never holds one, `/pages/` or `/blog/` or a category.
    /// 3. **A photograph.** In a mixed sitemap — Magento writes categories, CMS pages and
    ///    products into one file — the image extension is carried by products and by
    ///    nothing else: all 5,972 entries with one in Subdued's file are products, and its
    ///    81 without are categories and pages, bar a handful of products shot without one.
    /// 4. **Otherwise the page decides.** An entry with none of the above is *tentative*:
    ///    stored, never announced, until `ProductPage` has read it and found a product
    ///    there. A baseline leaves tentative entries out entirely.
    static func classify(_ entry: Entry, inProductListing: Bool) -> Verdict? {
        guard !entry.isIndex, let url = URL(string: entry.location),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        guard let last = segments.last, !listingWords.contains(last) else { return nil }

        if looksLikeProduct(entry.location) { return .product }
        // Before the file's own word: a product sitemap that also lists `/pages/about` has
        // not made it a product by doing so.
        if segments.contains(where: sectionWords.contains) { return nil }
        if inProductListing { return .product }
        if entry.imageLocation != nil { return .product }
        return .tentative
    }

    /// A path ending in one of these is the listing itself — `/products/`, `/shop` — not a
    /// thing for sale in it.
    private static let listingWords: Set<String> = ["products", "product", "shop", "p", "item", "store", "collections"]

    /// Sections of a site that hold no products, whatever else a page in them carries.
    private static let sectionWords: Set<String> = [
        "blog", "blogs", "pages", "page", "collections", "collection", "category", "categories",
        "news", "journal", "stories", "editorial", "lookbook", "help", "faq", "account", "cart",
        "checkout", "search", "policies", "legal", "about", "contact", "stores", "sale", "saldi",
        "outlet", "brands"
    ]

    /// Path shapes that hold individual products across the platforms streetwear brands
    /// actually use — Shopify, WooCommerce, Squarespace, BigCommerce and custom builds.
    static func looksLikeProduct(_ location: String) -> Bool {
        let lowered = location.lowercased()
        let markers = ["/products/", "/product/", "/shop/", "/p/", "/item/", "/store/"]
        guard markers.contains(where: lowered.contains) else { return false }
        // The listing page itself is not a product.
        return !markers.contains { lowered.hasSuffix($0) || lowered.hasSuffix(String($0.dropLast())) }
    }

    /// Whether a sitemap's entries are other sitemaps.
    ///
    /// A `<sitemapindex>` says so; a `<urlset>` whose every entry is an `.xml` file is the
    /// same thing badly spelled — Carhartt WIP wraps its 38 locale sitemaps in one.
    static func isIndex(_ entries: [Entry]) -> Bool {
        entries.allSatisfy { entry in
            if entry.isIndex { return true }
            let path = URL(string: entry.location)?.path.lowercased() ?? ""
            return path.hasSuffix(".xml") || path.hasSuffix(".xml.gz")
        }
    }

    /// Whether the dates in a listing distinguish anything.
    ///
    /// Victoria's Secret writes one instant on all 17,134 products; Hollister writes none.
    /// Either way, ordering by them is ordering by noise, and a baseline row dated by one is
    /// dated wrongly.
    static func hasInformativeDates(_ products: [Product]) -> Bool {
        let dates = products.compactMap(\.lastModified)
        guard dates.count > 1 else { return false }
        var counts: [Date: Int] = [:]
        for date in dates { counts[date, default: 0] += 1 }
        guard counts.count > 1, let common = counts.values.max() else { return false }
        return Double(common) / Double(dates.count) < 0.9
    }

    /// Newest first when the dates mean something; otherwise photographs first, then the
    /// order the brand listed them in.
    static func ranked(_ products: [Product], informative: Bool) -> [Product] {
        let indexed = Array(products.enumerated())
        let sorted = indexed.sorted { a, b in
            if informative {
                let left = a.element.lastModified ?? .distantPast
                let right = b.element.lastModified ?? .distantPast
                if left != right { return left > right }
            } else {
                let left = a.element.entry.imageLocation != nil
                let right = b.element.entry.imageLocation != nil
                if left != right { return left }
            }
            return a.offset < b.offset
        }
        return sorted.map(\.element)
    }

    // MARK: - Names

    /// The best name the entry can offer, in descending order of trust.
    ///
    /// The image extension's `<image:title>` is the brand's own words and beats anything
    /// derived from a URL. The slug is next, and only when it reads as language — a
    /// randomised handle is worse than admitting we don't have a name, because it prints
    /// a hash where a product should be.
    static func title(for entry: Entry, url: URL) -> String {
        if let published = entry.imageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !published.isEmpty {
            return published
        }
        let derived = title(from: url)
        return isReadable(derived) ? derived : unnamed
    }

    /// What a product is called when nothing has told us yet.
    public static let unnamed = "New arrival"

    /// Whether a title is a stand-in rather than a name.
    ///
    /// Both ends of the sync consult this before *replacing* a stored title: a product
    /// whose name arrived late — a randomised handle that a later poll resolved through
    /// the image extension — should take the real one, and a real one should never be
    /// downgraded back to a hash. Everything else keeps whatever it was given.
    public static func isProvisional(_ title: String) -> Bool {
        title == unnamed || !isReadable(title)
    }

    /// Whether a slug-derived title is a name or a hash.
    ///
    /// A real slug is words: it either has more than one of them, or it is a single word
    /// with no digits stirred through it. "av1bal6eijz1" and "e7anvz3i1psy" are neither,
    /// and there is no length at which a lone letter-and-digit soup becomes a product
    /// name. Short codes stay readable, because "FW26" genuinely is what something is
    /// called.
    public static func isReadable(_ title: String) -> Bool {
        let words = title.split(separator: " ")
        guard words.count == 1, let only = words.first else { return !words.isEmpty }
        guard only.count > 5 else { return true }
        let hasDigit = only.contains(where: \.isNumber)
        let hasLetter = only.contains(where: \.isLetter)
        return !(hasDigit && hasLetter)
    }

    /// "…/products/kith-box-logo-hoodie-black" → "Kith Box Logo Hoodie Black".
    ///
    /// Crude, and knowingly so. For streetwear the slug is usually the product name,
    /// which beats showing a bare URL — but see `isReadable`, because it is sometimes
    /// deliberately not.
    ///
    /// A catalogue number on the end is dropped: Hollister ends every slug with one
    /// (`…-denim-shortie-shorts-62344837`) and Subdued with a style code (`…-top-cn01j79`),
    /// and neither is part of anybody's name for the garment. Only the last word, only when
    /// it is a long run of digits or a long letter-and-digit code, and never the only word —
    /// a season code like "FW26" is too short to be taken for one.
    static func title(from url: URL) -> String {
        let slug = url.pathComponents.last(where: { $0 != "/" }) ?? url.absoluteString
        var words = slug
            .replacingOccurrences(of: ".html", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
        if words.count > 1, let last = words.last, isCatalogueNumber(last) {
            words.removeLast()
        }
        let cased = words.map { text -> String in
            // Keep acronyms and season codes as they are: "FW26" must not become
            // "Fw26", and "SS26" is not "Ss26".
            let isCode = text.count <= 4 && text.rangeOfCharacter(from: .decimalDigits) != nil
            return isCode ? text.uppercased() : text.capitalized
        }
        return cased.isEmpty ? url.absoluteString : cased.joined(separator: " ")
    }

    private static func isCatalogueNumber(_ word: String) -> Bool {
        let digits = word.filter(\.isNumber).count
        if digits == word.count { return word.count >= 5 }
        return word.count >= 6 && digits > 0 && word.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: - Detection

    /// **Attached only if it actually yields products, which is settled by reading it.**
    ///
    /// Judging on the names in a file is a guess. Acne Studios and Palm Angels both passed
    /// that test and then produced nothing on every poll for weeks, so detection runs the
    /// same read a poll would and requires at least one item out of it — one full read at
    /// add time, the bargain `UCPSource.detect` makes too, and cheaper than the alternative
    /// of that read happening every hour forever against a source that never answers.
    ///
    /// **robots.txt first.** Hollister, Subdued and victoriassecret.com publish theirs only
    /// there, at paths nobody would guess — `/api/ecomm/util/sitemap/index/hol`,
    /// `/media/sitemap/us_en/sitemap.xml` — and `/sitemap.xml` is a 404 on two of the three.
    /// Several listed is a choice between storefronts and is made the way an index's
    /// children are (`SitemapChoice`). Only the brand's own domain is believed: a sitemap
    /// elsewhere is somebody else's catalogue.
    ///
    /// - Parameter hint: the URL somebody typed, path and all, which may say which
    ///   storefront they meant (`/eu_en/`, `uk.`). Only read, never fetched.
    /// - Returns: the URL to pin the source to — the deepest one reached by choosing
    ///   between storefronts, so a poll never has to make that choice again with less to
    ///   go on.
    public static func detect(
        at base: URL,
        preferring hint: URL? = nil,
        http: any HTTPFetching = Net.live
    ) async -> URL? {
        let preference = LocalePreference.of(hint ?? base)

        // **The host that was typed, then its `www.` twin, and nothing else** — the swap
        // `ShopifySource.resolve` makes, for the same reason and with the same limit (every
        // other subdomain is a region). Hollister's apex answers `/robots.txt` with a
        // redirect to `/robots-hollisterco.com.txt` on `www.`, which is a 404, while
        // `www.`'s own robots.txt names the sitemap: typed the way people type it, without
        // the `www.`, the shop read as having no sitemap at all and fell to a page watch.
        let hosts = [base, ShopifySource.wwwVariant(of: base)].compactMap { $0 }
        var roots: [URL] = []
        for host in hosts {
            roots = await robotsSitemaps(at: host, http: http, preferring: preference)
            if !roots.isEmpty { break }
        }
        for host in hosts {
            for path in ["/sitemap.xml", "/sitemap_index.xml"] {
                var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
                components?.path = path
                components?.query = nil
                if let url = components?.url, !roots.contains(url) { roots.append(url) }
            }
        }

        let adapter = SitemapSource(http: http)
        for root in roots.prefix(4) {
            let probe = BrandSource(kind: .sitemap, url: root)
            guard let reading = try? await adapter.read(probe, preferring: preference),
                  !reading.result.items.isEmpty
            else { continue }
            return reading.pin
        }
        return nil
    }

    /// The sitemaps a site's robots.txt names, already narrowed to one storefront.
    private static func robotsSitemaps(
        at base: URL,
        http: any HTTPFetching,
        preferring preference: LocalePreference
    ) async -> [URL] {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/robots.txt"
        components?.query = nil
        guard let url = components?.url,
              let response = try? await http.get(url), response.status == 200,
              let host = base.host()
        else { return [] }

        let domain = BrandDiscovery.registrableDomain(of: host)
        let listed = RobotsRules.sitemaps(in: String(decoding: response.data, as: UTF8.self))
            .filter { $0.host().map { BrandDiscovery.registrableDomain(of: $0) == domain } ?? false }
        return SitemapChoice.select(listed.map(\.absoluteString), preferring: preference)
            .follow
            .compactMap(URL.init(string:))
    }

    // MARK: - The tree

    /// One walk down a sitemap tree, within the read's budget.
    struct Walk {
        struct Page {
            var entry: Entry
            var inProductListing: Bool
        }

        let http: any HTTPFetching
        let preference: LocalePreference
        /// Validators from the last read, by child URL.
        let validators: [String: String]
        var newValidators: [String: String] = [:]
        var budget = SitemapSource.maxChildFetches
        var pages: [Page] = []
        /// Children that answered with a body, and children that answered 304.
        var read = 0
        var unchanged = 0
        var failures: [any Error] = []
        /// Moves down the tree each time a choice between storefronts leaves one child.
        var pin: URL

        init(http: any HTTPFetching, preference: LocalePreference, validators: [String: String], pin: URL) {
            self.http = http
            self.preference = preference
            self.validators = validators
            self.pin = pin
        }

        mutating func follow(_ children: [String], depth: Int) async {
            let choice = SitemapChoice.select(children, preferring: preference)
            for child in choice.follow {
                guard budget > 0 else { return }
                guard let url = URL(string: child) else { continue }
                budget -= 1

                let response: HTTPResponse
                do {
                    response = try await http.get(url, etag: validators[child])
                } catch {
                    failures.append(error)
                    continue
                }
                if response.notModified {
                    unchanged += 1
                    if let old = validators[child] { newValidators[child] = old }
                    if choice.choseStorefront, choice.follow.count == 1 { pin = url }
                    continue
                }
                guard response.status == 200 else {
                    failures.append(SourceError.badResponse(response.status))
                    continue
                }
                read += 1
                if let etag = response.etag { newValidators[child] = etag }
                if choice.choseStorefront, choice.follow.count == 1 { pin = url }

                let entries = SitemapParser().parse(response.data)
                if SitemapSource.isIndex(entries) {
                    if depth < SitemapSource.maxDepth {
                        await follow(entries.map(\.location), depth: depth + 1)
                    }
                } else {
                    collect(entries, listing: child)
                }
            }
        }

        mutating func collect(_ entries: [Entry], listing: String) {
            let isProductListing = SitemapChoice.kind(of: listing) == .products
            for entry in entries where !entry.isIndex {
                guard pages.count < SitemapSource.maxEntries else { return }
                pages.append(Page(entry: entry, inProductListing: isProductListing))
            }
        }
    }

    struct Entry {
        var location: String
        var lastModified: String?
        /// True when this came from `<sitemapindex>` — a pointer to another sitemap
        /// rather than to a page.
        var isIndex: Bool
        /// First `<image:loc>` in this entry, when the sitemap carries the image
        /// extension. Sitemaps list images newest-first per page, so the first one is the
        /// product's lead shot.
        var imageLocation: String?
        /// First `<image:title>`, which is the product's real name.
        var imageTitle: String?

        init(
            location: String,
            lastModified: String? = nil,
            isIndex: Bool,
            imageLocation: String? = nil,
            imageTitle: String? = nil
        ) {
            self.location = location
            self.lastModified = lastModified
            self.isIndex = isIndex
            self.imageLocation = imageLocation
            self.imageTitle = imageTitle
        }
    }
}

/// What a sitemap source remembers between reads: every product URL it has seen, as a
/// 32-bit digest, and the validators of the child files it read.
///
/// **A digest and not the URLs.** Victoria's Secret lists 12,854 product pages; as URLs that
/// is over a megabyte rewritten whenever one is added, and as digests it is 50 KB. A digest
/// can collide, and the cost of one is a single new product taken for an old one — for a
/// listing of 17,000 that is a chance of about one in 250,000 per new product.
///
/// FNV-1a rather than `Hasher`, which is seeded per process: a memory written by one
/// launch has to be read by the next.
///
/// Held in `BrandSource.fingerprint`, behind a versioned prefix. Anything that does not
/// decode — a page watch's hash, a row written before this existed, a future format — reads
/// as no memory at all, which is a silent re-baseline: the safe direction, since the other
/// one is announcing a whole catalogue.
struct SitemapMemory: Equatable {
    var seen: Set<UInt32>
    var validators: [String: String]
    var rootIsIndex: Bool

    static let prefix = "sitemap-memory/1 "

    init(seen: Set<UInt32>, validators: [String: String], rootIsIndex: Bool) {
        self.seen = seen
        self.validators = validators
        self.rootIsIndex = rootIsIndex
    }

    init?(fingerprint: String?) {
        guard let fingerprint, fingerprint.hasPrefix(Self.prefix),
              let data = fingerprint.dropFirst(Self.prefix.count).data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let bytes = Data(base64Encoded: stored.seen), bytes.count % 4 == 0
        else { return nil }

        var seen = Set<UInt32>()
        seen.reserveCapacity(bytes.count / 4)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let value = bytes[index..<(index + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            seen.insert(value)
            index += 4
        }
        self.seen = seen
        self.validators = stored.validators ?? [:]
        self.rootIsIndex = stored.index ?? false
    }

    var fingerprint: String {
        var bytes = Data()
        bytes.reserveCapacity(seen.count * 4)
        for value in seen.sorted() {
            bytes.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        let stored = Stored(seen: bytes.base64EncodedString(), validators: validators, index: rootIsIndex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Self.prefix + json
    }

    /// FNV-1a, 32 bits, over the URL exactly as the sitemap lists it.
    static func digest(_ location: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in location.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// Optional fields, so a memory missing one still reads rather than re-baselining.
    private struct Stored: Codable {
        var seen: String
        var validators: [String: String]?
        var index: Bool?
    }
}

/// Handles both `<urlset>` and `<sitemapindex>`; they share the same `<loc>`/`<lastmod>`
/// shape and differ only in their wrapper, so one parser covers both.
private final class SitemapParser: NSObject, XMLParserDelegate {
    private var entries: [SitemapSource.Entry] = []
    private var location = ""
    private var lastModified = ""
    private var imageLocation = ""
    private var imageTitle = ""
    private var current: String?
    /// `<image:image>` nests a `<loc>` and a `<title>` of its own, so the same local
    /// names mean two different things depending on where they are. Without this the
    /// image URL overwrites the page URL and every entry points at a CDN photograph.
    private var isInsideImage = false

    func parse(_ data: Data) -> [SitemapSource.Entry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    /// The parser is not namespace-aware, so elements arrive qualified — "image:loc",
    /// not "loc". Prefixes are conventional rather than fixed, so the local part is what
    /// gets matched.
    private static func localName(_ elementName: String) -> String {
        let lowered = elementName.lowercased()
        guard let separator = lowered.lastIndex(of: ":") else { return lowered }
        return String(lowered[lowered.index(after: separator)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = Self.localName(elementName)
        if name == "url" || name == "sitemap" {
            location = ""
            lastModified = ""
            imageLocation = ""
            imageTitle = ""
        }
        if name == "image" { isInsideImage = true }
        current = name
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch (current, isInsideImage) {
        case ("loc", false): location += string
        case ("lastmod", _): lastModified += string
        // Only the first image in an entry is kept; a product page lists every shot.
        case ("loc", true) where imageLocation.isEmpty: imageLocation += string
        case ("title", true) where imageTitle.isEmpty: imageTitle += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = Self.localName(elementName)
        if name == "image" { isInsideImage = false }
        if name == "url" || name == "sitemap" {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let modified = lastModified.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(
                    SitemapSource.Entry(
                        location: trimmed,
                        lastModified: modified.isEmpty ? nil : modified,
                        isIndex: name == "sitemap",
                        imageLocation: Self.cleaned(imageLocation),
                        imageTitle: Self.cleaned(imageTitle)
                    )
                )
            }
        }
        current = nil
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
