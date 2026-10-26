// CreditStore.swift
// The phone's half of credits: what the server says the balance is, what StoreKit says the
// packs cost, and getting a purchase from one to the other.
//
// **The server is the bank and StoreKit is only the till.** The balance lives under the
// account (`CreateAccounts`), because StoreKit cannot restore a consumable and a balance kept
// here would be lost with the app. So nothing on this side adds a credit: a purchase is handed
// over as StoreKit signed it, the server verifies it and credits it, and this file only ever
// prints what the server answered.
//
// **A transaction is finished only once the server has taken it.** Finishing tells StoreKit
// the content was delivered, and an unfinished transaction is the only record that a
// purchase is still owed. So a purchase that reaches a server which cannot verify it yet, or
// a phone that loses the network halfway, stays unfinished — and is posted again from
// `Transaction.unfinished` on the next launch and from `Transaction.updates` whenever StoreKit
// delivers it, which is how an interrupted purchase is credited later rather than lost. The
// server credits a transaction once however often it is posted, so posting too often costs
// nothing.
//
// Standalone mode has no server to be the bank, so it has no credits: nothing here runs.
// See `docs/credits.md`.

import Foundation
import Observation
import StoreKit
import StreetwCore

@MainActor
@Observable
final class CreditStore {
    /// What the server last said. Nil until asked, or when it could not be.
    private(set) var summary: CreditsSummary?
    /// StoreKit's products for the server's packs, keyed by product id — the localized price
    /// comes from here, never from a number of ours.
    private(set) var products: [String: Product] = [:]
    /// The pack being bought, so its row can say so.
    private(set) var purchasing: String?
    /// One line about the last purchase, said under the packs.
    private(set) var message: String?

    private let settings: ServerSettings
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(settings: ServerSettings) {
        self.settings = settings
    }

    /// Whether the You page draws a Credits section: something to spend them on, a server, and
    /// an account on it.
    var isShown: Bool {
        Self.isOffered && settings.isConfigured && summary?.signedIn == true
    }

    /// **Off until an action costs credits** — Phase 4's AI. Selling packs nothing in the app
    /// can spend is a consumable that does nothing, which App Review refuses (3.1.1) and which
    /// would take somebody's money for a promise. The ledger, the routes and the purchase path
    /// all ship and are tested; this is the one switch that shows them.
    static let isOffered = false

    private var api: StreetwAPI? {
        guard let baseURL = settings.baseURL, settings.token != nil else { return nil }
        return StreetwAPI(baseURL: baseURL, token: settings.token)
    }

    // MARK: Launch

    /// Starts listening for transactions StoreKit delivers outside a purchase — one that was
    /// interrupted, approved later (Ask to Buy), or made on another device — and posts any
    /// left unfinished. **At launch**, from `streetwApp.init`, because a transaction delivered
    /// before anybody listens is delivered to nobody until the next launch.
    func start() {
        guard updates == nil, settings.isConfigured else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.deliver(result)
            }
        }
        Task { await settleUnfinished() }
    }

    /// Posts every transaction StoreKit still holds unfinished.
    func settleUnfinished() async {
        for await result in Transaction.unfinished {
            await deliver(result)
        }
    }

    // MARK: Reading

    /// Asks the server, then StoreKit for whichever packs the server sells.
    func refresh() async {
        guard let api else { return }
        do {
            let summary = try await api.credits()
            self.summary = summary
            await loadProducts(for: summary.packs ?? [])
        } catch {
            // Kept rather than cleared: a balance from a minute ago beats a section that
            // vanishes because the network blinked. A first read that fails draws nothing.
        }
        // A page somebody is looking at is a good moment to settle anything still owed — the
        // launch sweep may have run before this install had a token.
        await settleUnfinished()
    }

    private func loadProducts(for packs: [CreditPackDTO]) async {
        let wanted = Set(packs.map(\.productID))
        guard !wanted.isEmpty, wanted != Set(products.keys) else { return }
        do {
            let found = try await Product.products(for: wanted)
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        } catch {
            products = [:]
        }
    }

    // MARK: Buying

    func buy(_ pack: CreditPackDTO) async {
        guard purchasing == nil, let product = products[pack.productID] else { return }
        purchasing = pack.productID
        message = nil
        defer { purchasing = nil }

        var options: Set<Product.PurchaseOption> = []
        // Names the account the purchase is for, so the server can refuse to credit it to
        // another and tie a refund back to it. See `CreditsSummary.accountToken`.
        if let token = summary?.accountToken {
            options.insert(.appAccountToken(token))
        }

        do {
            switch try await product.purchase(options: options) {
            case .success(let result):
                await deliver(result)
            case .pending:
                // Ask to Buy, or a payment method that needs attention. The transaction
                // arrives through `Transaction.updates` if it is approved.
                message = "Waiting for approval. The credits arrive when it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The App Store couldn't complete the purchase."
        }
    }

    // MARK: Delivering

    /// Hands one transaction to the server and finishes it only if the server took it.
    ///
    /// Posted whether or not StoreKit could verify it locally: the server checks the
    /// signature itself and is the only judgement that matters. Anything that is not a
    /// credit pack is left alone — it is not this file's to finish.
    private func deliver(_ result: VerificationResult<Transaction>) async {
        let transaction = result.unsafePayloadValue
        guard transaction.productType == .consumable,
              transaction.productID.hasPrefix(Self.packPrefix)
        else { return }
        guard let api else { return } // posted again on the next launch

        do {
            let receipt = try await api.postPurchase(signedTransaction: result.jwsRepresentation)
            await transaction.finish()
            switch receipt.outcome {
            case .credited:
                message = "\(receipt.credited) credits added."
            case .alreadyCredited, .revoked:
                break
            }
            // The whole summary rather than the receipt's balance, which is the ledger's sum
            // and leaves out an allowance still due.
            if let refreshed = try? await api.credits() { summary = refreshed }
        } catch APIError.server(503, _) {
            // The server cannot verify purchases yet. Paid for and owed: left unfinished, so
            // it is posted again and credited once the server can.
            message = "Bought. Dropwall adds the credits as soon as the server can confirm the purchase."
        } catch APIError.server(let code, let reason) where (400..<500).contains(code) {
            message = reason ?? "The purchase wasn't accepted."
        } catch APIError.forbidden(let reason) {
            message = reason ?? "The purchase wasn't accepted."
        } catch {
            message = "Bought. The credits will be added next time Dropwall reaches the server."
        }
    }

    /// Every pack's product id starts with this; see `CreditPacks` on the server.
    static let packPrefix = "com.kern.functional.streetw.credits."
}
