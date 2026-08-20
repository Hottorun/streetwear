// HTMLEntities.swift
// Turning what a storefront wrote into what a person reads.
//
// Two files were decoding entities with a hand-written table apiece — `PageMetadataParser`
// for a shared link's title and price, `BrandNaming` for a `<title>` — and both tables held
// only the handful of *named* entities somebody had happened to hit. That is the wrong
// shape for the problem: the named set is open-ended and the numeric set is infinite, so a
// table can only ever be a list of the bugs already found.
//
// The one that got through: GV Gallery writes its Open Graph price as `&#036;190.00`, so a
// saved item was captioned with the markup instead of a price. `&#036;` is a dollar sign
// written the long way — with a leading zero, which even a table of `&#36;` would have
// missed. Numeric references are decoded arithmetically here, decimal and hex, and the
// named table is kept for the ones that have no number.
//
// Shared rather than duplicated for the reason every other shared thing in this package is:
// two copies drift, and the symptom is a title that decodes on one screen and not the next.

import Foundation

public enum HTMLEntities {
    /// Decodes every entity reference in `raw`, leaving anything unrecognised alone.
    ///
    /// Unrecognised text is passed through rather than stripped. A bare `&` is legal in
    /// plenty of real markup and `&foo;` is more likely a product name than an entity, so
    /// deleting what we cannot read would lose real characters to guard against ugly ones.
    public static func decode(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }

        var out = ""
        out.reserveCapacity(raw.count)

        var rest = Substring(raw)
        while let start = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<start]
            rest = rest[start...]

            // An entity is at most a few characters; scanning further than that means
            // this `&` was never the start of one.
            guard let end = rest.dropFirst().prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = rest.dropFirst()
                continue
            }

            let body = rest[rest.index(after: rest.startIndex)..<end]
            if let character = character(for: body) {
                out.append(character)
                rest = rest[rest.index(after: end)...]
            } else {
                out.append("&")
                rest = rest.dropFirst()
            }
        }
        out += rest
        return out
    }

    /// The part between `&` and `;`, resolved.
    private static func character(for body: Substring) -> Character? {
        guard !body.isEmpty else { return nil }

        if body.first == "#" {
            let digits = body.dropFirst()
            // Leading zeros are legal and common — `&#036;` is what put markup into a
            // price caption — so this parses rather than matching a literal.
            let scalar: UInt32?
            if digits.first == "x" || digits.first == "X" {
                scalar = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(digits, radix: 10)
            }
            return scalar.flatMap(Unicode.Scalar.init).map(Character.init)
        }

        return named[String(body)] ?? named[body.lowercased()]
    }

    /// The named references that turn up in storefront markup. Short on purpose: anything
    /// exotic is written as a number in practice, and numbers are handled above.
    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ndash": "–", "mdash": "—",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "hellip": "…", "middot": "·", "bull": "•",
        "trade": "™", "reg": "®", "copy": "©", "deg": "°",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½",
        "laquo": "«", "raquo": "»", "shy": "\u{00AD}", "ensp": " ", "emsp": " ",
        "thinsp": "\u{2009}"
    ]
}
