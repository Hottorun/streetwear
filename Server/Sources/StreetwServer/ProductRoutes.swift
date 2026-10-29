// ProductRoutes.swift
// Searching the catalogue, and "more like this". See `ProductSearch`.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension ProductSearchResponse: @retroactive Content {}
extension SimilarProductsResponse: @retroactive Content {}

func productRoutes(authed: any RoutesBuilder) {
    /// `?q=` as typed into Shop's field; `?scope=followed|all` (the caller's shops by
    /// default); `?cheaper=`, `?formal=`, `?inMySize=` for the chips, which set the same flags
    /// the words do; `?limit=` and `?cursor=` to page the exact matches.
    ///
    /// Phase 5, both optional and both absent from 1.2 and 1.3, which therefore get exactly
    /// what they always got: `?boost=standard|more` makes `scope=all` the one list in which the
    /// caller's own shops are lifted, and `?meaning=true` lets a product close to the query by
    /// meaning be a result without its words.
    ///
    /// For the profile the request acts for: its follows, its sizes, its gender filter, and
    /// the shop serving its account's country.
    authed.get("products", "search") { req async throws -> ProductSearchResponse in
        let user = try await req.actingUser()
        let ask = ProductSearch.Ask(
            text: (try? req.query.get(String.self, at: "q")) ?? "",
            scope: ProductSearchScope(query: try? req.query.get(String.self, at: "scope")),
            cheaper: (try? req.query.get(Bool.self, at: "cheaper")) ?? false,
            formal: (try? req.query.get(Bool.self, at: "formal")) ?? false,
            inMySize: (try? req.query.get(Bool.self, at: "inMySize")) ?? false,
            limit: (try? req.query.get(Int.self, at: "limit")) ?? ProductSearch.defaultLimit,
            // Opaque on the wire, for the reason `DiscoverResponse.nextCursor` is; an offset
            // into one query's ranking underneath.
            offset: (try? req.query.get(String.self, at: "cursor")).flatMap(Int.init) ?? 0,
            boost: (try? req.query.get(String.self, at: "boost")).map { FollowedBoost(query: $0) },
            meaning: (try? req.query.get(Bool.self, at: "meaning")) ?? false
        )
        // A sentence, not an essay: the grammar reads a few words and the index is asked one
        // condition per word.
        guard ask.text.count <= 200 else { throw Abort(.badRequest, reason: "A search is at most 200 characters.") }
        return try await ProductSearch.run(ask, for: user, app: req.application, on: req.db)
    }

    /// Products like one product, from the caller's shops (`?scope=all` for every shop).
    ///
    /// `:productID` is the product's id, or — because that is what the phone holds — its
    /// external id (`shopify:123`) with `?brand=`, read in the shop that serves the caller.
    authed.get("products", ":productID", "similar") { req async throws -> SimilarProductsResponse in
        let user = try await req.actingUser()
        guard let raw = req.parameters.get("productID") else { throw Abort(.badRequest) }

        let subject: ProductModel?
        if let id = UUID(uuidString: raw) {
            subject = try await ProductModel.find(id, on: req.db)
        } else {
            guard let brandID = try? req.query.get(UUID.self, at: "brand") else {
                throw Abort(.badRequest, reason: "An external id needs ?brand=.")
            }
            let serving = try await Storefronts.serving(
                country: user.country,
                enabled: req.application.storefrontCountries,
                brandIDs: [brandID],
                on: req.db
            )
            subject = try await ProductModel.query(on: req.db)
                .filter(\.$brand.$id == brandID)
                .filter(\.$externalID == raw)
                .filter(\.$storefrontID == serving[brandID]?.id)
                .first()
        }
        guard let subject else { throw Abort(.notFound, reason: "No such product.") }

        return try await ProductSearch.similar(
            to: subject,
            scope: ProductSearchScope(query: try? req.query.get(String.self, at: "scope")),
            limit: (try? req.query.get(Int.self, at: "limit")) ?? ProductSearch.similarLimit,
            for: user,
            app: req.application,
            on: req.db
        )
    }
}
