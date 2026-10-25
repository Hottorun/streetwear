// SaleBanner.swift
// Reading "25% off everything with code AUTUMN" out of a storefront's announcement bar.
//
// A code sale is invisible to everything else this app reads. The discount is applied in the
// cart, so every price in `/products.json` stays where it was and no markdown is ever seen;
// the only place the sale exists is the strip of text across the top of the homepage. So the
// server reads that strip, and this decides what in it is a sale.
//
// **Pattern matching, deliberately and only.** The end date, the exclusions and the fine print
// need reading, not matching, and that waits for the AI phase. What a pattern can do reliably
// is the shape every one of these takes — a percentage off, the word sale, a code — and the
// discipline is all in what it refuses, because a banner is mostly not about sales:
//
// - **Only the bar is read, never the page.** Every storefront has a "Sale" link in its
//   navigation, and Kith's homepage says `SALE_OF_DATA` a dozen times in its analytics
//   config. Reading the whole page would put every brand permanently on sale.
// - **Free shipping is not a sale**, and neither is "buy now, pay later". They carry no
//   percentage and no sale word, so they fall out on their own.
// - **A discount for somebody else is not a sale.** "Students get 10% off everything" and
//   "10% off your first order" are standing offers to people who are not the reader, and
//   Motel Rocks and Princess Polly lead their bars with them every day of the year.
// - **"On sale" is a drop.** In streetwear "goes on sale Friday" means *available*, and the
//   word only counts as a markdown when nothing says it is about a release.
//
// Shared rather than living in the server so the rules are fixture-tested beside every other
// reader of a storefront, and because nothing here touches the network.

import Foundation

public struct SaleBanner: Sendable, Equatable {
    /// The message as the brand wrote it, whitespace collapsed.
    public var message: String
    /// How it is said: "30% OFF EVERYTHING · CODE BDAY30". Also the ledger's key — two
    /// wordings of one offer are one sale (`SaleBannerLedger`).
    public var title: String
    public var percent: Int?
    public var code: String?

    /// The sale the bar is announcing, or nil when it is announcing something else or there
    /// is no bar.
    ///
    /// A bar holds several messages — free shipping, an app, a sale — rotated or scrolled,
    /// and a marquee repeats them. The most specific sale wins: a percentage and a code say
    /// more than a percentage, which says more than the word.
    public static func read(html: String) -> SaleBanner? {
        var best: (banner: SaleBanner, score: Int)?
        for message in messages(in: html) {
            guard let banner = reading(message) else { continue }
            let score = (banner.percent == nil ? 0 : 2) + (banner.code == nil ? 0 : 2) + 1
            if best == nil || score > best!.score { best = (banner, score) }
        }
        return best?.banner
    }

    // MARK: - Finding the bar

    /// What a theme calls the strip. Matched against an element's tag name, `class` and `id`
    /// only — never other attributes, where a Vue binding or a CSS variable can mention one
    /// without being one.
    static let containerMarkers = [
        "announcement", "topbar", "top-bar", "promo-bar", "promobar", "marquee", "ticker"
    ]

    /// Every message in every announcement-like region of a page, in order, duplicates
    /// dropped — a marquee prints its list twice so the scroll can loop.
    static func messages(in html: String) -> [String] {
        let page = stripped(html)
        var found: [String] = []
        var seen = Set<String>()
        var consumedUpTo = page.startIndex

        for tag in openingTags(in: page) where tag.range.lowerBound >= consumedUpTo {
            guard isContainer(name: tag.name, attributes: tag.attributes) else { continue }
            let end = closing(of: tag.name, from: tag.range.upperBound, in: page)
            consumedUpTo = end
            for message in Self.split(String(page[tag.range.upperBound..<end])) where seen.insert(message.lowercased()).inserted {
                found.append(message)
            }
        }
        return found
    }

    /// The page with everything that is never an announcement taken out first — scripts,
    /// styles, inline SVG (whose `<title>` White Fox's bar uses to say "Shop now with
    /// Afterpay"), templates, comments, and navigation, which is where every storefront's
    /// "Sale" link lives and which some themes nest inside their top bar.
    private static func stripped(_ html: String) -> String {
        var page = html
        for pattern in [
            "<!--.*?-->",
            "<script\\b.*?</script\\s*>",
            "<style\\b.*?</style\\s*>",
            "<svg\\b.*?</svg\\s*>",
            "<noscript\\b.*?</noscript\\s*>",
            "<template\\b.*?</template\\s*>",
            "<nav\\b.*?</nav\\s*>"
        ] {
            page = replacing(pattern, in: page, with: " ")
        }
        return page
    }

