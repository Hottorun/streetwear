// ShareContextWriter.swift
// What the share sheet is told about the store a share will land in.
//
// The extension opens no store, so it cannot see boards, sizes or follows — and it needs all
// three: board chips to file on, the profile's sizes to pre-select a watch, and the shops
// followed to say "you follow it" and whether a markdown will be said. The app writes them
// into the App Group, one small file per store (`SharedInbox.writeContext`), and the sheet
// reads the current store's.
//
// **Written whenever the app leaves the foreground, at a profile switch, and after a drain** —
// not from every place that edits a board. On iPhone the share sheet can only be opened from
// another app, so the app has always just left the foreground when it is; and the four screens
// that create, rename and delete boards would each need to remember a call. The write is a
// fetch of boards and brands and nothing when unchanged. The first share after installing this
// build, before the app has ever run it, sees no boards — and still saves.

import Foundation
import StreetwCore
import SwiftData

@MainActor
enum ShareContextWriter {
    static func publish(_ session: ProfileSession) {
        let context = session.container.mainContext

        let boards = ((try? context.fetch(FetchDescriptor<Board>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { SharedContext.Board(id: $0.id, name: $0.name) }

        let followed = (try? context.fetch(FetchDescriptor<Brand>(predicate: #Predicate { $0.followed }))) ?? []
        let domains = Set(followed.flatMap { brand in
            [brand.websiteURL, brand.shopURL].compactMap { $0?.host() }.map { BrandDiscovery.registrableDomain(of: $0) }
        })

        SharedInbox.writeContext(
            SharedContext(
                boards: boards,
                sizes: session.sizes.profile,
                followedDomains: domains.sorted(),
                savedPriceDropAlerts: PriceAlerts.isEnabled
            ),
            for: session.scope.home
        )
    }
}
