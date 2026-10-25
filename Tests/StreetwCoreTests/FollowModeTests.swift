import Foundation
import Testing

@testable import StreetwCore

/// The one rule between the three modes, and the wire's tolerance for both older and newer
/// ends of it. The app has no test target, and the server and the phone both decide with
/// `admits` — so this is where the two are held to one answer.
@Suite("Follow modes")
struct FollowModeTests {
    @Test("Everything admits every kind, Quiet none, and Sales only exactly the sale kinds")
    func admitsTable() {
        for kind in UpdateKind.allCases {
            #expect(FollowMode.everything.admits(kind))
            #expect(!FollowMode.quiet.admits(kind))
            #expect(FollowMode.salesOnly.admits(kind) == kind.isSale)
        }
        // The markdown and the brand-wide sale — the case a later sale kind joins.
        #expect(UpdateKind.allCases.filter(\.isSale) == [.priceDrop, .sale])
    }

    /// A newer server may know a mode this build does not. It must not take the follow list
    /// down with it, and the safe reading of a mode nobody here understands is the one that
    /// cannot hide a drop.
    @Test("An unknown mode reads as Everything rather than failing the decode")
    func unknownModeIsEverything() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"H&M","slug":"hm.com","lockedForDrop":false,"sources":[],"followMode":"loud"}"#.utf8)
        let brand = try APICoding.decoder.decode(BrandDTO.self, from: json)
        #expect(brand.followMode == .everything)
        #expect(FollowMode(lenient: "loud") == .everything)
        #expect(FollowMode(lenient: nil) == .everything)
    }

    /// The other direction: a server that predates modes sends no key, and nil is "not said",
    /// which the client must not mistake for a decision.
    @Test("A brand from a server that predates modes carries none")
    func absentModeIsNil() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Kith","slug":"kith.com","lockedForDrop":false,"sources":[]}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandDTO.self, from: json).followMode == nil)

        let quiet = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Kith","slug":"kith.com","lockedForDrop":false,"sources":[],"followMode":"quiet"}"#.utf8)
        #expect(try APICoding.decoder.decode(BrandDTO.self, from: quiet).followMode == .quiet)
    }

    /// The body the 1.0 app sends, unchanged, must still be a follow — with no mode, which
    /// the server reads as Everything.
    @Test("A follow request with no mode still decodes, and says nothing about one")
    func oldFollowBodyDecodes() throws {
        let body = Data(#"{"brandID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#.utf8)
        #expect(try APICoding.decoder.decode(FollowBrand.self, from: body).mode == nil)

        let sent = try APICoding.encoder.encode(FollowBrand(brandID: UUID()))
        #expect(!String(decoding: sent, as: UTF8.self).contains("mode"))
    }

    @Test("Modes travel as their raw names")
    func rawValues() throws {
        let encoded = try APICoding.encoder.encode(UpdateFollow(mode: .salesOnly))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"mode":"sales"}"#)
    }
}
