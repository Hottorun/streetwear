// StorefrontLock.swift
// Locks that answer 200.
//
// `HTTPResponse.isLocked` only sees a lock that shows up as a status code — a 401, or a
// redirect to `/password`. That is the classic Shopify "this store is closed" case and it
// is real, but it is not how most streetwear brands gate a drop, because closing the whole
// store also hides the lookbook, the newsletter and everything else they want you looking
// at while you wait.
//
// What they use instead renders a perfectly ordinary 200:
//
// - **Locksmith**, the Shopify app, which locks a page, a collection or a product and
//   publishes its own verdict into the markup as JSON:
//
//       <script type="application/vnd.locksmith+json">{"locked":true,"access_denied":true,…}
//
// - **A password page served at 200**, which some themes do rather than redirecting.
//
// Both are the storefront stating its own state in machine-readable form, which is the
// same bargain as `og:site_name` and `apple-touch-icon`: read what the site already
// publishes, don't guess.
//
// This only helps where we actually hold the HTML. A brand watched purely through
// `/products.json` never fetches a page, and a Locksmith lock on a *collection* does not
// change the catalog endpoint at all — so a store can be gated in a way this cannot see.
// That is a known gap, not an oversight.

import Foundation

public enum StorefrontLock {
    /// Whether this page says it is gated.
    public static func isLocked(html: String) -> Bool {
        locksmithVerdict(in: html) ?? looksLikePasswordPage(html)
    }

    /// Locksmith's own answer, when the page carries one. Nil when the app isn't installed
    /// — which is different from "not locked" and is why this isn't a `Bool`.
    ///
    /// `access_denied` rather than `locked` alone: a page can be locked *and* opened for
    /// you by a key, and Locksmith says so with both fields. Only being turned away counts.
    public static func locksmithVerdict(in html: String) -> Bool? {
        guard let range = html.range(
            of: "application/vnd\\.locksmith\\+json[^>]*>\\s*\\{[^}]*\\}",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        let blob = String(html[range]).lowercased()
        if blob.contains("\"access_denied\":true") || blob.contains("\"access_denied\": true") {
            return true
        }
        if blob.contains("\"locked\":true") || blob.contains("\"locked\": true") {
            // Locked but granted — a key you already hold — reads as open, because it is.
            let granted = blob.contains("\"access_granted\":true") || blob.contains("\"access_granted\": true")
            return !granted
        }
        return false
    }

    /// A Shopify password page rendered in place rather than redirected to.
    ///
    /// Two markers together, never one: "password" appears in the markup of plenty of open
    /// stores (a login form, an account link), and a single-word match would report half
    /// the internet as locked.
    static func looksLikePasswordPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        let hasForm = lowered.contains("action=\"/password\"") || lowered.contains("action='/password'")
        let hasStorefrontCopy = lowered.contains("password-page")
            || lowered.contains("enter store using password")
            || lowered.contains("opening soon")
        return hasForm && hasStorefrontCopy
    }
}
