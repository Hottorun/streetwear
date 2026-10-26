import Foundation
import Testing

@testable import StreetwCore

@Suite("Credits")
struct CreditsTests {
    /// 2026-10-24 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_792_843_200)

    @Test("A month is the UTC calendar month")
    func monthIsUTC() {
        #expect(CreditMonth.key(of: noon) == "2026-10")
        #expect(CreditMonth.key(of: Date(timeIntervalSince1970: 0)) == "1970-01")
        // 23:59:59 on the 31st UTC is still October, wherever the phone is.
        let lastSecond = Date(timeIntervalSince1970: 1_793_491_199)
        #expect(CreditMonth.key(of: lastSecond) == "2026-10")
        #expect(CreditMonth.key(of: lastSecond.addingTimeInterval(1)) == "2026-11")
    }

    @Test("A month starts at midnight UTC on the first")
    func monthStart() {
        let start = CreditMonth.start(of: noon)
        #expect(start == Date(timeIntervalSince1970: 1_790_812_800)) // 2026-10-01T00:00:00Z
        #expect(CreditMonth.key(of: start) == "2026-10")
        #expect(CreditMonth.key(of: start.addingTimeInterval(-1)) == "2026-09")
        #expect(CreditMonth.start(of: start) == start)
    }

    @Test("An action this build has never heard of still decodes, and still prints")
    func unknownActionsSurvive() throws {
        let json = Data(#"[{"action":"search","count":23},{"action":"try_on","count":1}]"#.utf8)
        let usage = try JSONDecoder().decode([CreditUsage].self, from: json)
        #expect(usage.map(\.action) == ["search", "try_on"])
        #expect(CreditAction(usage[0].action).label(count: 23) == "searches")
        #expect(CreditAction(usage[1].action).label(count: 1) == "action")
        #expect(CreditAction.search.label(count: 1) == "search")
    }

    @Test("An action encodes as its bare name")
    func actionIsAString() throws {
        let data = try JSONEncoder().encode([CreditAction.scan])
        #expect(String(decoding: data, as: UTF8.self) == #"["scan"]"#)
    }

    @Test("An anonymous device's summary is one field")
    func anonymousSummary() throws {
        let decoded = try APICoding.decoder.decode(CreditsSummary.self, from: Data(#"{"signedIn":false}"#.utf8))
        #expect(decoded == CreditsSummary(signedIn: false))
        #expect(decoded.balance == nil && decoded.packs == nil)
    }
}
