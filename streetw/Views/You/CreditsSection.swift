// CreditsSection.swift
// The balance, what this month used, and the packs — on You, and only for an account.
//
// Drawn only when the server says this device is signed in (`CreditsSummary.signedIn`), and
// never in standalone mode, where there is no server to hold a balance. An anonymous device
// sees no section rather than a row asking it to sign in: signing in is its own section's
// to offer, and a second invitation here would be the page talking about itself.
//
// **The line under the title is the whole pricing policy, said plainly**: credits never
// expire, every action costs a fixed number, and those numbers are set from what the actions
// measurably cost. Nothing about it is small print, so none of it is printed small.
//
// See `docs/credits.md`.

import StoreKit
import StreetwCore
import SwiftUI

struct CreditsSection: View {
    @Environment(CreditStore.self) private var credits: CreditStore
    @Environment(AIStore.self) private var ai: AIStore

    /// Asked for by `YouView`, not here: a section that draws nothing when signed out is an
    /// `EmptyView`, and an `EmptyView` never appears, so a `.task` on it would never run.
    var body: some View {
        if credits.isShown, let summary = credits.summary {
            content(summary)
        }
    }

    private func content(_ summary: CreditsSummary) -> some View {
        let unlimited = summary.unlimited == true
        return VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(
                title: "Credits",
                note: unlimited ? "NEVER CHARGED · USAGE STILL COUNTED" : nil,
                info: info(summary)
            )

            VStack(spacing: 0) {
                YouRow(
                    title: "Balance",
                    detail: unlimited ? "UNLIMITED" : balance(summary.balance ?? 0),
                    detailColor: (summary.balance ?? 0) < 0 && !unlimited ? .signal : .ink
                )
                YouRow(title: "This month", detail: usage(summary.thisMonth ?? []), detailColor: .ink)

                // The price of each action, from the server's own table — the numbers the
                // affordances print beside themselves, gathered where the balance is.
                ForEach(prices, id: \.title) { price in
                    YouRow(title: price.title, detail: price.detail)
                }

                if !unlimited {
                    ForEach(summary.packs ?? []) { pack in
                        PackRow(pack: pack, product: credits.products[pack.productID], isBuying: credits.purchasing == pack.productID) {
                            Task { await credits.buy(pack) }
                        }
                    }
                }
            }

            if let message = credits.message {
                DataLabel(text: message.uppercased(), size: 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The whole pricing policy, a tap from the balance — nothing about it is small print, so
    /// it is said at full size in the sheet rather than in grey under the title.
    private func info(_ summary: CreditsSummary) -> InfoNote {
        var lines = [
            "Credits never expire.",
            "Each AI action costs a fixed number of them, set from what it measurably costs to run."
        ]
        if let allowance = summary.monthlyAllowance {
            lines.append("\(allowance) are free each month you use them.")
        }
        lines.append("Every action says its price before you press it, and what it took after.")
        return InfoNote(title: "Credits", lines: lines)
    }

    /// Each paid action this build offers, by the name its button uses, and what it costs.
    /// Only those the server prices: an action with no price is never printed as free.
    private var prices: [(title: String, detail: String)] {
        guard ai.isAvailable else { return [] }
        let named: [(CreditAction, String, String?)] = [
            (.search, "Ask Dropwall", "REPLIES INCLUDED"),
            (.webSearch, "Show me more", "THE OPEN WEB"),
            (.scan, "Scan a garment", nil),
            (.fitJudge, "Judge a fit", nil),
            (.fitSuggest, "Suggest for a fit", nil)
        ]
        return named.compactMap { action, title, note in
            guard let cost = ai.credits(for: action), cost > 0 else { return nil }
            let price = AIStore.creditsLabel(cost)
            return (title, note.map { "\(price) · \($0)" } ?? price)
        }
    }

    private func balance(_ value: Int) -> String {
        value == 1 ? "1 CREDIT" : "\(value) CREDITS"
    }

    /// "23 SEARCHES · 2 SCANS", most used first — the order the server sends.
    private func usage(_ rows: [CreditUsage]) -> String {
        guard !rows.isEmpty else { return "NOTHING YET" }
        return rows
            .map { "\($0.count) \(CreditAction($0.action).label(count: $0.count))".uppercased() }
            .joined(separator: " · ")
    }
}

/// One pack: what it adds, and StoreKit's price for it in the buyer's own currency.
private struct PackRow: View {
    let pack: CreditPackDTO
    let product: Product?
    let isBuying: Bool
    let buy: () -> Void

    var body: some View {
        Button(action: buy) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(pack.credits) credits")
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if isBuying {
                    ProgressView().controlSize(.mini).tint(.muted)
                } else {
                    // No product means StoreKit has not answered — or does not sell this pack
                    // in this storefront — and a price we made up would be a promise.
                    DataLabel(text: product?.displayPrice ?? "—", size: 10, color: product == nil ? .muted : .ink)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rule() }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(product == nil || isBuying)
    }
}
