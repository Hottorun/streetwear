// ServerSettingsView.swift
// The alerts row, and the honest reporting behind it.
//
// This file used to also hold an editable server address. That is gone: the app ships
// pointing at its own backend, there is one correct value, and a text field inviting
// someone to change it offered a way to break the app in exchange for nothing. The
// diagnostics it carried were worth keeping and live in the alerts section now.

import StreetwCore
import SwiftData
import SwiftUI
import UserNotifications

/// Alerts, and whether they can actually arrive.
///
/// Three things have to line up and they fail independently: iOS has to have granted
/// permission, the phone has to have handed a token to the server, and the server has to
/// hold an APNs key. Any one missing means total silence, and from this screen all three
/// look identical unless they are reported separately — which is exactly how the app
/// shipped with no `aps-environment` entitlement and eleven tokenless devices while every
/// status indicator read green.
struct NotificationsSection: View {
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isRequesting = false
    @State private var delivery: DeliveryState = .unknown

    private enum DeliveryState: Equatable {
        case unknown
        case ok
        /// The server has no APNs key, so nothing is ever sent.
        case noKey
        /// No device has handed over a token — this end of the pipe is the broken one.
        case noToken
        case unreachable
    }

    var body: some View {
        Section {
            switch status {
            case .authorized, .provisional, .ephemeral:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Alerts on", systemImage: "bell.fill")
                        .foregroundStyle(.green)
                    // Permission granted is not the same as deliverable, and saying
                    // "Alerts on" while nothing can arrive is the lie worth avoiding.
                    switch delivery {
                    case .noKey:
                        Text("The server has no push key, so nothing is being sent.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .noToken:
                        Text("This device hasn't registered for push yet — reopen the app to retry.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .unreachable:
                        Text("Can't reach the server right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .ok, .unknown:
                        EmptyView()
                    }
                }
            case .denied:
                // Once denied, the prompt never comes back — only Settings can undo it,
                // so offering the button again would be a dead end.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Alerts off", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Turn on in Settings", destination: url)
                            .font(.caption)
                    }
                }
            default:
                Button {
                    Task {
                        isRequesting = true
                        await PushAuthorization.request()
                        status = await PushAuthorization.current()
                        isRequesting = false
                    }
                } label: {
                    Label("Turn on drop alerts", systemImage: "bell.badge")
                }
                .buttonStyle(.borderless)
                .disabled(isRequesting || !settings.isConfigured)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Get told when a brand you follow drops, restocks in your size, or locks its storefront.")
        }
        .task {
            status = await PushAuthorization.current()
            delivery = await checkDelivery()
        }
    }

    /// Asks the server whether a push could actually reach anyone.
    private func checkDelivery() async -> DeliveryState {
        guard let baseURL = settings.baseURL else { return .unreachable }
        do {
            let status = try await StreetwAPI(baseURL: baseURL, token: settings.token).status()
            if status.apnsConfigured != true { return .noKey }
            // Nil rather than zero on a server that predates the field — not knowing is
            // not the same as knowing it's broken, so stay quiet.
            if let tokens = status.devicesWithToken, tokens == 0 { return .noToken }
            return .ok
        } catch {
            return .unreachable
        }
    }
}
