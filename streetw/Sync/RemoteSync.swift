// RemoteSync.swift
// Fills the local store from the server instead of fetching sources on the phone.
//
// The local SwiftData model stays exactly as it was — this only changes where rows come
// from. That means the whole UI, saving, style profile and size filtering keep working
// unchanged whether the app is in server mode or standalone mode.

import Foundation
import StreetwCore
import SwiftData

@MainActor
@Observable
final class RemoteSync {
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?
    private(set) var newItemCount = 0

    private let context: ModelContext
    private let settings: ServerSettings

    /// Cursor of the newest event already merged. Kept out of the model store because it
    /// belongs to the *connection*, not to the data.
    private var cursor: Date? {
        get { UserDefaults.standard.object(forKey: "feedCursor") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "feedCursor") }
    }

    init(context: ModelContext, settings: ServerSettings) {
        self.context = context
        self.settings = settings
    }

    private var api: StreetwAPI? {
        guard let baseURL = settings.baseURL else { return nil }
        return StreetwAPI(baseURL: baseURL, token: settings.token)
    }

    // MARK: - Registration

    /// Registers this device if it hasn't been already, and pushes the current sizes so
    /// the server can target restock alerts.
    func ensureRegistered(sizes: SizeProfile) async throws {
        guard let baseURL = settings.baseURL else { throw APIError.notConfigured }

        if settings.token == nil {
            let anonymous = StreetwAPI(baseURL: baseURL, token: nil)
            let response = try await anonymous.register(
                RegisterDevice(
                    environment: BackgroundServices.apnsEnvironment,
                    locale: Locale.current.identifier,
                    sizes: SizePayload(sizes)
                )
            )
            settings.token = response.token
        } else {
            try await api?.updateDevice(UpdateDevice(sizes: SizePayload(sizes)))
        }
    }

    /// Hands APNs' device token to the server, which is what turns this install from a
    /// puller into something that can be told.
    ///
    /// The environment goes up with it: the same install produces a sandbox token from a
    /// debug build and a production one from TestFlight, and sending to the wrong host is
    /// a silent no-delivery rather than an error.
    func pushDeviceToken(_ token: String) async {
        guard settings.isRegistered, let api else { return }
        do {
            try await api.updateDevice(
                UpdateDevice(apnsToken: token, environment: BackgroundServices.apnsEnvironment)
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pushSizes(_ sizes: SizeProfile) async {
        guard settings.isRegistered, let api else { return }
        do {
            try await api.updateDevice(UpdateDevice(sizes: SizePayload(sizes)))
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Brands

    func addBrand(url: String, name: String?, instagram: String?, sizes: SizeProfile) async throws -> BrandDTO {
        try await ensureRegistered(sizes: sizes)
        guard let api else { throw APIError.notConfigured }

        let brand = try await api.discover(DiscoverBrand(url: url, name: name, instagram: instagram))
        if let id = brand.id {
            try await api.follow(brandID: id)
        }
        return brand
    }

    /// Dry run via the server, so the phone never fetches storefronts itself.
    func probe(url: String) async throws -> BrandProbe {
        guard let api else { throw APIError.notConfigured }
        return try await api.probe(url: url)
    }

    func searchBrands(_ query: String) async throws -> [BrandDTO] {
        guard let api else { throw APIError.notConfigured }
        return try await api.searchBrands(query)
    }

    func popularBrands(limit: Int = 12) async throws -> [PopularBrand] {
        guard let api else { throw APIError.notConfigured }
        return try await api.popularBrands(limit: limit)
    }

    /// Follows a brand the catalog already has, and pulls it straight into the local
    /// store so the UI reflects it without waiting for a full sync.
    func followExisting(_ dto: BrandDTO, sizes: SizeProfile) async throws {
        try await ensureRegistered(sizes: sizes)
        guard let api, let id = dto.id else { throw APIError.notConfigured }
        try await api.follow(brandID: id)
        mergeBrands([dto])
        try? context.save()
    }

    func follow(brandID: UUID) async throws {
        guard let api else { throw APIError.notConfigured }
        try await api.follow(brandID: brandID)
    }

    func unfollow(_ brand: Brand) async {
        guard let remoteID = brand.remoteID, let api else { return }
        do {
            try await api.unfollow(brandID: remoteID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Watches

    /// Mirrors a local watch onto the server, which is what lets it fire while the app is
    /// closed. Failure is survivable: the local watch still fires on the next sync, so
    /// this reports rather than throws.
    func createWatch(_ watch: StockWatch) async {
        guard settings.isConfigured,
              let api,
              let brandID = watch.update?.brand?.remoteID,
              let externalID = watch.update?.externalID
        else { return }

        do {
            let created = try await api.createWatch(
                CreateWatch(
                    brandID: brandID,
                    productExternalID: externalID,
                    size: watch.size,
                    color: watch.color
                )
            )
            watch.remoteID = created.id
            try? context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteWatch(_ watch: StockWatch) async {
        guard let remoteID = watch.remoteID, let api else { return }
        do {
            try await api.deleteWatch(id: remoteID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pulls the server's verdict on every watch and marks the fired ones locally, so a
    /// restock that happened while the app was closed is reflected rather than waiting
    /// for the phone to observe the transition itself.
    private func mergeWatches() async {
        guard let api, let remote = try? await api.watches() else { return }

        let byID = Dictionary(
            remote.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let local = (try? context.fetch(FetchDescriptor<StockWatch>())) ?? []

        for watch in local {
            guard let id = watch.remoteID, let dto = byID[id] else { continue }
            guard watch.firedAt == nil, let firedAt = dto.firedAt else { continue }
            watch.firedAt = firedAt
            watch.firedSizes = dto.firedSizes
        }
    }

    // MARK: - Sync

    func sync(sizes: SizeProfile) async {
        guard !isSyncing, settings.isConfigured else { return }
        isSyncing = true
        lastError = nil
        newItemCount = 0
        defer {
            isSyncing = false
            lastSyncedAt = Date()
        }

        do {
            try await ensureRegistered(sizes: sizes)
            guard let api else { return }

            let brands = try await api.follows()
            mergeBrands(brands)

            // First sync pulls a week; afterwards only what's new since the cursor.
            let response = try await api.feed(since: cursor)
            merge(response.items)

            // Only advance once the merge succeeded, so a failure re-fetches rather
            // than silently skipping a window of events.
            if let next = response.nextCursor {
                cursor = next
            }
            await mergeWatches()
            try? context.save()

            // Also checked locally, not only trusted from the server: the app has the
            // variant data in hand and a push can be missed, denied or throttled. Firing
            // is edge-triggered, so the two paths can't produce two alerts.
            await WatchNotifier.run(in: context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Merging

    private func mergeBrands(_ remote: [BrandDTO]) {
        let existing = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        var byRemoteID = Dictionary(
            existing.compactMap { brand in brand.remoteID.map { ($0, brand) } },
            uniquingKeysWith: { first, _ in first }
        )

        for dto in remote {
            guard let id = dto.id else { continue }
            if let brand = byRemoteID[id] {
                brand.name = dto.name
                brand.currencyCode = dto.currency
                brand.isLockedForDrop = dto.lockedForDrop
                if let logo = dto.logoURL { brand.logoURLString = logo }
                brand.sources = dto.sources.map(Self.source(from:))
            } else {
                let brand = Brand(
                    name: dto.name,
                    websiteURL: dto.website.flatMap(URL.init(string:)),
                    instagramHandle: dto.instagramHandle
                )
                brand.remoteID = id
                brand.currencyCode = dto.currency
                brand.isLockedForDrop = dto.lockedForDrop
                brand.logoURLString = dto.logoURL
                brand.sources = dto.sources.map(Self.source(from:))
                context.insert(brand)
                byRemoteID[id] = brand
            }
        }

        // Whole-array assignment above, never a mutation of one element: `Brand.sources`
        // is a Codable array on a `@Model`, so writing through to a member does not
        // persist.

        // A brand unfollowed on another device should disappear here too. Local-only
        // brands (no remoteID) are left alone so standalone mode still works.
        let remoteIDs = Set(remote.compactMap(\.id))
        for brand in existing {
            if let id = brand.remoteID, !remoteIDs.contains(id) {
                context.delete(brand)
            }
        }
    }

    /// The server's view of a source, in the shape the app already stores.
    ///
    /// `fingerprint` and `etag` stay nil and that is correct: they are the *poller's*
    /// state, and in server mode the phone is not the poller. They fill themselves in if
    /// this store is ever run under `-standalone YES`, where the first poll of each source
    /// establishes them.
    ///
    /// An unrecognised `kind` becomes `.page` rather than being dropped, so a brand watched
    /// by something this build has never heard of still reports that it is watched at all.
    private static func source(from dto: BrandSourceDTO) -> BrandSource {
        BrandSource(
            id: dto.id,
            kind: dto.sourceKind ?? .page,
            url: URL(string: dto.url) ?? URL(string: "https://invalid.invalid")!,
            enabled: dto.enabled,
            lastCheckedAt: dto.lastCheckedAt,
            lastError: dto.lastError,
            failureCount: dto.failureCount
        )
    }

    private func merge(_ items: [FeedItem]) {
        guard !items.isEmpty else { return }

        let brands = (try? context.fetch(FetchDescriptor<Brand>())) ?? []
        let byRemoteID = Dictionary(
            brands.compactMap { brand in brand.remoteID.map { ($0, brand) } },
            uniquingKeysWith: { first, _ in first }
        )

        // One row per event. The server already decided what is worth surfacing, so the
        // client does no diffing of its own.
        //
        // Fetching only the ids we are about to check, rather than every `BrandUpdate` in
        // the store. The old version loaded and faulted in the entire table — thousands of
        // rows after a few weeks — on every sync, to test membership of at most 200.
        let incoming = items.map { "event:\($0.eventID.uuidString)" }
        let descriptor = FetchDescriptor<BrandUpdate>(
            predicate: #Predicate { incoming.contains($0.externalID) }
        )
        let held = Dictionary(
            ((try? context.fetch(descriptor)) ?? []).map { ($0.externalID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for item in items {
            let externalID = "event:\(item.eventID.uuidString)"
            if let existing = held[externalID] {
                backfill(existing, from: item)
                continue
            }
            guard let brand = byRemoteID[item.brandID] else { continue }

            let update = BrandUpdate(
                externalID: externalID,
                brand: brand,
                title: item.title,
                summary: item.summary,
                linkURL: item.linkURL.flatMap(URL.init(string:)),
                imageURLStrings: item.imageURLs,
                publishedAt: item.createdAt,
                kind: item.updateKind,
                priceText: item.priceText,
                isAvailable: item.isAvailable,
                tags: item.tags ?? [],
                productType: item.productType
            )
            update.restockedSizes = item.restockedSizes
            // What it was marked down from. Without this a server-backed markdown could
            // say "cheaper" and nothing else — no "was", and no way to rank one cut
            // against another, which is the whole ordering of the markdowns list.
            update.previousPriceText = item.previousPriceText
            update.previousPriceAmount = item.previousPriceAmount
            // What the garment is, beside what happened to it — so a link shared from
            // Safari can find the card the feed already drew for the same product.
            update.productExternalID = item.productExternalID
            // The server already matched against this device's profile. Kept as a
            // fallback for items that genuinely have no variants — a collection
            // announcement, a page change — where the local check can't answer.
            update.serverSaysInMySize = item.availableInMySize
            // Variants are what make the size run print, the "my size" filter mean
            // anything, and colourways exist at all. A server that predates the field
            // sends nil, and the app degrades exactly as it did before rather than
            // storing an empty list that reads as "no sizes".
            update.variants = item.variants ?? []
            context.insert(update)

            if let gender = item.gender {
                update.genderRaw = gender
                // The server's revision, not ours. Claiming ours froze the verdict
                // forever the moment the phone shipped a better classifier than the
                // deployment — `gender` only re-derives on a version *mismatch*, so
                // stamping the local number is a promise that this build produced the
                // answer. A server that doesn't say reads as revision 0, which is stale
                // by definition and re-derived on first read.
                update.genderVersion = item.genderVersion ?? 0
            } else {
                // A server that predates the field sends nothing, and a nil gender reads
                // as `.unknown`, which no filter hides — so a "menswear only" feed would
                // quietly show everything. Classifying locally recovers the answer from
                // the title, the URL handle and — since the feed now carries them — the
                // product type and tags, without waiting on a deploy.
                update.refreshGender()
            }
            newItemCount += 1
        }
    }

    /// Fills in classification text on a row this device already holds.
    ///
    /// Rows written before the feed carried `productType` and `tags` hold neither, and a
    /// gender stamped by an older revision therefore re-derives from a title alone —
    /// which for a brand that files its womenswear as `product_type: "For Her"` and names
    /// its products `W2156` can only ever answer "unknown". Unknown is never filtered, so
    /// every one of those reappeared in a menswear feed. They cannot heal on their own:
    /// the merge below skips ids it already has, so without this they keep that answer
    /// until they age out of the feed window.
    ///
    /// Only ever adds. It does not touch `isSeen`, the save, or anything the person did —
    /// this is the same event, better described, not a new one.
    private func backfill(_ update: BrandUpdate, from item: FeedItem) {
        var changed = false
        if update.productType == nil, let productType = item.productType {
            update.productType = productType
            changed = true
        }
        if update.tags.isEmpty, let tags = item.tags, !tags.isEmpty {
            update.tags = tags
            changed = true
        }
        // The same trap as `productType`, and a louder one. A row stored before the feed
        // carried variants holds none, and the merge above skips ids it already has — so
        // it keeps none for as long as it exists. With no variants there is no size run,
        // no colourways and no watchable size: the two things a product page is *for* are
        // simply absent, on exactly the brands somebody has followed longest. Filled only
        // when empty, never overwritten: an event is a record of what happened, and the
        // stock in it is what was true when it fired.
        if update.variants.isEmpty, let variants = item.variants, !variants.isEmpty {
            update.variants = variants
            changed = true
        }
        // Without this the dedupe only ever works for rows written after the field
        // shipped, and everything already in the feed stays un-matchable by a share.
        if update.productExternalID == nil, let productID = item.productExternalID {
            update.productExternalID = productID
            changed = true
        }
        guard changed else { return }
        if let gender = item.gender {
            update.genderRaw = gender
            update.genderVersion = item.genderVersion ?? 0
        } else {
            update.refreshGender()
        }
    }
}