    private struct Tag {
        var name: String
        var attributes: String
        var range: Range<String.Index>
    }

    /// Opening tags, quote-aware — Petal & Pup's bar carries `cell-selector=".list > *"`, and
    /// a tag read up to the first `>` would spill the rest of itself into the message.
    private static func openingTags(in page: String) -> [Tag] {
        guard let pattern = try? NSRegularExpression(
            pattern: "<([a-zA-Z][a-zA-Z0-9-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>",
            options: []
        ) else { return [] }
        let range = NSRange(page.startIndex..<page.endIndex, in: page)
        return pattern.matches(in: page, range: range).compactMap { match in
            guard let whole = Range(match.range, in: page),
                  let name = Range(match.range(at: 1), in: page),
                  let attributes = Range(match.range(at: 2), in: page)
            else { return nil }
            return Tag(name: page[name].lowercased(), attributes: String(page[attributes]), range: whole)
        }
    }

    private static func isContainer(name: String, attributes: String) -> Bool {
        if containerMarkers.contains(where: name.contains) { return true }
        guard let pattern = try? NSRegularExpression(
            pattern: "\\b(?:class|id)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
            options: [.caseInsensitive]
        ) else { return false }
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        for match in pattern.matches(in: attributes, range: range) {
            for group in 1...2 {
                guard let value = Range(match.range(at: group), in: attributes) else { continue }
                let lowered = attributes[value].lowercased()
                if containerMarkers.contains(where: lowered.contains) { return true }
            }
        }
        return false
    }

