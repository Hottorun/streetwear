// RateLimit.swift
// What one caller may ask for, and how often.
//
// **The device-token tier was never a cost barrier.** `POST /v1/devices` is unauthenticated
// by necessity — a phone has to be able to register before it has a credential — and it
// mints a working token per call. So "behind `RequireDevice`" meant "behind one extra
// request", and everything under `/v1` was effectively public to anyone willing to make it.
//
// That matters most for the two routes that make the *server* do expensive things on a
// stranger's say-so. `POST /v1/brands/discover` fetches a URL the caller chose and writes a
// permanent brand row, which the poller then re-fetches every twenty minutes for as long as
// it exists; `GET /v1/brands/probe` fetches without writing. `HostSafety` stops those
// reaching anywhere private, which was the dangerous half — this is the expensive half.
//
// There is a second, sharper consequence worth naming, because it is not about cost at all.
// The probe routes share one `PoliteFetcher` with the poller, deliberately, so nothing can
// fetch a storefront alongside the poller instead of behind it. A slot is reserved *before*
// the sleep, so a loop of probes aimed at one host pushes that host's next slot arbitrarily
// far into the future — and the poller's own request for that brand queues behind all of
// them. Being early is the entire product; that is how you make a drop arrive late.
//
// ## The two decisions in here
//
// **Storage is in memory, and belongs to the running server.** The alternative is a row per
// request, and a write per request to stop a read-per-request attack is the wrong trade — it
// makes the cheap path expensive in order to defend the expensive one. Two consequences,
// both deliberate: a restart forgives everybody, and on two instances a caller gets two
// buckets. That is the right shape for what this guards — outbound fetch budget and row
// creation, which are already per-instance concerns — and it is written down here so the day
// this scales out nobody has to work out whether it mattered.
//
// **Limits are generous enough that no real client can reach them.** A rate limiter that
// fires on ordinary use is worse than none: it turns a working app into an intermittently
// broken one, and the failure looks like a bug rather than a policy. Every number below is
// set well above what the app actually does — the app syncs on a sixty-second throttle and
// pages Discover by hand — so tripping one is a statement that the caller is not the app.

import Fluent
import Vapor

/// A token bucket: `capacity` requests available, refilling at `refillPerSecond`.
///
/// Pure and value-typed so it can be tested without a clock, a socket or a server — the
/// interesting behaviour is the arithmetic, and the arithmetic is the part that is easy to
/// get subtly wrong.
struct TokenBucket: Equatable {
    /// The most that can be spent in one burst.
    let capacity: Double
    /// How fast it comes back.
    let refillPerSecond: Double

    private(set) var tokens: Double
    private(set) var updatedAt: Date

    init(capacity: Int, refillPerSecond: Double, now: Date) {
        self.capacity = Double(capacity)
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
        self.updatedAt = now
    }

    /// Spends one token if there is one.
    /// - Returns: nil when allowed, or how long to wait when refused.
    mutating func take(now: Date) -> TimeInterval? {
        // Refill first, always — including when the answer will be no, so a refusal still
        // advances the clock and a caller who waits is not punished for having asked.
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        updatedAt = now

        if tokens >= 1 {
            tokens -= 1
            return nil
        }
        // How long until one token exists. Rounded up to a whole second: `Retry-After` is
        // expressed in seconds, and telling somebody to wait zero seconds is telling them
        // to try again immediately, which is what got them here.
        let needed = 1 - tokens
        return max(1, (needed / refillPerSecond).rounded(.up))
    }

    /// Whether this bucket carries no information any more — full, and therefore
    /// indistinguishable from one that has never been used. Such an entry can be dropped.
    func isSpent(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        return min(capacity, tokens + elapsed * refillPerSecond) >= capacity
    }
}

/// One named budget, shared by every caller of the routes it guards.
actor RateLimitStore {
    private var buckets: [String: TokenBucket] = [:]
    private let capacity: Int
    private let refillPerSecond: Double

    /// Above this many tracked callers, a sweep runs before the next admission. Bounded so
    /// the table cannot grow without limit under exactly the traffic it exists to refuse —
    /// a limiter that leaks memory per attacker is a denial of service with extra steps.
    private let sweepAbove = 10_000

    init(capacity: Int, refillPerSecond: Double) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }

    /// - Returns: nil when allowed, or the seconds to wait when refused.
    func take(_ identity: String, now: Date = Date()) -> TimeInterval? {
        if buckets.count > sweepAbove { sweep(now: now) }

        var bucket = buckets[identity]
            ?? TokenBucket(capacity: capacity, refillPerSecond: refillPerSecond, now: now)
        let wait = bucket.take(now: now)
        buckets[identity] = bucket
        return wait
    }

    /// Drops every bucket that has refilled to full: it says nothing a fresh one would not.
    private func sweep(now: Date) {
        buckets = buckets.filter { !$0.value.isSpent(now: now) }
    }

    var tracked: Int { buckets.count }
}

