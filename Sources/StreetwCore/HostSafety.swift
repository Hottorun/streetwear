// HostSafety.swift
// Which hosts a stranger is allowed to make this software fetch.
//
// `POST /v1/brands/discover` and `GET /v1/brands/probe` exist so somebody can name a
// storefront the catalogue has never seen. The server then fetches it — and until this
// file, "it" was anything at all: `BrandDiscovery.normalizedURL` forced the scheme to
// `https`, stripped the path, and passed the host through untouched, port included. So
// `127.0.0.1`, `169.254.169.254`, `[::1]` and `postgres.railway.internal:5432` were all
// valid brands, and on this deployment that private network is where the database lives.
//
// It was not blind, either. The discover response carries the target's `og:site_name` or
// `<title>` back as `suggestedName`, so whatever answered could be read; and the discover
// route *writes a permanent brand row*, which the poller then re-fetches every twenty
// minutes for as long as it exists.
//
// The device-token tier was no barrier — `POST /v1/devices` is unauthenticated and mints a
// token per call. So this is the barrier.
//
// Deliberately pure string and integer arithmetic: `StreetwCore` compiles on Linux against
// swift-corelibs-foundation, and anything that reached for `Network` or a resolver would
// break the deploy rather than this machine. It also means the whole thing is testable
// without a socket, which is the only way a rule like this stays correct.

import Foundation

public enum HostSafety {
    /// Whether a host may be fetched on behalf of somebody who typed it.
    ///
    /// The answer is about *reachability*, not about whether a brand lives there: a public
    /// host that turns out to serve nothing is discovery's problem and is handled by
    /// discovery. This only refuses the addresses that are interesting for reasons that
    /// have nothing to do with clothes.
    public static func isPublic(host rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            // A trailing dot is a legal fully-qualified name and would otherwise defeat
            // every suffix check below.
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return false }

        // IPv6 arrives bracketed from `URLComponents.host` on some paths and bare on
        // others; a zone index (`%en0`) is never meaningful to us.
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        let unzoned = bare.split(separator: "%", maxSplits: 1).first.map(String.init) ?? bare
        if unzoned.contains(":") { return isPublicIPv6(unzoned) }

        // **A name with no dot cannot be a storefront.** It is a container, a service
        // alias on a private network, or an integer-encoded address (`2130706433` is
        // `127.0.0.1`, and every URL parser accepts it). Refusing the whole shape is both
        // simpler and safer than trying to enumerate the ways one can be spelled.
        let labels = unzoned.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return false }

        // Anything whose last label is numeric is an address being written as a name — a
        // real domain never has a numeric TLD. Such a host has to parse as a genuine
        // dotted quad *and* be publicly routable; "0177.0.0.1" satisfies neither and is
        // refused here rather than being read as a domain because it happens to have dots.
        if labels.last?.allSatisfy(\.isNumber) == true {
            guard let quad = ipv4(unzoned) else { return false }
            return isPublicIPv4(quad)
        }

        // Names that are private by definition. `.local` is mDNS, `.internal` is what
        // every cloud provider hands out on its private network (Railway included),
        // `.home.arpa` is the RFC 8375 home-network name, and `.lan` is convention.
        let privateSuffixes = [".internal", ".local", ".localhost", ".home.arpa", ".lan"]
        if privateSuffixes.contains(where: { unzoned.hasSuffix($0) }) { return false }

        return true
    }

    /// Convenience for the shape the rest of the code actually holds.
    public static func isPublic(url: URL) -> Bool {
        guard let host = url.host() else { return false }
        return isPublic(host: host)
    }

    // MARK: - Addresses

    private static func ipv4(_ text: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            // No leading zeros: "010" is octal to some resolvers and decimal to others,
            // and a disagreement about that is exactly how a check like this is walked past.
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  part.count == 1 || !part.hasPrefix("0"),
                  let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    private static func isPublicIPv4(_ quad: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = quad
        switch a {
        case 0:                     return false   // "this network"
        case 10:                    return false   // RFC 1918
        case 127:                   return false   // loopback
        case 100 where (64...127).contains(b):
                                    return false   // RFC 6598 carrier-grade NAT
        case 169 where b == 254:    return false   // link-local — the metadata endpoint
        case 172 where (16...31).contains(b):
                                    return false   // RFC 1918
        case 192 where b == 0:      return false   // IETF protocol assignments
        case 192 where b == 168:    return false   // RFC 1918
        case 198 where (18...19).contains(b):
                                    return false   // benchmarking
        case 224...255:             return false   // multicast, reserved, broadcast
        default:                    return true
        }
    }

    private static func isPublicIPv6(_ text: String) -> Bool {
        // The unspecified address and loopback, in any legal spelling.
        let collapsed = text.replacingOccurrences(of: "0", with: "")
        if text == "::1" || text == "::" || collapsed == "::" || collapsed == "::1" {
            return false
        }
        // An IPv4-mapped address is an IPv4 address; reading it as "some IPv6 host" is how
        // `::ffff:127.0.0.1` gets through a check that only looked at the family.
        if let mapped = text.split(separator: ":").last, mapped.contains(".") {
            guard let quad = ipv4(String(mapped)) else { return false }
            return isPublicIPv4(quad)
        }
        // fc00::/7 unique-local and fe80::/10 link-local.
        if text.hasPrefix("fc") || text.hasPrefix("fd") { return false }
        if ["fe8", "fe9", "fea", "feb"].contains(where: { text.hasPrefix($0) }) { return false }
        return true
    }
}
