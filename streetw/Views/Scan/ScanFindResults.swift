// ScanFindResults.swift
// "Find this or something like it": what the server says looks like the photograph, or a
// search for the scan's own words.
//
// **`similar` first, when it came back** — the server compared the photograph itself with every
// product's photograph (`similarBasis` `photograph`, Phase 5), or, where it could not, the
// reading's words with their text (`description`); the line above the grid says which.
// Otherwise the reading's `searchText` is searched exactly as Shop's field searches it — the
// one list over every shop the server watches, your own shops lifted — and the line says where.
// The search is free: the reading was what was paid for. A search that failed says it failed.

import StreetwCore
import SwiftData
import SwiftUI

struct ScanFindResults: View {
    @Environment(\.modelContext) private var context
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(ProfileStore.self) private var profiles: ProfileStore
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    let searchText: String
    let similar: [DiscoverCard]?
    /// `AIScanResponse.similarBasis`; nil from a server that predates it, which matched words.
    var similarBasis: String?

    private enum Answer {
        case loading
        case found(cards: [(card: DiscoverCard, matched: [String]?)], label: String)
        case none(String)
        case failed
    }

    @State private var answer: Answer = .loading
    @State private var viewing: DiscoverCard?
    /// Bumped by "try again", so the search is asked afresh.
    @State private var attempt = 0

    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    /// What is already kept, by product, so a tile's bookmark is filled for it — the rule
    /// `ShopView.savedKeys` follows.
    private var savedKeys: Set<String> {
        var keys: Set<String> = []
        for update in saves.compactMap(\.update) {
            keys.insert(update.externalID)
            if let product = update.productExternalID { keys.insert(product) }
        }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch answer {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    NoteLine(text: "Looking…")
                }
                .padding(.horizontal, 20)
            case .found(let cards, let label):
                NoteLine(text: label, color: .ink)
                    .padding(.horizontal, 20)
                let saved = savedKeys
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(cards, id: \.card.productExternalID) { entry in
                        ShopCardTile(
                            card: entry.card,
                            matched: entry.matched,
                            isSaved: saved.contains(entry.card.productExternalID),
                            onSave: { DiscoverSave.save(entry.card, in: context) },
                            onOpen: { viewing = entry.card }
                        )
                    }
                }
                .padding(.horizontal, 16)
            case .none(let line):
                Text(line)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    Text("The search didn't go through, so this isn't a “nothing found”.")
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { attempt += 1 }
                        .font(.data(12, .semibold))
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 20)
        .task(id: attempt) { await find() }
        .sheet(item: $viewing) { card in
            DiscoverProductSheet(
                card: card,
                isSaved: savedKeys.contains(card.productExternalID),
                onSave: { DiscoverSave.save(card, in: context) }
            )
        }
    }

    private func find() async {
        if let similar, !similar.isEmpty {
            answer = .found(cards: similar.map { (card: $0, matched: nil) }, label: Self.similarLabel(similar.count, basis: similarBasis))
            return
        }
        guard let baseURL = settings.baseURL else {
            answer = .failed
            return
        }
        answer = .loading
        let api = StreetwAPI(baseURL: baseURL, token: settings.token, profileID: profiles.session.scope.id)
        do {
            let response = try await api.searchProducts(
                searchText, scope: .all, cheaper: false, formal: false, inMySize: false,
                boost: .standard, meaning: true
            )
            let hits = response.exact + response.partial
            guard !hits.isEmpty else {
                answer = .none("Nothing in the shops Dropwall watches matches “\(searchText)”.")
                return
            }
            // From the answer's own scope, never from what was asked.
            let place = response.scope == .followed ? "in your shops" : "in every shop we watch"
            answer = .found(
                cards: hits.map { (card: $0.card, matched: $0.byMeaning == true ? nil : $0.matched) },
                label: "“\(searchText)” \(place)."
            )
        } catch {
            answer = .failed
        }
    }

    /// What `similar` was compared by, said above it.
    static func similarLabel(_ count: Int, basis: String?) -> String {
        let products = count == 1 ? "One product" : "\(count) products"
        switch basis {
        case "photograph": return count == 1 ? "One product looks like your photograph." : "\(products) look like your photograph."
        case "description": return "\(products) like its description."
        default: return count == 1 ? "One product looks like it." : "\(count) products look like it."
        }
    }
}

/// The results on their own page — from a garment of your own, where "find it" is asked long
/// after the scan.
struct ScanFindSheet: View {
    @Environment(\.dismiss) private var dismiss

    let searchText: String
    let similar: [DiscoverCard]?
    var similarBasis: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                ScanFindResults(searchText: searchText, similar: similar, similarBasis: similarBasis)
                    .padding(.top, 12)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Like it")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.data(13, .semibold))
                }
            }
        }
        .tint(.ink)
    }
}
