import Foundation
import Testing

@testable import StreetwCore

/// Serves canned responses by URL path so adapters can be exercised without the network.
/// Records every request, which is how the pagination and conditional-GET tests assert
/// on what the adapter *didn't* ask for.
final class MockHTTPClient: HTTPFetching, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var etag: String?
        var finalURL: URL?
    }

    private let lock = NSLock()
    private var stubs: [String: Stub] = [:]
    private var defaultStub = Stub(status: 404)
    private(set) var requests: [(url: URL, etag: String?)] = []
    /// Bodies sent by `post`, in order. The UCP tests assert on the *request* — that the
    /// agent profile is named and that the cursor is carried — which nothing else in this
    /// suite has ever needed to do.
    private(set) var posted: [(url: URL, body: Data)] = []
    /// Successive answers for `post`, popped in order, so a paging test can hand over page
    /// one and then page two without the key having to encode a cursor nobody controls.
    private var postStubs: [Stub] = []

    /// Key is "path?query" — enough to distinguish catalog pages.
    func stub(_ key: String, _ stub: Stub) {
        lock.withLock { stubs[key] = stub }
    }

    func stub(_ key: String, fixture: String, etag: String? = nil) {
        stub(key, Stub(body: Fixtures.data(fixture), etag: etag))
    }

    /// Keyed by host as well, for the few cases where *which* host answered is the point
    /// — a store that serves its catalog on `www.` and 404s on the apex, say. A
    /// host-qualified stub wins over a bare path, so existing host-blind stubs still work
    /// as the catch-all they were written to be.
    func stub(host: String, _ key: String, _ stub: Stub) {
        lock.withLock { stubs["\(host)|\(key)"] = stub }
    }

    func stub(host: String, _ key: String, fixture: String, etag: String? = nil) {
        stub(host: host, key, Stub(body: Fixtures.data(fixture), etag: etag))
    }

    func setDefault(_ stub: Stub) {
        lock.withLock { defaultStub = stub }
    }

    /// Queues one answer for a `post`. Call once per expected round trip.
    func stubPost(_ stub: Stub) {
        lock.withLock { postStubs.append(stub) }
    }

    func stubPost(fixture: String) {
        stubPost(Stub(body: Fixtures.data(fixture)))
    }

    func stubPost(json: String) {
        stubPost(Stub(body: Data(json.utf8)))
    }

    var postedBodies: [String] {
        lock.withLock { posted.map { String(decoding: $0.body, as: UTF8.self) } }
    }

    var requestedKeys: [String] {
        lock.withLock { requests.map { Self.key(for: $0.url) } }
    }

    static func key(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.query.map { "?\($0)" } ?? ""
        return (components?.path ?? url.path) + query
    }

    func get(_ url: URL, etag: String?) async throws -> HTTPResponse {
        // Scoped locking: NSLock's lock()/unlock() pair is unavailable in async contexts.
        let stub = lock.withLock { () -> Stub in
            requests.append((url, etag))
            let path = Self.key(for: url)
            let qualified = url.host().map { "\($0)|\(path)" }
            return qualified.flatMap { stubs[$0] } ?? stubs[path] ?? defaultStub
        }

        // Honour If-None-Match the way a real origin does, so the adapter's 304 path
        // is exercised rather than simulated.
        if let etag, let stubETag = stub.etag, etag == stubETag {
            return HTTPResponse(data: Data(), status: 304, finalURL: url, etag: stubETag)
        }
        return HTTPResponse(
            data: stub.body,
            status: stub.status,
            finalURL: stub.finalURL ?? url,
            etag: stub.etag
        )
    }

    func post(_ url: URL, json body: Data, accept: String) async throws -> HTTPResponse {
        let stub = lock.withLock { () -> Stub in
            posted.append((url, body))
            // A queued answer if one is left, and a 404 once they run out — so a test that
            // stubs two pages and finds a third request asked for is told, rather than
            // being handed page two again and quietly looping.
            return postStubs.isEmpty ? Stub(status: 404) : postStubs.removeFirst()
        }
        return HTTPResponse(data: stub.body, status: stub.status, finalURL: url)
    }
}

enum Fixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            Issue.record("Missing fixture \(name)")
            return Data()
        }
        return data
    }

    static func string(_ name: String) -> String {
        String(decoding: data(name), as: UTF8.self)
    }
}

extension BrandSource {
    static func shopify(_ host: String = "https://example.com") -> BrandSource {
        BrandSource(kind: .shopify, url: URL(string: host)!)
    }
}