/// Refuses a caller who is asking far faster than the app ever would.
struct RateLimit: AsyncMiddleware {
    /// How a caller is told apart from another one.
    enum Identity {
        /// The bearer token — i.e. the device. Used for everything under `/v1` that is
        /// authenticated, because that is the thing a limit should attach to.
        case device
        /// The client address, for the one route that runs before anybody has a token.
        ///
        /// Read from `X-Forwarded-For` first: this runs behind a proxy, so `peerAddress` is
        /// the proxy on every request and limiting on it would put the entire internet in
        /// one bucket — a limiter that refuses everybody once anybody misbehaves.
        case address
    }

    let store: RateLimitStore
    let identity: Identity
    /// Named in the log line, so a refusal says which budget was spent.
    let name: String

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let key = Self.key(for: identity, request: request)
        if let wait = await store.take(key) {
            request.logger.notice("rate limit: refused \(name) for \(Self.redact(key))")
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .retryAfter, value: String(Int(wait)))
            throw Abort(
                .tooManyRequests,
                headers: headers,
                reason: "Too many requests. Try again in \(Int(wait))s."
            )
        }
        return try await next.respond(to: request)
    }

    static func key(for identity: Identity, request: Request) -> String {
        switch identity {
        case .device:
            // The raw bearer token. It never leaves this process and is never logged whole
            // — see `redact` — but it is the only per-device handle available before the
            // authenticator has run, and ordering the middleware the other way would mean a
            // database lookup on every refused request.
            return request.headers.bearerAuthorization?.token
                ?? key(for: .address, request: request)
        case .address:
            if let forwarded = request.headers.first(name: .xForwardedFor) {
                // The left-most entry is the original client; everything after it is the
                // chain of proxies. Trusting the right-most would bucket by our own edge.
                let first = forwarded.split(separator: ",").first ?? ""
                let trimmed = first.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return request.peerAddress?.ipAddress ?? "unknown"
        }
    }

    /// Enough of a key to correlate two log lines, never enough to replay.
    static func redact(_ key: String) -> String {
        key.count <= 8 ? key : String(key.prefix(6)) + "…"
    }
}

/// The budgets, in one place so they can be read against each other.
///
/// Every number is a ceiling on *abuse*, not a target for normal use — see the file header.
///
/// **Owned by the `Application`, not by the process.** These were `static let`s, which is
/// the obvious shape and the wrong one: a budget is a property of a running server, and
/// making it global means every server in the process shares it. That is invisible in
/// production, where there is exactly one — and immediately visible in the test suite, where
/// a dozen `Application`s each register a device and the twelfth is refused by a bucket the
/// first eleven spent. A limiter whose behaviour depends on what some *other* server did is
/// not one anybody can reason about.
final class RateLimits: @unchecked Sendable {
    /// Registration, per address. A phone registers once per install, and again only if the
    /// server forgets it. Ten an hour is already far more than a person can legitimately
    /// need, and it is the tightest budget here because this route is the one that mints
    /// the credential every other budget is keyed on.
    let registration = RateLimitStore(capacity: 10, refillPerSecond: 10.0 / 3600)

    /// Brand discovery and the site probe, per device. These make the server fetch a
    /// storefront somebody named, and discovery writes a row the poller then revisits
    /// forever.
    ///
    /// Twenty in a burst, sixty an hour. Sized against the worst *legitimate* case rather
    /// than the typical one: somebody setting the app up for the first time, pasting a
    /// dozen storefronts in a sitting and checking a few of them before committing. Most of
    /// that costs nothing here anyway — the catalogue is searched first and a brand already
    /// in it is followed rather than discovered — but a limit that punishes enthusiasm on
    /// day one is a limit that gets removed rather than tuned.
    let outbound = RateLimitStore(capacity: 20, refillPerSecond: 60.0 / 3600)

    /// Everything else authenticated, per device. Four a second sustained, sixty in a
    /// burst — the app syncs on a sixty-second throttle and pages Discover by hand, so this
    /// is roughly two orders of magnitude above what it does.
    let standard = RateLimitStore(capacity: 60, refillPerSecond: 4)

    /// Usage reports, per device. Each one is a handful of upserts, so this is the budget
    /// that stops the counting route from being a way to make the database write: ten in a
    /// burst, thirty an hour. The app reports at most once every five minutes, whether on
    /// coming back, on the way out or when its token changes — twelve an hour at the very
    /// most, and one or two on an ordinary day.
    let usage = RateLimitStore(capacity: 10, refillPerSecond: 30.0 / 3600)
}

extension Application {
    private struct RateLimitsKey: StorageKey {
        typealias Value = RateLimits
    }

    /// This server's budgets. Created on first read and held for the life of the app, so
    /// every route group shares one set and a restart is the only thing that resets them.
    var rateLimits: RateLimits {
        if let existing = storage[RateLimitsKey.self] { return existing }
        let made = RateLimits()
        storage[RateLimitsKey.self] = made
        return made
    }
}
