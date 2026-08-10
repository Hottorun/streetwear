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
                    environment: "sandbox",
                    locale: Locale.current.identifier,
                    sizes: SizePayload(sizes)
                )
            )
            settings.token = response.token
        } else {
            try await api?.updateDevice(UpdateDevice(sizes: SizePayload(sizes)))
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
            try? context.save()
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
            } else {
                let brand = Brand(
                    name: dto.name,
                    websiteURL: dto.website.flatMap(URL.init(string:)),
                    instagramHandle: dto.instagramHandle
                )
                brand.remoteID = id
                brand.currencyCode = dto.currency
                brand.isLockedForDrop = dto.lockedForDrop
                context.insert(brand)
                byRemoteID[id] = brand
            }
        }

        // A brand unfollowed on another device should disappear here too. Local-only
        // brands (no remoteID) are left alone so standalone mode still works.
        let remoteIDs = Set(remote.compactMap(\.id))
        for brand in existing {
            if let id = brand.remoteID, !remoteIDs.contains(id) {
                context.delete(brand)
            }
        }
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
        let existingIDs = Set(
            ((try? context.fetch(FetchDescriptor<BrandUpdate>())) ?? []).map(\.externalID)
        )

        for item in items {
            let externalID = "event:\(item.eventID.uuidString)"
            guard !existingIDs.contains(externalID) else { continue }
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
                isAvailable: item.isAvailable
            )
            update.restockedSizes = item.restockedSizes
            // The server already matched against this device's profile; keep its answer
            // so the badge doesn't need every variant shipped down.
            update.serverSaysInMySize = item.availableInMySize
            context.insert(update)
            newItemCount += 1
        }
    }
}
