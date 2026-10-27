# Credits and cost metering

Part of the streetw guidance set; see `CLAUDE.md` for the index and the build rules.

**Read this before touching `CreditLedger`, `CostMeter`, `AppStorePurchases`, `PurchasePolicy`,
`CreditPacks`, `CreditPolicy`, `CreditStore`, `CreditsSection`, `streetw.storekit` or any
`/v1/credits`, `/v1/app-store` or `/admin/costs` route.**

The decision being implemented is in `ROADMAP.md`, *Decided*: AI is paid for with credits that
never expire, a fixed number per action, a small free monthly allowance, usage shown in the app,
and prices set from measured cost. No AI action exists yet (Phase 4); everything here is built so
that one only has to call it.

**The app shows credits since Phase 4** (`CreditStore.isOffered`, true), the release in which an
action first costs them. It was false until then: packs nothing in the app can spend are a
consumable that does nothing — App Review refuses those under 3.1.1, and it would be taking money
for a promise. **The packs go into App Store Connect with this release, not before.**

## What Phase 4 calls

```swift
let accountID = try CreditLedger.accountID(of: user)          // 403 "Sign in to use credits"
let charge = try await CreditLedger.spend(
    credits: CreditPolicy.credits(for: .search), for: .search, account: accountID, on: db)
do {
    let reply = try await provider.call(...)                   // not inside the transaction
    try await CostMeter.record(reply.cost, for: user, on: db)  // every call, always
} catch {
    try await CreditLedger.undo(charge, on: db)                // the action produced nothing
    throw error
}
```

- **Spend before the call, never after.** A spend is the only place a refusal can happen, and a
  provider bill already run up cannot be refused.
- **Meter every provider call**, including the ones whose result is thrown away, on unlimited
  accounts, and for work done for nobody in particular (`account: nil, user: nil`). The meter
  is a fact about the provider bill, not about who was charged.
- **One action may be several calls.** Usage ("this month: 23 searches") is counted from spends,
  not from metered calls, so a search with a follow-up is still one search.
- The provider call is **not** inside the spend's transaction: that holds the account's row lock
  for the duration of a network call.

## The ledger

- **The ledger is the truth and the balance is its sum** (`credit_ledger`, `SUM(delta)`). There
  is no stored balance to drift from the rows that explain it. One indexed range per spend over
  one account's rows; when that is measurably slow, a maintained column goes *beside* the ledger,
  written in the same transaction — the ledger stays what it is checked against.
- **A spend is serialised per account by `SELECT … FOR UPDATE` on the account row** (Postgres),
  then the sum, the decision and the insert in one transaction. Without it two concurrent spends
  of the last five credits both read five and both take five. **SQLite cannot show this race**:
  it takes no row locks and serialises writers. `CreditRaceTests` runs it against a real Postgres
  when `STREETW_TEST_POSTGRES_URL` names a scratch database, and fails with the lock removed — 20
  concurrent spends of ten against a balance of fifty succeed exactly five times.
- **Reasons**: `purchase`, `allowance`, `spend`, `grant`, `refund`, `refund_reversed`,
  `reversal`. A spend undone is a `reversal` row, never a deleted spend, so the ledger still says
  what happened.
- **The order of the rule** (`CreditLedger.decide`): the monthly cost cap first, then unlimited,
  then the balance.
- **Unlimited** (`accounts.unlimited_credits`, the owner's switch, flipped by the account routes):
  a spend writes a row of **zero** and never refuses — so usage is counted exactly as for anybody
  — and the cost is still metered. No allowance is granted to an account that is never charged.
- **The monthly cost cap** (`accounts.monthly_cost_cap_micros`) refuses once this UTC month's
  metered cost for the account has reached it, unlimited or not. It is a guard against a looping
  bug spending real money, not a price; nil is no cap.
- **Credits need an account.** StoreKit cannot restore a consumable, so a balance has to live
  under the identity that survives a reinstall (`CreateAccounts`). An anonymous device gets
  `403 Sign in to use credits` from any spend or purchase, and `{"signedIn": false}` from
  `GET /v1/credits`.

## The free monthly allowance

- **`CreditPolicy.monthlyAllowance` = 50 is a placeholder** until the meter has a few weeks of
  real actions — the roadmap's "generous allowance while the server records what every action
  really cost". So is every number in `CreditPolicy.credits(for:)` (scan is two because the
  roadmap says two).
- **Granted lazily, on the first spend of a UTC month** (`CreditMonth`), not by a job on the
  first. An account that does not use credits in a month is granted nothing for it, so there is
  no sweep over every account and nothing accrues for somebody who has left.
- **Reading the balance does not grant it.** `GET /v1/credits` counts an allowance still due into
  the balance it prints and writes nothing — otherwise opening You once a month would accrue
  credits without using any, and a balance that jumped by fifty on first use would read as a bug.
- **Granted credits never expire either.** Nothing is taken back at the month's end; the month
  after adds another allowance on top. Simple, and consistent with "nothing expires"; if the
  allowance should instead top up to a ceiling, that is a change to `grantAllowanceIfDue` alone.
