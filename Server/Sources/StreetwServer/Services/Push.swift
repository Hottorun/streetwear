// Push.swift
// The only file that talks to Apple. Everything about *who* gets notified and *what it
// says* lives in `Notifier`, behind `PushSending`, so the fan-out is testable offline.

import APNS
import APNSCore
import Foundation
import StreetwCore
import Vapor
import VaporAPNS

/// Custom payload carried alongside the alert. The app uses it to open the thing the
/// notification was about, and to pull the feed without waiting for the user to find a tab.
struct PushPayload: Codable, Sendable {
    var brandID: String
    /// The event this alert is about, when it is about exactly one — a restock, a single
    /// new drop, a fired watch. Nil for a counted summary ("3 restocks"), where there is
    /// no single product to open and the brand is the honest destination.
    ///
    /// The client keys its rows `event:<uuid>`, so this is enough to find the item it
    /// just pulled and go straight to its page.
    var eventID: String?
    /// Bumped so a client can tell a streetw push apart from anything added later.
    var version = 2
}

struct APNSPushSender: PushSending {
    let app: Application
    /// The app's bundle ID. Wrong topic is a hard APNs rejection, not a silent drop.
    let topic: String

    /// Every streetw alert shares one notification thread, so the system stacks them
    /// under the app rather than splitting them per brand.
    static let threadID = "streetw"

    func send(_ message: PushMessage) async throws {
        var notification = APNSAlertNotification(
            alert: APNSAlertNotificationContent(
                title: .raw(message.title),
                body: .raw(message.body)
            ),
            // A drop is worthless an hour later. Rather than sit in APNs' store-and-forward
            // queue indefinitely, these expire — a notification about a sold-out release is
            // worse than no notification.
            expiration: .timeIntervalSince1970InSeconds(Int(Date().timeIntervalSince1970) + 3600),
            priority: .immediately,
            topic: topic,
            payload: PushPayload(
                brandID: message.brandID.uuidString,
                eventID: message.eventID?.uuidString
            ),
            sound: .default,
            // One thread for the whole app, not one per brand.
            //
            // iOS groups by thread id *within* an app, so a per-brand id is what split
            // streetw's notifications into a separate stack for every storefront — five
            // brands meant five piles on the lock screen instead of one that says
            // "streetw · 5 notifications". Collapsing is still per brand, which is the
            // knob that actually stops one brand shouting; grouping is about how the
            // stack reads.
            threadID: Self.threadID
        )
        notification.collapseID = message.collapseID

        // Sandbox and production APNs are separate hosts with separate token namespaces,
        // and a token from one is simply invalid at the other.
        let client = message.environment == "production"
            ? app.apns.client(.production)
            : app.apns.client(.development)

        do {
            try await client.sendAlertNotification(notification, deviceToken: message.deviceToken)
        } catch let error as APNSError {
            switch error.reason {
            case .some(.badDeviceToken), .some(.unregistered), .some(.deviceTokenNotForTopic):
                throw PushDeliveryError.invalidToken
            default:
                throw error
            }
        }
    }
}

extension Application {
    /// Wires up APNs if the deployment has credentials, and returns the sender.
    ///
    /// Returns `nil` when unconfigured — which is the normal state locally and in tests.
    /// Push is an addition to the product, not a prerequisite for it: a server with no
    /// key must still poll, serve the feed and register devices.
    func configureAPNS() -> (any PushSending)? {
        guard
            let key = Environment.get("APNS_KEY_P8"),
            let keyID = Environment.get("APNS_KEY_ID"),
            let teamID = Environment.get("APNS_TEAM_ID")
        else {
            logger.notice("apns: not configured (APNS_KEY_P8/APNS_KEY_ID/APNS_TEAM_ID) — pushes disabled")
            return nil
        }

        // Required, with no default on purpose. The topic *is* the bundle ID, so a
        // default here is a value that silently goes stale the moment the app's
        // identifier changes — and a wrong topic is not a startup error, it is every
        // push being rejected by Apple long after the deploy looked healthy. Refusing to
        // enable push is the loud failure; guessing is the quiet one.
        guard let topic = Environment.get("APNS_TOPIC") else {
            logger.error("apns: APNS_TOPIC is not set (it must be the app's bundle ID) — pushes disabled")
            return nil
        }

        do {
            // Deployment platforms mangle multi-line env vars; accepting the escaped form
            // means the key can be pasted as one line without a base64 dance.
            let pem = key.replacingOccurrences(of: "\\n", with: "\n")
            apns.configure(.jwt(
                privateKey: try .loadFrom(string: pem),
                keyIdentifier: keyID,
                teamIdentifier: teamID
            ))
            logger.notice("apns: configured for topic \(topic)")
            return APNSPushSender(app: self, topic: topic)
        } catch {
            // Loud, but not fatal: a malformed key must not take the whole service down.
            logger.error("apns: could not load key — pushes disabled: \(error)")
            return nil
        }
    }
}
