// ProductPhotoReading.swift
// What the server reads off a product's photographs once (Phase 5): which photograph is the
// clean product shot, and a few style words. The vocabulary and the wire are here because both
// ends read them — the server writes the words, the search grammar matches them on both ends,
// and the phone stores them beside the row.
//
// See `docs/server.md` (*The product photograph and style words*) for how they are read, and
// `docs/collection.md` (*The cover*) for what the phone does with the shot.

import Foundation

/// The fixed vocabulary of style words a product can be given.
///
/// **Fixed, small and single words**, on purpose. A word here is something a search can match
/// ("workwear jacket"), so it must be one token the grammar reads whole; and every word is one
/// more thing the reading can be wrong about, so the list holds only styles somebody shopping
/// these shops would type. A reading can only ever answer from this list — the zero-shot reader
/// compares against these and nothing else, and a model's answer is filtered through it — so a
/// word added here is a word no stored product carries until the reading's version is bumped.
public enum StyleWords {
    public static let vocabulary: [String] = [
        "workwear", "minimal", "preppy", "streetwear", "tailoring", "y2k", "sporty", "outdoor",
        "romantic", "vintage", "skate", "western", "boho", "grunge", "graphic",
    ]

    /// At most this many words per product: more is a list of guesses, and the eval measured
    /// precision falling with each one added (`docs/server.md`).
    public static let maximum = 2

    /// `words` kept to the vocabulary, lowercased, in order, without repeats, at most `maximum`.
    public static func clean(_ words: [String]) -> [String] {
        var out: [String] = []
        for word in words {
            let lowered = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard vocabulary.contains(lowered), !out.contains(lowered) else { continue }
            out.append(lowered)
            if out.count == maximum { break }
        }
        return out
    }
}

/// The product shot as a photograph rather than a position: the URL at `index`, when there is one.
public enum ProductShotIndex {
    public static func url(in imageURLs: [String], at index: Int?) -> String? {
        guard let index, imageURLs.indices.contains(index) else { return nil }
        return imageURLs[index]
    }
}

/// `POST /v1/products/readings`: the server's reading for products the phone already holds.
///
/// A feed row is sent once, usually before the server has read the product's photographs —
/// the reading runs behind the embedding backfill, minutes after a poll — and the merge never
/// revisits a row it holds. So without this, a save would only ever learn its product shot if it
/// had been saved from Discover or a search. The phone asks for its saves, a few dozen at a time.
public struct ProductReadingsRequest: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Hashable {
        /// Nil for a save from a brand the phone does not follow, which it holds with no brand
        /// row: the external id alone is then the key, and a catalogue key is the shop's own.
        public var brandID: UUID?
        /// The product's key as the phone holds it — `shopify:<id>`.
        public var externalID: String

        public init(brandID: UUID?, externalID: String) {
            self.brandID = brandID
            self.externalID = externalID
        }
    }

    public var items: [Item]

    /// The most items one request may name.
    public static let limit = 100

    public init(items: [Item]) {
        self.items = items
    }
}

public struct ProductReadingsResponse: Codable, Sendable, Equatable {
    public struct Reading: Codable, Sendable, Hashable {
        /// As asked.
        public var brandID: UUID?
        public var externalID: String
        /// The clean product shot as its URL — not an index, because the phone's row may hold an
        /// older gallery than the server's, and a URL that is not in it is simply not used.
        public var productShotURL: String?
        public var styleWords: [String]

        public init(brandID: UUID?, externalID: String, productShotURL: String?, styleWords: [String]) {
            self.brandID = brandID
            self.externalID = externalID
            self.productShotURL = productShotURL
            self.styleWords = styleWords
        }
    }

    /// Only products the server has read. One it has not is left out, and asked about again.
    public var readings: [Reading]

    public init(readings: [Reading]) {
        self.readings = readings
    }
}