- One per account per month, by the unique `(account_id, allowance_month)`; the check-then-insert
  runs under the account's lock, and the constraint is the backstop.

## Purchases

`POST /v1/credits/purchases` takes one StoreKit 2 transaction exactly as StoreKit signed it
(`VerificationResult.jwsRepresentation`). **Nothing the phone says about a purchase is believed.**

1. **The signature** — `SignedTransactionVerifying.verifiedPayload(of:)`, the only crypto;
   `AppStoreVerifier` in production. See *Verifying the signature* below.
2. **The bundle id** is `com.kern.functional.streetw`, or any app's purchase could be replayed.
3. **The environment** (`PurchasePolicy.accepts`): `Production` everywhere; `Sandbox` off
   production or with `CREDITS_ALLOW_SANDBOX=true`; **`Xcode` never on production, flag or no
   flag** — those are signed by a certificate any developer's Xcode makes for itself. The flag is
   needed on production while App Review and TestFlight buy packs, because both are sandbox
   purchases against the production server; while it is on, a TestFlight tester can mint
   credits. Every purchase row carries `store_environment` so those can be found and taken back
   with a negative grant.
4. **The product** is in `CreditPacks`, which says what it is worth. A product App Store Connect
   sells and this table does not list is refused with 422 and left unfinished on the phone — a
   deploy behind App Store Connect, which the next deploy can still credit.

Then:

- **Credited once per transaction id**, by the unique `(apple_transaction_id, reason)`. A replay,
  a retry after a lost reply and `Transaction.updates` re-delivering all answer
  `alreadyCredited` with 200, so the phone can finish the transaction.
- **`appAccountToken` is the account id** (`CreditsSummary.accountToken`), set by the phone at
  purchase. A transaction naming a different account is refused (409); one credited to another
  account is refused (409). Nil is allowed — an interrupted purchase may predate the account on
  this install.
- **Quantity multiplies the pack.**
- **A revoked transaction** (`revocationDate`) is final: 200, `revoked`, nothing credited.

### Verifying the signature

`AppStoreVerifier` (`Server/Sources/StreetwServer/Services/AppStoreSignature.swift`) is what Apple's
`app-store-server-library-swift` does, without its JWT stack. A JWS it cannot read is 400
`malformed`; one whose signature or chain does not verify is 400 `untrusted` ("That transaction's
signature doesn't verify"), and the phone leaves the transaction unfinished.

- **`alg` is `ES256` and `x5c` is exactly three certificates** — leaf, Apple's WWDR intermediate,
  root — standard base64 DER.
- **The root is the server's, never the token's.** The chain is built from the leaf through the
  token's intermediate to **Apple Root CA - G3**, compiled in as PEM (`AppleRootCA.g3PEM`, from
  https://www.apple.com/certificateauthority/AppleRootCA-G3.cer, SHA-256
  `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`).
  The token's own third certificate plays no part. A test pins the PEM to that fingerprint, so
  a mangled paste cannot ship. When Apple issues a successor root, it goes beside G3 in
  `trustedRoots`.
- **Apple's marker OIDs**: 1.2.840.113635.100.6.11.1 on the leaf (receipt signing),
  1.2.840.113635.100.6.2.1 on the intermediate (WWDR). Without them, any certificate Apple's root
  ever vouched for could sign a purchase.
- **Validity is checked at the payload's `signedDate`, not now** — what Apple's libraries do with
  online checks off. A transaction is signed once and may be posted again months later, and a
  refund can be about a purchase older than the certificate in use today, so "now" would one day
  refuse something genuine. The date is read before the chain is checked, which only lets a
  caller choose *when* a chain is judged; it must still end at Apple's root and the signature
  still verify. A payload with no `signedDate` is judged at now, which is stricter. RFC 5280's
  rules (basic constraints, every certificate in its validity window) come from swift-certificates'
  `RFC5280Policy(fixedExpiryValidationTime:)`, an `@_spi` initialiser the library itself points
  to for exactly this.
- **No online revocation check (OCSP).** The price of judging at `signedDate`: a leaf Apple revoked
  after a key leak would still verify. Checking would put a request to Apple's OCSP responder in
  front of every purchase and refund and make crediting depend on its uptime. Apple's library
  makes it a switch (`enableOnlineChecks`); this is that switch off.
- **The ES256 signature is raw r‖s, 64 bytes**, over `header.payload` exactly as sent, checked
  with the leaf's P-256 key. A DER-encoded signature is refused.

