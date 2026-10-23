import Foundation
import Testing

@testable import StreetwCore

@Suite("Host safety")
struct HostSafetyTests {
    @Test("Ordinary storefronts are allowed")
    func storefrontsPass() {
        for host in [
            "kith.com", "www.kith.com", "usa.palaceskateboards.com",
            "bbcicecream.com", "shop.carhartt-wip.com", "stussy.co.uk"
        ] {
            #expect(HostSafety.isPublic(host: host), "\(host) should be reachable")
        }
    }

    @Test("Loopback, private and link-local literals are refused")
    func privateLiteralsFail() {
        for host in [
            "127.0.0.1", "127.1.1.1", "0.0.0.0", "10.0.0.5", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "255.255.255.255",
            "224.0.0.1"
        ] {
            #expect(!HostSafety.isPublic(host: host), "\(host) should be refused")
        }
    }

    @Test("Public IPv4 is still allowed, so the rule is not simply 'no addresses'")
    func publicIPv4Passes() {
        #expect(HostSafety.isPublic(host: "93.184.216.34"))
        #expect(HostSafety.isPublic(host: "8.8.8.8"))
        #expect(HostSafety.isPublic(host: "172.32.0.1"))
        #expect(HostSafety.isPublic(host: "100.128.0.1"))
    }

    @Test("Private names are refused, including the one this deployment uses")
    func privateNamesFail() {
        for host in [
            "localhost", "postgres.railway.internal", "redis.internal",
            "printer.local", "router.home.arpa", "nas.lan", "app.localhost"
        ] {
            #expect(!HostSafety.isPublic(host: host), "\(host) should be refused")
        }
    }

    @Test("A name with no dot cannot be a storefront")
    func singleLabelFails() {
        #expect(!HostSafety.isPublic(host: "postgres"))
        #expect(!HostSafety.isPublic(host: "metadata"))
        // 2130706433 is 127.0.0.1 written as one integer, which URL parsers accept.
        #expect(!HostSafety.isPublic(host: "2130706433"))
    }

    /// The forms that exist specifically to walk past a check like this one.
    @Test("Alternate spellings of a loopback address are refused")
    func obfuscatedLiteralsFail() {
        #expect(!HostSafety.isPublic(host: "0177.0.0.1"))   // octal
        #expect(!HostSafety.isPublic(host: "127.0.0.01"))   // leading zero
        #expect(!HostSafety.isPublic(host: "127.1"))        // short form
        #expect(!HostSafety.isPublic(host: "0x7f.0.0.1"))   // hex
    }

    @Test("IPv6 loopback and private ranges are refused, in brackets or bare")
    func ipv6PrivateFails() {
        for host in ["::1", "[::1]", "::", "[::]", "fd00::1", "fc00::1", "fe80::1", "[fe80::1%en0]"] {
            #expect(!HostSafety.isPublic(host: host), "\(host) should be refused")
        }
    }

    @Test("An IPv4-mapped IPv6 address is judged as the IPv4 address it is")
    func mappedIPv6() {
        #expect(!HostSafety.isPublic(host: "::ffff:127.0.0.1"))
        #expect(!HostSafety.isPublic(host: "[::ffff:169.254.169.254]"))
        #expect(HostSafety.isPublic(host: "::ffff:93.184.216.34"))
    }

    @Test("Public IPv6 still resolves")
    func publicIPv6Passes() {
        #expect(HostSafety.isPublic(host: "2606:4700:4700::1111"))
        #expect(HostSafety.isPublic(host: "[2001:4860:4860::8888]"))
    }

    @Test("A trailing dot does not defeat the suffix rules")
    func trailingDot() {
        #expect(!HostSafety.isPublic(host: "postgres.railway.internal."))
        #expect(HostSafety.isPublic(host: "kith.com."))
    }

    /// The whole point of putting the check in `normalizedURL`: every user-supplied URL in
    /// the project goes through it, so neither route needs to remember.
    @Test("normalizedURL refuses what HostSafety refuses, port included")
    func normalizedURLRefuses() {
        #expect(BrandDiscovery.normalizedURL("kith.com") != nil)
        #expect(BrandDiscovery.normalizedURL("https://www.kith.com/collections/new") != nil)

        for raw in [
            "127.0.0.1", "localhost:5432", "169.254.169.254",
            "http://10.0.0.5:8080/x", "postgres.railway.internal:5432",
            "metadata.google.internal", "[::1]"
        ] {
            #expect(BrandDiscovery.normalizedURL(raw) == nil, "\(raw) should not normalise")
        }
    }
}
