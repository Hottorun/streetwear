// Region.swift
// The two codes a storefront is described by — where it sells and what it charges in — and
// how a price is written for whoever is reading it.
//
// Deliberately free of `Locale`'s region APIs. Which country a phone is in is the app's
// question (`LocationSetting`), and swift-corelibs-foundation answers it differently from
// Apple's Foundation in ways only a Linux build reveals; nothing here needs to know it.

import Foundation

/// An ISO 3166-1 alpha-2 country, as `users.country` and `storefronts.country` hold it.
public enum CountryCode {
    /// "gb" → "GB", and nil for anything that is not two letters.
    ///
    /// Shape only, not membership: a list of every country would be a table to keep current
    /// for no gain, because an unknown code can only ever fail to match a storefront — which
    /// is the main shop, the same answer as no code at all. "ZZ" and the user-assigned codes
    /// are refused, since no shop sells to them and a phone reports "ZZ" for "unknown".
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return nil
        }
        guard !userAssigned.contains(code), !code.hasPrefix("X") else { return nil }
        return code
    }

    /// AA, QM–QZ and ZZ; the X range is checked by prefix above.
    private static let userAssigned: Set<String> = [
        "AA", "QM", "QN", "QO", "QP", "QQ", "QR", "QS", "QT", "QU", "QV", "QW", "QX", "QY", "QZ", "ZZ"
    ]
}

/// An ISO 4217 currency, as a stored price carries it.
public enum CurrencyCode {
    /// "gbp" → "GBP", and nil for a symbol, a word or anything that is not three letters.
    ///
    /// The sources mostly say it properly — Shopify's `/meta.json`, UCP's money, JSON-LD's
    /// `priceCurrency` — but the last of those is typed into a template by a person, and a
    /// "£" stored as a currency code would be passed to a formatter that cannot read it.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return nil
        }
        return code
    }
}

/// A price written the reader's way, in the shop's own currency.
///
/// **Formatted on the device that shows it, not on the server that read it.** The text a feed
/// row carries was formatted on a Linux box in the server's locale, and a currency symbol means
/// different things in different places: "$180" is unambiguous in New York and a guess in
/// Toronto, where the honest spelling of a US price is "US$180". With the amount and the
/// currency both known, the reader's own locale decides; with either missing — a row stored
/// before currencies were — there is nothing to format, and the caller prints the stored text
/// as it always did.
///
/// Never converts. There are no exchange rates anywhere in this system: a price is in the
/// currency of the shop that charges it, and comparing two of them is only ever done within
/// one shop.
public enum PriceFormat {
    /// - Parameters:
    ///   - amount: the price as a number, in `currency`.
    ///   - currency: the ISO code. Nil — or anything `CurrencyCode` refuses — formats nothing.
    ///   - locale: whose conventions to write it in; the reader's, in the app.
    /// - Returns: nil when there is not enough to write a price, so the caller can fall back.
    public static func text(amount: Double?, currency: String?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let amount, amount.isFinite, let code = CurrencyCode.normalized(currency) else { return nil }
        // Whole units, as `ShopifySource.formatPrice` has always written them: a feed of
        // "$180.00" against "$180" would read as two different prices.
        return amount.formatted(.currency(code: code).precision(.fractionLength(0)).locale(locale))
    }

    /// The price to print: formatted from the amount where the currency is known, and the
    /// stored text otherwise.
    public static func display(text: String?, amount: Double?, currency: String?, locale: Locale = .autoupdatingCurrent) -> String? {
        Self.text(amount: amount, currency: currency, locale: locale) ?? text
    }
}