The dependencies: swift-crypto (`Crypto`, `_CryptoExtras` for Sign in with Apple's RSA) and
swift-certificates (`X509`), approved by the owner and declared in `Server/Package.swift` with
floors at the resolved versions. Both were already in `Package.resolved` through Vapor,
swift-nio-extras and APNSwift, so declaring them downloaded nothing. swift-asn1 comes in through
swift-certificates and is not declared; the code compares OIDs by their dotted form so it never
names a SwiftASN1 type.

### The local double

`UnverifiedLocalVerifier` believes any well-formed JWS, so a simulated purchase can be followed
end to end against a local server. **It needs both a non-production server and
`CREDITS_UNVERIFIED_TRANSACTIONS=true`**; on a server running `--env production` (the Dockerfile's
`CMD`) the flag is refused with a critical log line and the real verifier is used. The suite puts
the double in through `app.purchasePolicy`.

## Refunds

`POST /v1/app-store/notifications` is App Store Server Notifications V2 — the URL App Store Connect
is given, for both environments. **Public**: Apple holds no device token, so the signature is the
authentication. It verifies the notification *and* the transaction inside it — and the
`signedRenewalInfo`, when there is one (only subscriptions carry it, so a pack never does, but a
notification is only as genuine as everything inside it) — each the same way as a purchase. It is
rate-limited per address because each delivery is two or three chain-and-signature checks. A
delivery that does not verify is 400.

- **`REFUND` and `REVOKE` take back exactly what the purchase row added** — the ledger's number,
  not the pack table's, which may have changed since. Once per transaction (the same unique
  constraint), so Apple's retries are harmless.
- **The balance may go negative.** The credits were spent and the money returned; a negative
  balance refuses every spend until something brings it back above zero. The phone prints it in
  vermilion.
- **A refund that arrives before the purchase was ever posted** is recorded as a zero `refund`
  row under the account its `appAccountToken` names, so the later post answers `revoked` and
  credits nothing. With no token there is nowhere to write it — the one case a stale copy of the
  transaction could still be credited once.
- **`REFUND_REVERSED`** gives the credits back, once.
- Everything else (`CONSUMPTION_REQUEST`, `TEST`, another app's) is answered 200 and changes
  nothing. Answering a consumption request needs the App Store Server API, which this server does
  not call; not answering is allowed.

## Metering

- `ai_costs`: action, model, tokens each way, cost in millionths of a dollar — **numbers only**,
  no prompt, reply, photograph or product. Every count is a `BIGINT`.
- Keyed to the account when there is one, the user otherwise, neither for shared work. **Both
  keys are `ON DELETE SET NULL`**: deleting an account takes the person out of the rows and
  leaves the measurement prices are set from. The ledger, by contrast, cascades with the account
  — deleting an account forfeits its credits, which the deletion screen has to say.
- `GET /admin/costs?since=` (ISO-8601, default 30 days, at most a year): per action, count, total,
  mean, nearest-rank p50 and p90, max, tokens, and calls per model — most expensive first. The
  percentiles are computed in Swift because SQLite has no `percentile_cont`; at measurement scale
  that is thousands of rows. **Price from the p90, not the mean**: the mean undercharges the tail,
  which is where a long thread or a big photograph lives.

## The app

- **The server is the bank, StoreKit is the till.** Nothing on the phone adds a credit; it prints
  what `GET /v1/credits` answers. The packs come from that answer, prices from StoreKit
  (`Product.displayPrice`), never from a number of ours — a pack StoreKit has not answered for
  shows "—" and cannot be tapped.
- **Finish a transaction only once the server has taken it** (any 2xx). An unfinished transaction
  is the only record that a purchase is still owed. `CreditStore.start` listens to
  `Transaction.updates` from `streetwApp.init` — a transaction delivered before anybody listens
  reaches nobody until the next launch — and posts `Transaction.unfinished` at launch and each
  time You opens.
- **The Credits section is drawn only when `CreditsSummary.signedIn`**, and never standalone. An
  anonymous device sees no section, not an invitation: signing in is its own section's to offer.
  Whether one exists is the server's answer, so You asks every time it opens, keyed on the token.
- **Unlimited shows "UNLIMITED" and no packs**; the server sends none for such an account anyway.
- **Each AI action's price is a row of its own**, by the name its button uses ("Ask Dropwall ·
  1 CREDIT · A SEARCH, WITH ITS REPLIES"), read from `GET /v1/ai`'s `credits` table through
  `AIStore` — so a price change needs no app update, and an action the server prices at nothing
  is not printed as free. Usage lines name the new actions through `CreditAction.label`.
- **An AI answer carries its `AICharge`, and `CreditStore.apply` writes its balance into the
  summary**, so the balance is right the moment the action answers. This month's usage is the
  server's count and is read again the next time You opens. The action itself prints the charge
  beside its result ("1 CREDIT · 48 LEFT", "NO CHARGE — PART OF THIS SEARCH").
- **A refusal names its fix** (`AIRefusal`): 402 "Not enough credits" with *Get credits*, 403
  "Sign in to use" with *Sign in* — both open You, where the packs and sign-in are — and 429 the
  month's cost cap, which no button can pass. None is drawn as an empty result.
- **`streetw.storekit`** holds three placeholder consumables (`…credits.50/150/500` at
  $0.99/$2.99/$8.99) and is referenced from the scheme's Run action. It sits beside the
  `.xcodeproj` rather than in `streetw/` for the reason `streetw-Info.plist` does — the
  synchronized root group would copy it into the bundle. **It only applies when Xcode launches the
  app** (⌘R): `xcodebuild` and `simctl launch` never sync it to the simulator's StoreKit daemon, so
  a CLI-launched build shows "—" for every price. Product ids are `com.kern.functional.streetw.credits.<n>`;
  the number is a convention, the count is read from `CreditPacks`.
