import Foundation
import Testing

@testable import StreetwCore

/// What both ends say about profiles: how a name is cleaned before it is printed on every
/// alert, how an alert for somebody else reads, and that the wire tolerates an older server.
@Suite("Profiles")
struct ProfileNamingTests {
    @Test("A name is trimmed, collapsed to one line and kept short")
    func cleansNames() {
        #expect(ProfileNaming.clean("  Anna ") == "Anna")
        #expect(ProfileNaming.clean("Anna\nMaria") == "Anna Maria")
        #expect(ProfileNaming.clean("Anna   Maria") == "Anna Maria")
        #expect(ProfileNaming.clean(" \n\t ") == nil)
        #expect(ProfileNaming.clean("") == nil)
        let long = ProfileNaming.clean(String(repeating: "a", count: 40))
        #expect(long?.count == ProfileNaming.maxLength)
        // Cut at a space leaves no trailing space before the colon of the label.
        #expect(ProfileNaming.clean("Anna Maria Theresa von Hohenberg")?.hasSuffix(" ") == false)
    }

    @Test("An alert for another profile is labelled on its body")
    func labels() {
        #expect(ProfileAlert.labelled("Back in M — Box Tee", for: "Anna") == "For Anna: Back in M — Box Tee")
    }

    /// The app restores a watch from this list on a phone that has never seen the product;
    /// a server that predates the description must still decode, with the fields nil.
    @Test("A watch from an older server decodes without its product description")
    func watchDecodesLeniently() throws {
        let json = #"""
        {"id":"7A3B6C7E-0F35-4C1E-9C5A-6D1E2F3A4B5C","brandID":"1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9",
         "productExternalID":"shopify:1","createdAt":"2026-10-01T10:00:00Z","firedSizes":[]}
        """#
        let watch = try APICoding.decoder.decode(WatchDTO.self, from: Data(json.utf8))
        #expect(watch.imageURLs == nil)
        #expect(watch.variants == nil)
        #expect(watch.productURL == nil)
    }
}