    /// Where the element opened at `start` closes, counting nested elements of the same
    /// name. Capped, so an unclosed `<div>` reads one bar's worth of page and not the rest of
    /// it — the navigation, with its "Sale" link, is usually right below.
    private static func closing(of name: String, from start: String.Index, in page: String) -> String.Index {
        let limit = page.index(start, offsetBy: 12_000, limitedBy: page.endIndex) ?? page.endIndex
        let open = "<\(name)"
        let close = "</\(name)"
        var depth = 1
        var cursor = start
        while cursor < limit {
            let nextOpen = page.range(of: open, options: .caseInsensitive, range: cursor..<limit)
            let nextClose = page.range(of: close, options: .caseInsensitive, range: cursor..<limit)
            guard let nextClose else { return limit }
            if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                // `<div` must not count `<divider>`.
                let after = nextOpen.upperBound < page.endIndex ? page[nextOpen.upperBound] : ">"
                if after.isWhitespace || after == ">" || after == "/" { depth += 1 }
                cursor = nextOpen.upperBound
                continue
            }
            depth -= 1
            if depth == 0 { return nextClose.lowerBound }
            cursor = nextClose.upperBound
        }
        return limit
    }

    /// A region's markup as its messages: one per block element or line break, inline
    /// markup (`<a>`, `<strong>`, `<span>`) read through. Anything past a banner's length is
    /// a paragraph somebody nested inside the bar, not a message in it.
    private static func split(_ markup: String) -> [String] {
        let blocks = "p|div|li|ul|ol|section|article|header|footer|aside|h[1-6]|br|tr|td|slide"
        var text = replacing("</?(?:\(blocks))\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", in: markup, with: "\n")
        // A custom element is a slide or a carousel at least as often as it is inline.
        text = replacing("</?[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z0-9-]*\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", in: text, with: "\n")
        text = replacing("<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", in: text, with: " ")
        text = HTMLEntities.decode(text)
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && $0.count <= 160 }
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    // MARK: - Reading one message

    /// Words that make an offer somebody else's: a student, a subscriber, a first order, a
    /// member, an app user. Whole tokens, never substrings — "membership" is not "members",
    /// and "applies" is not "app".
    static let notForEveryone: Set<String> = [
        "student", "students", "unidays", "subscribe", "subscriber", "subscribers", "newsletter",
        "signup", "member", "members", "membership", "military", "teacher", "teachers", "nurse",
        "nurses", "refer", "referral", "loyalty", "rewards", "app"
    ]

    /// Two-word versions of the same. "First order" is the commonest banner on Shopify.
    static let notForEveryonePhrases = [
        ["first", "order"], ["first", "purchase"], ["sign", "up"], ["your", "first"]
    ]

    /// What a message is, if it is a sale. Nil for everything else.
    public static func reading(_ message: String) -> SaleBanner? {
        let lowered = message.lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        guard !tokens.contains(where: notForEveryone.contains),
              !contains(notForEveryonePhrases, in: tokens)
        else { return nil }

        let percent = percentage(in: lowered)
        let phrase = salePhrase(in: tokens)
        let offWord = tokens.contains("off") || tokens.contains("save") || tokens.contains("discount")
        // A percentage is an offer only when something says it comes *off* — "30% recycled"
        // is a fabric. And the bare word on its own is a link someone left in the bar, not
        // an announcement: a bar that means it says "sale now on".
        guard phrase != nil || (percent != nil && offWord) else { return nil }
        guard percent != nil || tokens.count > 1 else { return nil }

        let code = code(in: message)
        var parts: [String] = []
        // A sale named for what it is ("END OF SEASON SALE") says something a percentage
        // does not; "SALE" on its own beside one says nothing more.
        if let phrase, phrase.contains(" ") || percent == nil { parts.append(phrase) }
        if let percent {
            var offer = percent.extra ? "EXTRA " : ""
            if percent.upTo { offer += "UP TO " }
            offer += "\(percent.value)% OFF"
            if let scope = scope(after: "off", in: tokens) { offer += " \(scope)" }
            parts.append(offer)
        }
        if let code { parts.append("CODE \(code)") }

        return SaleBanner(
            message: message,
            title: parts.joined(separator: " · "),
            percent: percent?.value,
            code: code
        )
    }

    private static func contains(_ phrases: [[String]], in tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        for index in 0..<(tokens.count - 1) {
            if phrases.contains(where: { $0[0] == tokens[index] && $0[1] == tokens[index + 1] }) {
                return true
            }
        }
        return false
    }

    /// The largest percentage in the message and how it is qualified. Two digits at most,
    /// so "100% cotton" is not an offer; a range ("50-70% off") reads as its top, "up to".
    private static func percentage(in lowered: String) -> (value: Int, upTo: Bool, extra: Bool)? {
        guard let pattern = try? NSRegularExpression(
            pattern: "(?:(?<![\\d.])(\\d{1,2})\\s?%?\\s?(?:-|to)\\s?)?(?<![\\d.])(\\d{1,2})\\s?%",
            options: []
        ) else { return nil }
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        var best: (value: Int, upTo: Bool, extra: Bool)?
        for match in pattern.matches(in: lowered, range: range) {
            guard let digits = Range(match.range(at: 2), in: lowered),
                  let value = Int(lowered[digits]), value > 0
            else { continue }
            let isRange = match.range(at: 1).location != NSNotFound
            let before = lowered[..<(Range(match.range, in: lowered)?.lowerBound ?? lowered.startIndex)]
            let lead = before.split { !$0.isLetter }.suffix(2).map(String.init)
            let upTo = isRange || lead == ["up", "to"]
            let extra = lead.last == "extra"
            if best == nil || value > best!.value { best = (value, upTo, extra) }
        }
        return best
    }

    /// The sale itself, named: up to three words before "sale" — "END OF SEASON SALE",
    /// "ARCHIVE SALE" — or a sale with a name of its own. Nil for "sale" used about a
    /// release, a policy or someone else's offer.
    private static func salePhrase(in tokens: [String]) -> String? {
        // "All sale items are final sale" is a returns policy from end to end, and the first
        // "sale" in it reads exactly like an announcement.
        if contains([["final", "sale"]], in: tokens) { return nil }
        for (index, token) in tokens.enumerated() {
            if token == "friday", index > 0, tokens[index - 1] == "black" { return named(tokens, endingAt: index) }
            if token == "monday", index > 0, tokens[index - 1] == "cyber" { return named(tokens, endingAt: index) }
            guard token == "sale" || token == "sales" else { continue }
            let previous = index > 0 ? tokens[index - 1] : ""
            // "Final sale" is a returns policy, "pre-sale" is early access to a drop, and
            // "on sale" — "goes on sale Friday" — is a release going live.
            guard !["final", "pre", "on", "for"].contains(previous) else { continue }
            return named(tokens, endingAt: index)
        }
        return nil
    }

    /// Where the name of a sale stops, reading backwards from "sale": the verbs and
    /// articles around it, and the offer itself — "UP TO 70% OFF SALE STYLES" is a
    /// percentage and a rail, not a sale called "OFF".
    private static let filler: Set<String> = [
        "shop", "the", "our", "now", "is", "live", "here", "its", "it", "new", "a", "an", "and",
        "to", "in", "at", "with", "all", "big", "off", "up", "extra", "save", "get", "take", "on"
    ]

    private static func named(_ tokens: [String], endingAt index: Int) -> String {
        var words = [tokens[index]]
        var cursor = index - 1
        while cursor >= 0, words.count < 4 {
            let word = tokens[cursor]
            guard word.allSatisfy(\.isLetter), !filler.contains(word) else { break }
            words.insert(word, at: 0)
            cursor -= 1
        }
        if words.last == "friday" || words.last == "monday" {
            if index + 1 < tokens.count, tokens[index + 1] == "sale" { words.append("sale") }
        }
        return words.joined(separator: " ").uppercased()
    }

    /// What the offer is on — "EVERYTHING", "DRESSES", "SELECTED STYLES" — read from the
    /// words after "off" until one that starts the conditions.
    private static let conditions: Set<String> = [
        "with", "when", "use", "using", "code", "at", "on", "your", "you", "orders", "order",
        "for", "in", "until", "ends", "end", "today", "tonight", "now", "only", "and", "applied",
        "automatically", "online", "the", "a", "an", "of", "this", "over", "plus", "t", "cs",
        "excludes", "exclusions", "apply", "shop", "sale"
    ]

    private static func scope(after word: String, in tokens: [String]) -> String? {
        guard let index = tokens.lastIndex(of: word) else { return nil }
        var words: [String] = []
        for token in tokens[(index + 1)...] {
            guard token.allSatisfy(\.isLetter), !conditions.contains(token), words.count < 2 else { break }
            words.append(token)
        }
        return words.isEmpty ? nil : words.joined(separator: " ").uppercased()
    }

    /// A code the bar names: "code AUTUMN", "CODE: BDAY30". The code itself is read from the
    /// brand's own casing — it has to be in capitals or carry a digit, which is what codes
    /// look like and what "code at checkout" does not.
    private static func code(in message: String) -> String? {
        guard let pattern = try? NSRegularExpression(
            pattern: "\\bcode\\b\\s*[:\\-]?\\s*([A-Za-z0-9]{3,20})\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for match in pattern.matches(in: message, range: range) {
            guard let found = Range(match.range(at: 1), in: message) else { continue }
            let candidate = String(message[found])
            let looksLikeACode = candidate.contains(where: \.isNumber)
                || candidate == candidate.uppercased()
            guard looksLikeACode, !codeWords.contains(candidate.lowercased()) else { continue }
            return candidate.uppercased()
        }
        return nil
    }

    /// Words a banner in capitals puts after "CODE" that are not one.
    private static let codeWords: Set<String> = [
        "at", "applies", "applied", "below", "required", "needed", "checkout", "online", "only",
        "for", "the", "and", "not", "needs", "valid", "in", "to", "on", "will", "auto"
    ]
}

