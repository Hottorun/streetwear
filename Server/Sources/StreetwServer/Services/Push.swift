// Push.swift
// The only file that talks to Apple. Everything about *who* gets notified and *what it
// says* lives in `Notifier`, behind `PushSending`, so the fan-out is testable offline.

import APNS
import APNSCore
import Foundation
import StreetwCore
import Vapor
import VaporAPNS

/// Custom payload carried alongside the alert. The app uses it to jump straight to the
/// brand and to pull the feed without waiting for the user to open a tab.
struct PushPayload: Codable, Sendable {
    var brandID: String
    /// Bumped so a client can tell a streetw push apart from anything added later.
    var version = 1
}

struct APNSPushSender: PushSending {
    let app: Application
    /// The app's bundle ID. Wrong topic is a hard APNs rejection, not a silent drop.
    let topic: String

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
            payload: PushPayload(brandID: message.brandID.uuidString),
            sound: .default,
            threadID: message.brandID.uuidString
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
        let topic = Environment.get("APNS_TOPIC") ?? "functional.streetw"

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
