// SharedSaveImporter.swift
// Turns links shared from elsewhere into saved items.
//
// This is what makes Dropwall an archive rather than a feed reader: the collection stops
// being limited to brands we happen to watch. A link from any storefront, any blog, any
// resale listing becomes a card on the wall.
//
// The enrichment happens here rather than in the extension because the app has time and
// memory the extension doesn't. If the fetch fails the save still lands — with the URL
// and whatever title the share sheet gave us — because losing someone's save to a flaky
// network would be far worse than an ugly card.
//
// **What Safari already loaded comes first, after the catalogue** (contract 2, see
// `SharedPage`). The share sheet hands over the page as the person's own browser drew it —
// its JSON-LD, its tags and its largest pictures — and this reads it with the same
// `ProductPage` the app's own fetch uses. That is the fix for shops whose pages answer the
// browser and not us, and for the colourway on screen, which is in the address Safari had and
// not in the canonical one it shares. The phone's own fetch is the fallback for a link shared
// from an app that hands over no page.
//
// **It fetches from the phone in both modes, and that is a deliberate exception to "go over
// the server when one is configured".** Written down here because it was not written down
// anywhere, which is the actual fault: `StockRefresh` names the same exception in its own
// header and is the only one CLAUDE.md's routing table knew about. The reason is that there
// is no route to call. A share is an arbitrary URL from any storefront, any blog, any resale
// listing — the server's catalogue is brands somebody added, so it has nothing to look this
// up in, and a route that made the server fetch a URL a client chose is the shape of request
// `RequireDevice` was added to stop being anonymous. The calls are bounded rather than
// open-ended: `ShopifySource.product(at:)` and the page itself are one request each per newly
// shared link, a repair is at most `repairBatch` links a pass on a widening schedule, and
// `identifySites` is one homepage per *host* per `siteIdentityVersion`, stamped whatever the
// answer was, capped at `identifyBatch` hosts a pass. All go through the same adapters as
// everything else the phone fetches. A route would be the better answer the day this needs to
// happen in bulk — the same conclusion `StockRefresh` reaches.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum SharedSaveImporter {
    /// This path runs without anyone watching — a share arrives while the app is closed
    /// and is filed on the next launch. When it goes wrong there is nothing on screen to
    /// see, so it says what it did.
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "share")
    /// How long to wait for a page's own description before giving up on it.
    ///
    /// A storefront product page is heavy and occasionally just hangs. The save must not
    /// hang with it: a card with no photograph is a poor card, but a save that never
    /// arrives is a lost one, so the fetch is capped and the item is filed regardless.
    private static let metadataTimeout: Duration = .seconds(12)
    private static var isDraining = false

    /// Files everything waiting in the inbox into the store. Returns how many landed.
    ///
    /// The sheet asked what it could — boards, a watch, a follow — and wrote the answers into
    /// the share's file; they are carried out here. What it could not ask is asked here,
    /// because here is the first moment anyone knows the answer: whether the thing is sold
    /// out, and which sizes it comes in. Those questions go into `questions`, which keeps
    /// them until they are answered (`ShareQuestions`); they are written **before** the inbox
    /// file is removed, so no kill in between can lose one.
    ///
    /// - Parameter scope: whose store `context` is. Only that profile's shares are filed; the
    ///   rest wait in the inbox until their profile is current — except a share for a profile
    ///   this phone no longer has, which the holder takes rather than leaving it forever.
    @discardableResult
    static func drain(
        into context: ModelContext,
        scope: ProfileScope? = nil,
        questions: ShareQuestions,
        remote: RemoteSync?,
        confirm: SaveConfirmation? = nil
    ) async -> Int {
        // One drain at a time. A cold launch runs two — `ContentView`'s `.task` and the
        // scene-phase drain — and both read the same file before either removed it, so every
        // share was fetched twice and filed once.
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }

        let scope = scope ?? ProfileScope.active
        let known = ProfileScope.known
        // By store, never by "whoever is current": a share filed while another Apple ID was
        // signed in waits for that account rather than landing in this one's wall. And not
        // while its sheet is still open — the file is rewritten with every choice until Done.
        let pending = SharedInbox.pending().filter { item in
            guard SharedInbox.isSettled(item.save) else { return false }
            guard let owner = item.save.profileID else { return scope.home == nil }
            guard known.contains(owner) else { return scope.isHolder }
            return owner == scope.home
        }
        log.info("inbox: container \(SharedInbox.isAvailable ? "ok" : "MISSING"), \(pending.count) pending")
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        var landed: [BrandUpdate] = []
        var quiet: [BrandUpdate] = []
        for item in pending {
            let save = item.save

            // A shop's page somebody chose to follow: nothing is saved, the follow is kept for
            // `ShareFollows`, which needs the network and possibly several foregrounds.
            guard save.savesPage else {
                if save.follow == true {
                    let page = save.page?.url ?? save.url
                    questions.follow(page, named: save.page?.metadata(base: page).siteName, sharedAt: save.sharedAt, for: scope)
                }
                SharedInbox.remove(item.id)
                continue
            }

            // One at a time on purpose: sharing happens a link at a time, and a burst of
            // parallel requests to one storefront is exactly what `PoliteFetcher`
            // exists to prevent elsewhere.
            let reading = await read(save)
            let result = importOne(save, reading: reading, into: context)
            let update = result.update
            if result.isNew { imported += 1 }
            file(update, as: save, in: context)
            let watched = setWatches(on: update, from: save, in: context)
            do {
                // Only once it is genuinely committed is the file dropped. A failed save
                // leaves the item in the inbox to be retried, which is the whole reason
                // reading and deleting are separate steps.
                try context.save()
                let asked = ask(about: update, from: save, questions: questions, scope: scope)
                SharedInbox.remove(item.id)
                log.info("imported \(save.url.absoluteString, privacy: .public) (new: \(result.isNew), page: \(save.page != nil), photos: \(update.imageURLStrings.count))")
                // A share that asked something, or set a watch, has had its answer; the
                // confirmation is for one that landed quietly.
                if result.isNew { landed.append(update) }
                if result.isNew, !asked, watched.isEmpty { quiet.append(update) }
            } catch {
                log.error("could not store \(save.url.absoluteString, privacy: .public): \(error)")
                continue
            }
            // Mirrored to the server after the store has them, the way `WatchEditor` does it.
            if let remote {
                for watch in watched { await remote.createWatch(watch) }
            }
        }

        // Once for the whole drain, and only for a lone share. Sharing five things should not
        // flash five confirmations that each replace the last unread — and a confirmation whose
        // buttons act on *one* product has no honest subject when several arrived, which is the
        // same reason a counted push carries no `eventID`. Not a question: the sheet already
        // offered its board and its watch, so nothing is lost when it goes.
        if landed.count == 1, quiet.count == 1, let only = quiet.first {
            confirm?.confirm(only, destination: only.save?.destinationLabel ?? "Inspiration")
        }
        return imported
    }

    /// The revision of enrichment that `repair` stamps. Bump it when this file learns to
    /// find something it previously couldn't, and every thin save gets one more look.
    ///
    /// 2: enrichment now takes the catalogue's whole set of photographs over the single
    /// Open Graph frame a share arrives with, so every link filed under revision 1 is owed
    /// another look — and the images it gains are what put it back in front of
    /// `ImageTagger`.
    ///
    /// 3: the page's own JSON-LD is read as well as its Open Graph, which is where a shop
    /// that is not on Shopify keeps its price, stock, photographs and sizes — so every share
    /// that found no catalogue is owed one more look.
    static let enrichmentVersion = 3

    /// How many thin saves to re-fetch per pass.
    ///
    /// Small on purpose. This runs on a foreground with nobody asking for it, against
    /// storefronts that owe us nothing, and there is no hurry: a save that has been a bare
    /// bookmark for a month can be a bare bookmark for another minute. Several passes
    /// drain a backlog.
    private static let repairBatch = 4

    /// How long a share with no photograph waits before each further try, after the first.
    /// Widening, and short: a phone that was offline heals within the hour, a bot wall that
    /// let one request through lets another, and past the last a page that has never given
    /// a picture in four days is not going to — the save stays, without one.
    static let photoRetryDelays: [TimeInterval] = [3_600, 6 * 3_600, 86_400, 3 * 86_400]
    private static let firstPhotoRetry: TimeInterval = 300

    /// Files saved items under a brand they were never attributed to.
    ///
    /// Costs no network and is idempotent, so it needs no version stamp: it looks only at
    /// rows that have no brand at all, and the answer either exists in the store now or it
    /// doesn't. Rows land brandless for two reasons and both heal here — the host match
    /// used to be exact, so anything from a brand's other storefronts missed; and a link
    /// can simply be shared before its brand is followed, which is the ordinary way round
    /// for somebody who finds a label and then decides to watch it.
    @discardableResult
    static func attachBrands(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.brand == nil && !$0.saves.isEmpty }
        )
        descriptor.fetchLimit = 200

        let orphans = (try? context.fetch(descriptor)) ?? []
        guard !orphans.isEmpty else { return 0 }

        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        guard !brands.isEmpty else { return 0 }

        var attached = 0
        for update in orphans {
            guard let link = update.linkURL,
                  let brand = brands.first(where: { BrandDiscovery.isSameBrandHost(link, $0.websiteURL) })
            else { continue }
            update.brand = brand
            attached += 1
        }
        if attached > 0 {
            try? context.save()
            log.info("attached \(attached) saved items to a brand")
        }
        return attached
    }

    /// The revision of the site probe. Bump it when `SiteIdentityProbe` learns to read a
    /// name it previously couldn't.
    static let siteIdentityVersion = 1

    /// How many *hosts* to probe per pass. Hosts, not rows: five saves from one shop are
    /// one request.
    private static let identifyBatch = 3

    /// Works out what the site behind an unattributed save calls itself.
    ///
    /// A share from a brand nobody follows has no `brand`, and until now that meant it had
    /// no name either — the wall showed a photograph with no wordmark, the detail page was
    /// titled "Saved", and the one obvious thing to do with a label you have just discovered
    /// (follow it) was not offered anywhere. The app was not missing the information; it had
    /// the URL and declined to read it.
    ///
    /// So this is `BrandDiscovery`'s identity step, pointed at a save instead of at a brand:
    /// one homepage fetch per host, `og:site_name` then the `<title>` with its marketing
    /// tail removed, and the mark the site publishes alongside. Exactly the same code a
    /// followed brand's name comes from, which is the point — "Billionaire Boys Club" should
    /// not depend on whether you happened to add them.
    ///
    /// Stamped whatever happens, so a blog that announces nothing is asked once and then
    /// left alone. Runs after the inbox and after `repair`, because both of those can make
    /// this unnecessary: `attachBrands` may find a real brand, and a real brand outranks
    /// anything a site says about itself.
    @discardableResult
    static func identifySites(in context: ModelContext) async -> Int {
        let version = siteIdentityVersion
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.brand == nil && $0.siteIdentityVersion != version && !$0.saves.isEmpty }
        )
        descriptor.fetchLimit = 200

        let anonymous = (try? context.fetch(descriptor)) ?? []
        guard !anonymous.isEmpty else { return 0 }

        // Grouped by host before anything is fetched. A collection is routinely several
        // things from the same shop, and asking that shop who it is once per garment is
        // both slower and ruder than asking it once.
        var byHost: [String: [BrandUpdate]] = [:]
        for update in anonymous {
            guard let host = update.linkURL?.host() else {
                update.siteIdentityVersion = version
                continue
            }
            byHost[host, default: []].append(update)
        }

        var named = 0
        for (host, rows) in byHost.sorted(by: { $0.key < $1.key }).prefix(identifyBatch) {
            guard let origin = URL(string: "https://\(host)") else { continue }
            let identity = await SiteIdentityProbe.discover(at: origin)
            for row in rows {
                row.siteIdentityVersion = version
                if let name = identity.name { row.siteName = name }
                if let logo = identity.logoURL { row.siteLogoURLString = logo.absoluteString }
            }
            if identity.name != nil { named += rows.count }
            log.info("identified \(host, privacy: .public) as \(identity.name ?? "nothing", privacy: .public)")
        }

        try? context.save()
        return named
    }


    /// Gives shares that landed thin another chance: at the catalogue, and at a photograph.
    ///
    /// Two kinds of row, and the second is what this was missing. A share is enriched once,
    /// at import, and the inbox file is deleted immediately afterwards — so a link that found
    /// no catalogue record kept a title and a single Open Graph frame permanently; that is the
    /// version stamp's job, one more look per bump. But a share that landed with **no
    /// photograph at all** was stamped on that one look whatever went wrong, so one slow page
    /// or one turned-away request cost the save its picture for good. Those are retried on a
    /// widening schedule (`photoRetryAt`), and let go only when the page says it has none.
    ///
    /// Only `shared:` rows are candidates: a `shopify:` key means the catalogue already
    /// answered.
    @discardableResult
    static func repair(in context: ModelContext, now: Date = Date()) async -> Int {
        let version = enrichmentVersion
        var stale = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.enrichmentVersion != version && !$0.saves.isEmpty }
        )
        stale.fetchLimit = repairBatch * 4
        var due = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.photoRetryAt <= now && !$0.saves.isEmpty }
        )
        due.fetchLimit = repairBatch

        var seen = Set<String>()
        let candidates = (((try? context.fetch(due)) ?? []) + ((try? context.fetch(stale)) ?? []))
            .filter { $0.externalID.hasPrefix("shared:") && seen.insert($0.externalID).inserted }
            // Thin, or a Shopify product the catalogue did not answer for at import — read from
            // its page instead, it has sizes but not the `shopify:` identity that lands it on
            // the row a followed brand's feed already holds.
            .filter { update in
                update.variants.isEmpty || update.imageURLStrings.isEmpty
                    || (update.productExternalID == nil
                        && update.linkURL.flatMap(ShopifySource.productHandle(in:)) != nil)
            }
            .prefix(repairBatch)
        guard !candidates.isEmpty else { return 0 }

        var upgraded = 0
        for update in candidates {
            // Stamped whatever happens. A link whose storefront publishes no catalogue —
            // a regional subdomain, a blog, a resale listing — must not be re-fetched on
            // every foreground for the rest of its life; a missing photograph is retried by
            // its own schedule below, not by this.
            update.enrichmentVersion = version
            guard let link = update.linkURL else {
                update.photoRetryAt = .distantFuture
                continue
            }

            var outcome: PageOutcome = .read
            var found = await catalogProduct(for: link)
            if found == nil {
                let fetched = await ownReading(of: link, title: update.title)
                found = fetched.item
                outcome = fetched.outcome
            }
            if let found {
                apply(found, to: update)
                // The rest of what a catalogue record knows and Open Graph doesn't. Only ever
                // filling gaps: a title someone has been looking at for a month should not
                // change under them, but an empty summary or a missing product type is
                // strictly better filled in.
                if update.summary == nil { update.summary = found.summary }
                if update.productType == nil { update.productType = found.productType }
                if update.tags.isEmpty { update.tags = found.tags }
                update.refreshGender()
                upgraded += 1
                log.info("repaired \(link.absoluteString, privacy: .public): \(found.variants.count) variants, \(update.imageURLStrings.count) photos")
            }
            schedulePhotoRetry(for: update, after: outcome, now: now)
        }

        try? context.save()
        return upgraded
    }

    /// What the next look for a photograph is, given how this one went.
    private static func schedulePhotoRetry(for update: BrandUpdate, after outcome: PageOutcome, now: Date) {
        guard update.imageURLStrings.isEmpty else {
            update.photoRetryAt = .distantFuture
            return
        }
        switch outcome {
        case .read, .gone:
            // The page answered and has no picture, or the page is not there. Asking again
            // gets the same answer — the `.gone` half of `ImageTagger.load`'s rule.
            update.photoRetryAt = .distantFuture
            log.info("no photograph to be had for \(update.externalID, privacy: .public)")
        case .unavailable:
            let delays = photoRetryDelays
            if update.photoAttempts < delays.count {
                update.photoRetryAt = now.addingTimeInterval(delays[update.photoAttempts])
                update.photoAttempts += 1
            } else {
                update.photoRetryAt = .distantFuture
                log.info("gave up on a photograph for \(update.externalID, privacy: .public) after \(update.photoAttempts) tries")
            }
        }
    }

    // MARK: - Reading a share

    /// How asking the page went, in the two kinds that matter for asking again.
    enum PageOutcome {
        /// It answered — whether or not it had a photograph.
        case read
        /// A 4xx that is not a rate limit. The same answer next time.
        case gone
        /// Offline, a timeout, a 429, a 5xx. Temporary by definition.
        case unavailable
    }

    struct Reading {
        /// The catalogue's record (`shopify:` key), or the page's own (`shared:` key).
        var item: FetchedItem?
        var metadata: PageMetadata
        var outcome: PageOutcome
    }

    /// The best answer to "what is this", in order of how much it knows: the Shopify catalogue
    /// (sizes and live stock, and a key that lands on a row the app already holds), the page
    /// Safari had loaded, and the phone's own fetch of it.
    static func read(_ save: SharedSave) async -> Reading {
        let base = save.page?.url ?? save.url
        let metadata = save.page?.metadata(base: base) ?? PageMetadata()

        if let product = await catalogProduct(for: save.url) {
            return Reading(item: product, metadata: metadata, outcome: .read)
        }
        if let page = save.page {
            let item = pageItem(
                metadata: metadata,
                product: page.product(base: base),
                pictures: page.imageURLs,
                link: metadata.canonicalURL ?? save.url,
                title: save.title
            )
            // A page Safari drew with no picture anywhere on it is still worth one look of our
            // own; anything else it said is the better answer, because it is what was seen.
            if !item.imageURLStrings.isEmpty {
                return Reading(item: item, metadata: metadata, outcome: .read)
            }
        }
        let own = await ownReading(of: save.url, title: save.title)
        return Reading(item: own.item, metadata: own.metadata, outcome: own.outcome)
    }

    /// The phone's own fetch of a page: JSON-LD and Open Graph from one request.
    private static func ownReading(of url: URL, title: String?) async -> Reading {
        let fetched = await fetchPage(url)
        guard case .page(let html, let base) = fetched else {
            return Reading(item: nil, metadata: PageMetadata(), outcome: fetched.outcome)
        }
        let metadata = PageMetadataParser.parse(html, base: base)
        let item = pageItem(
            metadata: metadata,
            product: ProductPage.parse(html, base: base),
            pictures: [],
            link: metadata.canonicalURL ?? url,
            title: title
        )
        return Reading(item: item, metadata: metadata, outcome: .read)
    }

    /// A page's own description of itself, as the row it would become. Keyed `shared:` — only
    /// the catalogue's record is a product the poller would know.
    private static func pageItem(
        metadata: PageMetadata,
        product: ProductPage?,
        pictures: [String],
        link: URL,
        title: String?
    ) -> FetchedItem {
        var item = FetchedItem(
            externalID: "shared:\(link.absoluteString)",
            title: Self.title(candidates: [metadata.title, title], siteName: metadata.siteName, link: link),
            linkURL: link,
            imageURLStrings: metadata.imageURL.map { [$0.absoluteString] } ?? [],
            publishedAt: Date(),
            kind: .product,
            priceText: metadata.price,
            isAvailable: metadata.isAvailable
        )
        if let product { item = product.applied(to: item) }
        // The pictures the page drew, which a shop that builds its gallery with a script has
        // and its markup does not. Last, because they are the least certain to be the product.
        if item.imageURLStrings.isEmpty { item.imageURLStrings = Array(pictures.prefix(10)) }
        return item
    }

    private enum Fetched {
        case page(html: String, base: URL)
        case failed(PageOutcome)

        var outcome: PageOutcome {
            switch self {
            case .page: .read
            case .failed(let outcome): outcome
            }
        }
    }

    private static func fetchPage(_ url: URL) async -> Fetched {
        await answer(within: metadataTimeout, or: .failed(.unavailable)) {
            do {
                let response = try await Net.live.get(url)
                if response.status == 429 || response.status >= 500 { return .failed(.unavailable) }
                guard response.status == 200,
                      let html = String(data: response.data, encoding: .utf8)
                        ?? String(data: response.data, encoding: .isoLatin1)
                else { return .failed(.gone) }
                return .page(html: html, base: response.finalURL ?? url)
            } catch {
                return .failed(.unavailable)
            }
        }
    }

    /// The storefront's own record of the product, when the link is a Shopify product
    /// page. Worth trying first and by a distance: Open Graph gives a title, a picture and
    /// a price, while this gives the size run, the colourways and which of them are gone —
    /// which is the difference between a saved link and something you can put a watch on.
    private static func catalogProduct(for url: URL) async -> FetchedItem? {
        await answer(within: metadataTimeout, or: nil) { await ShopifySource.product(at: url) }
    }

    /// `work`'s answer, or `fallback` once `limit` has passed — **at the deadline, whether or
    /// not `work` listens.** These used to be task groups racing a sleep, and a task group
    /// cancels its children and then *waits for them*: a request that does not hear
    /// cancellation held the drain until its own timeout, so a share of a Kith product took
    /// 57 seconds to file against a twelve-second cap while the phone's own sync crowded the
    /// host. The work runs unstructured instead and is cancelled and left to finish on its own;
    /// the same conclusion the server's `withTimeout` reached for the embedding sidecar.
    private static func answer<T: Sendable>(
        within limit: Duration,
        or fallback: T,
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let once = FirstAnswer(continuation)
            let worker = Task { once.give(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                once.give(fallback)
                worker.cancel()
            }
        }
    }

    /// A continuation resumed by whichever answer arrives first. Main-actor bound, like
    /// everything here, so the two can never resume it together.
    private final class FirstAnswer<T> {
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func give(_ value: T) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    // MARK: - Filing

    /// Keeps the share. Separated from the fetch so it is synchronous, testable and easy to
    /// reason about.
    ///
    /// Returns the row and whether it is newly kept — false when the share was a duplicate
    /// of something already in the collection.
    @discardableResult
    static func importOne(
        _ save: SharedSave,
        reading: Reading,
        into context: ModelContext
    ) -> (update: BrandUpdate, isNew: Bool) {
        let item = reading.item
        let metadata = reading.metadata
        let isCatalogue = item.map { !$0.externalID.hasPrefix("shared:") } ?? false
        // The canonical URL is what dedupes: a share sheet hands over links carrying
        // whatever tracking parameters the referring app added, so the same product
        // shared twice arrives as two different URLs.
        let link = item?.linkURL ?? metadata.canonicalURL ?? save.url
        // A catalogue hit is keyed the way the poller keys it, so sharing something from a
        // brand the app already follows lands on the row that already exists instead of
        // minting a second card for the same product.
        let externalID = item?.externalID ?? "shared:\(link.absoluteString)"

        if let existing = existingRow(for: externalID, in: context) {
            // Already here. Re-sharing something is a request to keep it, not a
            // request for a duplicate card.
            if let item { apply(item, to: existing, isCatalogue: isCatalogue) }
            if existing.save == nil {
                context.insert(SavedItem(update: existing, type: .inspiration))
                UsageCounts.record(.saveAdded)
                return (existing, true)
            }
            return (existing, false)
        }

        let update = BrandUpdate(
            externalID: externalID,
            brand: matchingBrand(for: link, in: context),
            title: item?.title ?? title(candidates: [metadata.title, save.title], siteName: metadata.siteName, link: link),
            summary: item?.summary,
            linkURL: link,
            imageURLStrings: item?.imageURLStrings ?? metadata.imageURL.map { [$0.absoluteString] } ?? [],
            publishedAt: save.sharedAt,
            kind: .product,
            priceText: item?.priceText ?? metadata.price,
            priceAmount: item?.priceAmount,
            isAvailable: item?.isAvailable ?? metadata.isAvailable,
            tags: item?.tags ?? [],
            productType: item?.productType
        )
        update.variants = item?.variants ?? []
        update.productExternalID = isCatalogue ? item?.externalID : nil
        // Only a structured price says which currency it is in; Open Graph's price text is
        // printed as the page wrote it.
        update.currencyCode = item?.priceAmount != nil ? item?.currency : nil
        // Free: the page has already been read, and `og:site_name` is the brand's own name
        // for itself. `identifySites` improves on it later where it can (and is the only
        // source at all on the catalogue path, which reads no HTML), but a card should not be
        // anonymous for the minutes in between.
        if let declared = metadata.siteName, let tidied = BrandNaming.tidy(declared) {
            update.siteName = tidied
        }
        // With no photograph because the page did not answer, the first retry is a few minutes
        // off — the commonest reason is a request that did not get through this once, and the
        // repair pass right behind this drain would only ask the same page again at once. The
        // version is left at 0, so a share the catalogue did not answer gets the one repair
        // look it always had.
        if update.imageURLStrings.isEmpty, reading.outcome == .unavailable {
            update.photoRetryAt = Date().addingTimeInterval(firstPhotoRetry)
        }
        // Saved deliberately, so it is never "news" — it must not turn up in the feed
        // as an unread item the user has to dismiss.
        update.isSeen = true
        update.refreshGender()

        context.insert(update)
        context.insert(SavedItem(update: update, type: .inspiration, note: nil))
        UsageCounts.record(.saveAdded)
        return (update, true)
    }

    /// Files the save on the boards chosen in the sheet, creating any named there.
    ///
    /// A board deleted since the sheet was drawn is ignored — boards are filters, and a filter
    /// that no longer exists has nothing to file onto. A new board whose name matches one that
    /// exists (two shares typed "Tokyo" before the app ran) is that board rather than a second
    /// one; otherwise it is made the way every other screen makes one (`CollectionEdit.newBoard`).
    private static func file(_ update: BrandUpdate, as save: SharedSave, in context: ModelContext) {
        guard let item = update.save,
              !(save.boardIDs ?? []).isEmpty || !(save.newBoards ?? []).isEmpty
        else { return }
        var boards = (try? context.fetch(FetchDescriptor<Board>())) ?? []

        var targets = boards.filter { (save.boardIDs ?? []).contains($0.id) }
        for name in save.newBoards ?? [] {
            if let existing = boards.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                targets.append(existing)
            } else if let created = CollectionEdit.newBoard(named: name, after: boards, in: context) {
                boards.append(created)
                targets.append(created)
            }
        }
        for board in targets where !item.isFiled(on: board) {
            item.boards.append(board)
        }
    }

    /// The watches "Notify me" asked for — one per size chosen, or one for any size — set the
    /// way `WatchEditor` sets one. A watch already pinned the same way is not set twice, so
    /// re-draining a share is harmless. Nothing is set when the sheet asked for a size the
    /// page could not list: that is a question for `ask`.
    private static func setWatches(on update: BrandUpdate, from save: SharedSave, in context: ModelContext) -> [StockWatch] {
        guard let notify = save.notify, !notify.askSize else { return [] }
        let sizes: [String?] = notify.sizes.isEmpty ? [nil] : notify.sizes
        var made: [StockWatch] = []
        for size in sizes {
            let target = WatchTarget(size: size, color: notify.color)
            guard !update.activeWatches.contains(where: { $0.target == target }) else { continue }
            let watch = StockWatch(update: update, size: size, color: notify.color)
            context.insert(watch)
            made.append(watch)
        }
        return made
    }

    /// The one question a share may still raise, and whether it raised it. **One question,
    /// answered once**: a share that chose "Notify me" is never also asked whether to be told
    /// when it's back.
    @discardableResult
    private static func ask(
        about update: BrandUpdate,
        from save: SharedSave,
        questions: ShareQuestions,
        scope: ProfileScope
    ) -> Bool {
        if let notify = save.notify {
            guard notify.askSize, update.activeWatches.isEmpty else { return false }
            questions.ask(.pickSize, about: update.externalID, color: notify.color, for: scope)
            return true
        }
        // Only on an explicit "sold out": a page that declared nothing about stock must not be
        // guessed at, or the reward for saving something you could have bought is an
        // unprompted sheet.
        guard update.isAvailable == false, update.activeWatches.isEmpty else { return false }
        questions.ask(.soldOut, about: update.externalID, for: scope)
        return true
    }

    // MARK: - Rows

    private static func row(for externalID: String, in context: ModelContext) -> BrandUpdate? {
        var descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.externalID == externalID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The row this share is about, if the collection already holds one.
    ///
    /// Two keys, because there are two ways the same garment can already be here and only
    /// one of them was ever checked:
    ///
    /// - `externalID`, which matches a row the *local* poller wrote (`shopify:<id>`) or an
    ///   earlier share of the same link.
    /// - `productExternalID`, which matches a row the **server** wrote. A feed row is keyed
    ///   `event:<uuid>` and can never equal a catalogue key, so sharing something the app
    ///   was already showing you minted a second card for it — in the only mode the app
    ///   ships in.
    ///
    /// One product legitimately has several event rows — a drop, a markdown, a restock —
    /// so a product match can be ambiguous. A row that is already saved wins, because that
    /// is the one carrying somebody's note and board and the one they would expect to find
    /// again; otherwise the most recent, which is what the feed is currently showing.
    static func existingRow(for externalID: String, in context: ModelContext) -> BrandUpdate? {
        if let exact = row(for: externalID, in: context) { return exact }

        let descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { $0.productExternalID == externalID }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.first { !$0.saves.isEmpty }
            ?? candidates.max { $0.publishedAt < $1.publishedAt }
    }

    /// Refreshes a row we already hold with what the storefront says now. Sizes sell out
    /// between one share and the next, and a stale variant list is what a watch would be
    /// evaluated against.
    private static func apply(_ product: FetchedItem, to update: BrandUpdate, isCatalogue: Bool = true) {
        if !product.variants.isEmpty { update.variants = product.variants }
        // A row that reached the catalogue now knows which garment it is, so the next
        // share of it — or of the same product under a different link — finds it. This is
        // also how a `shared:` row repaired long after the fact becomes matchable. A page's
        // own reading is keyed `shared:` and names no catalogue product.
        if isCatalogue, !product.externalID.hasPrefix("shared:"), update.productExternalID == nil {
            update.productExternalID = product.externalID
        }
        // Upgraded, not merely filled. A share arrives with at most one photograph — the one
        // Open Graph publishes for link previews — while the catalogue record carries the
        // whole set: the back, the detail, the on-body shot. Keeping the single frame
        // because the field was technically non-empty left a gallery that said "1/1" about a
        // garment the app had eight pictures of. Only ever *more*, so a storefront that
        // publishes one is never talked down to zero.
        if product.imageURLStrings.count > update.imageURLStrings.count {
            update.imageURLStrings = product.imageURLStrings
        }
        update.isAvailable = product.isAvailable ?? update.isAvailable
        update.priceText = product.priceText ?? update.priceText
        update.priceAmount = product.priceAmount ?? update.priceAmount
        if product.priceAmount != nil, let currency = product.currency { update.currencyCode = currency }
    }

    /// Attaches the save to a brand already being watched, when it is the same brand.
    ///
    /// Matched on the *registrable domain*, not the hostname. Stripping `www.` and
    /// comparing what is left only works when the brand happens to be stored under the
    /// same host the link came from — and a brand is not one host. Palace answers on the
    /// apex, `www.`, `usa.` and `eu.`; the row holds whichever one it was added with, so
    /// a link from any of the other three matched nothing and the save arrived with no
    /// brand on it. On screen that is a card in the collection with no wordmark over it,
    /// a detail page with no brand in the title, and an item that contributes nothing to
    /// the brand facet of the style profile. Five of eleven saves in the test store were
    /// in exactly this state, all of them Palace.
    ///
    /// Deliberately does *not* create a brand for an unknown host: adding a link from
    /// some blog should not start watching that blog, and it would quietly fill the
    /// Brands tab with things the user never chose to follow. Following is a choice the
    /// share sheet offers on a shop's page (`ShareFollows`), never a side effect of saving.
    private static func matchingBrand(for link: URL, in context: ModelContext) -> Brand? {
        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        return brands.first { BrandDiscovery.isSameBrandHost(link, $0.websiteURL) }
    }

    /// Best available name, in descending order of how much it was written *for* this
    /// page. Falls back to the host so a card is never blank.
    private static func title(candidates: [String?], siteName: String?, link: URL) -> String {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return cleaned(candidate, siteName: siteName)
            }
        }
        return link.host() ?? link.absoluteString
    }

    /// Storefront titles are usually "Product Name | Kith" or "Product Name – Kith".
    /// The brand is already on the card, so the suffix is noise. Compared without case:
    /// Intimissimi calls itself "intimissimi" and signs its titles "Intimissimi".
    private static func cleaned(_ title: String, siteName: String?) -> String {
        guard let siteName, !siteName.isEmpty else { return title }
        for separator in [" | ", " – ", " — ", " - "] {
            let suffix = "\(separator)\(siteName)"
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                return String(title.dropLast(suffix.count))
            }
        }
        return title
    }
}
