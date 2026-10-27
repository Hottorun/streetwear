// AIBackgroundReading.swift
// Reading where rules cannot: a sale banner's end date and fine print, and a new product's
// page that publishes no structured data.
//
// Owner-paid and conservative, because nobody asked for either:
//
// - **Off when AI is off, and off for the rest of the UTC day once owner-paid work has cost
//   `AI_BACKGROUND_DAILY_CAP_MICROS`** (`AIBackground`). Every call is metered with no account
//   and no user.
// - **A banner is read once per sale**, on the pass that announces it — `SaleBannerLedger`
//   already decides that a reworded bar is the same sale, so a distinct text that is not a
//   new sale is never sent.
// - **A page is read once per new product**: only a product the poller is about to announce
//   (`pending_announcement`), only when its page loaded and the rules found nothing in it,
//   and at most `Poller.pageReadingBudget` a pass. Never a baseline's rows, never a re-read.
// - **What comes back is held to the rules' own shapes**: a date inside a plausible window, a
//   price above nothing, a name. Anything else is treated as not read.

import Foundation
import StreetwCore
import Vapor

enum AIBackgroundReading {
    /// The longest a sale can plausibly be said to run from today. A date beyond it is a
    /// misreading ("ends 2027" on a banner about a loyalty scheme), not a sale.
    static let saleHorizon: TimeInterval = 120 * 86_400
    /// How much of a page's visible text is sent. A product page says what it sells near its
    /// top; the rest is navigation, reviews and footers, and every character is paid for.
    /// Deliberately a cut, not an oversight.
    static let pageTextLimit = 12_000
    /// A page with less visible text than this has nothing a model could read either.
    static let pageTextMinimum = 80

    // MARK: Sale banners

    /// The banner's end date, code and fine print, or nil when AI is off, the day's cap is
    /// spent, or the reading failed.
    static func readSale(_ banner: SaleBanner, brand: String, app: Application, now: Date = Date()) async -> AISaleReading? {
        guard let service = app.ai, await AIBackground.allows(service, now: now, on: app.db) else { return nil }
        do {
            let answer = try await service.provider.readSaleBanner(message: banner.message, brand: brand, today: now)
            await AIBackground.record(answer.costs, now: now, on: app.db)
            return checked(answer.value, now: now)
        } catch {
            if let failure = error as? AIFailure { await AIBackground.record(failure.costs, now: now, on: app.db) }
            app.logger.info("ai: sale banner of \(brand) not read: \(String(describing: error))")
            return nil
        }
    }

    static func checked(_ raw: AISaleReading, now: Date) -> AISaleReading? {
        let endsAt = raw.endsAt.flatMap { date in
            date > now.addingTimeInterval(-86_400) && date < now.addingTimeInterval(saleHorizon) ? date : nil
        }
        let code = raw.code
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .flatMap { code in
                !code.isEmpty && code.count <= 24 && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? code : nil
            }
        let terms = raw.terms.map { AIText.clean($0, 200) }.flatMap { $0.isEmpty ? nil : $0 }
        guard endsAt != nil || code != nil || terms != nil else { return nil }
        return AISaleReading(endsAt: endsAt, code: code, terms: terms)
    }

    // MARK: Product pages

    /// What a page with no structured data says, as the rules would have read it, or nil.
    static func readPage(html: String, url: URL, app: Application, now: Date = Date()) async -> ProductPage? {
        guard let service = app.ai else { return nil }
        let text = visibleText(of: html)
        guard text.count >= pageTextMinimum, await AIBackground.allows(service, now: now, on: app.db) else { return nil }
        do {
            let answer = try await service.provider.readProductPage(text: text, url: url)
            await AIBackground.record(answer.costs, now: now, on: app.db)
            return answer.value.flatMap(page(from:))
        } catch {
            if let failure = error as? AIFailure { await AIBackground.record(failure.costs, now: now, on: app.db) }
            app.logger.info("ai: page of \(url.host() ?? "?") not read: \(String(describing: error))")
            return nil
        }
    }

    /// The reading as a `ProductPage`, so the poller lays it over the row exactly as it lays
    /// a structured page.
    static func page(from reading: AIPageReading) -> ProductPage? {
        let title = AIText.clean(reading.title, 200)
        guard !title.isEmpty else { return nil }
        let price = reading.price.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let currency = price == nil ? nil : reading.currency.flatMap(CurrencyCode.normalized)
        var seen = Set<String>()
        let variants = reading.sizes.compactMap { size -> VariantInfo? in
            let label = AIText.clean(size.size, 24)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { return nil }
            return VariantInfo(
                id: "page-size-\(label.lowercased())",
                title: label,
                // Said nothing about stock: shown as buyable, the reading that hides nothing.
                available: size.available ?? true,
                size: label
            )
        }
        return ProductPage(
            name: title,
            currency: currency,
            price: price,
            isAvailable: reading.available ?? (variants.isEmpty ? nil : variants.contains(where: \.available)),
            variants: variants
        )
    }

    /// A page's words, without its scripts, styles and markup, whitespace collapsed.
    static func visibleText(of html: String, limit: Int = pageTextLimit) -> String {
        var page = html
        for pattern in [
            "<!--.*?-->",
            "<script\\b.*?</script\\s*>",
            "<style\\b.*?</style\\s*>",
            "<svg\\b.*?</svg\\s*>",
            "<noscript\\b.*?</noscript\\s*>",
            "<template\\b.*?</template\\s*>",
            "<[^>]+>",
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            page = regex.stringByReplacingMatches(in: page, range: NSRange(page.startIndex..., in: page), withTemplate: " ")
        }
        let words = HTMLEntities.decode(page).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(limit))
    }
}