/// Once per sale per brand: what the server keeps about the bar between reads.
///
/// **Keyed on the offer, not the prose.** The ledger stores `SaleBanner.title`, so a bar that
/// rewords itself — "ends Sunday", then "last day" — is the same sale, while a new code or a
/// deeper cut is a new one and is said again.
///
/// **A banner that disappears is not forgotten at once.** Bars are rotated, A/B-tested and
/// served differently by region, so the one read can lack the sale the last one had; clearing
/// the ledger there would announce the same sale again an hour later. The same words come
/// back as news only after `forgetAfter` without them, which is a new sale using the old copy.
public enum SaleBannerLedger {
    public static let forgetAfter: TimeInterval = 14 * 86_400

    public struct Outcome: Sendable, Equatable {
        public var announce: Bool
        public var stored: String?
        public var seenAt: Date?
    }

    /// - Parameter isFirstCheck: the brand's bar has never been read. That read is a
    ///   baseline — a sale already up when the bar was first looked at did not just start.
    public static func decide(
        found: SaleBanner?,
        stored: String?,
        seenAt: Date?,
        isFirstCheck: Bool,
        now: Date = Date()
    ) -> Outcome {
        guard let found else { return Outcome(announce: false, stored: stored, seenAt: seenAt) }
        let isSame = stored == found.title
            && seenAt.map { now.timeIntervalSince($0) < forgetAfter } == true
        return Outcome(announce: !isFirstCheck && !isSame, stored: found.title, seenAt: now)
    }
}
