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
    /// The one alert decided on this phone rather than by the server — see `PriceAlerts`.
    @AppStorage(PriceAlerts.settingKey) private var savedPriceDrops = true
    /// The morning's picks, scheduled on this phone too — and **off** unless asked for, because
    /// nobody asked for picks in the first place. See `PicksNotice`.
    @AppStorage(PicksNotice.settingKey) private var dailyPicks = false

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
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(title: "Alerts", info: Self.info)

            switch status {
            case .authorized, .provisional, .ephemeral:
                VStack(alignment: .leading, spacing: 7) {
                    DataLabel(text: "ALERTS ON", size: 11, color: .ink)
                    // Permission granted is not the same as deliverable, and saying
                    // "Alerts on" while nothing can arrive is the lie worth avoiding.
                    // Vermilion for the two states somebody can act on; muted for the one
                    // that is only the network having a bad minute.
                    switch delivery {
                    case .noKey:
                        DataLabel(text: "NOT SENDING · THE SERVER HAS NO PUSH KEY", size: 10, color: .signal)
                    case .noToken:
                        DataLabel(text: "NOT REGISTERED YET · REOPEN TO RETRY", size: 10, color: .signal)
                    case .unreachable:
                        DataLabel(text: "CAN'T REACH THE SERVER", size: 10)
                    case .ok, .unknown:
                        EmptyView()
                    }
                }
            case .denied:
                // Once denied, the prompt never comes back — only Settings can undo it,
                // so offering the button again would be a dead end.
                VStack(alignment: .leading, spacing: 9) {
                    DataLabel(text: "ALERTS OFF", size: 11)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            SettingsAction(title: "Turn on in Settings")
                        }
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
                    SettingsAction(title: "Turn on drop alerts")
                }
                .buttonStyle(.plain)
                .disabled(isRequesting || !settings.isConfigured)
            }

            // Its own switch because it is the one alert about your collection rather than
            // about a brand — and the only one the server never sees, since saves stay here.
            Toggle(isOn: $savedPriceDrops) {
                Text("Price drops on things you saved")
                    .font(.editorial(15))
                    .foregroundStyle(Color.ink)
            }

            Toggle(isOn: $dailyPicks) {
                Text("Today’s picks, in the morning")
                    .font(.editorial(15))
                    .foregroundStyle(Color.ink)
            }
            .onChange(of: dailyPicks) { _, on in
                Task {
                    if on {
                        // Asked here because it was asked for: switching an alert on is the
                        // one moment a permission prompt is the answer to something.
                        if status == .notDetermined {
                            await PushAuthorization.request()
                            status = await PushAuthorization.current()
                        }
                    } else {
                        await PicksNotice.withdrawAll()
                    }
                }
            }
        }
        .task {
            status = await PushAuthorization.current()
            delivery = await checkDelivery()
        }
    }

    /// What each alert is, and the two decided on this phone — said once, behind the ⓘ.
    static let info = InfoNote(
        title: "Alerts",
        lines: [
            "A shop you follow drops something, goes on sale or locks its storefront, and something you watch comes back.",
            "Price drops on things you saved are worked out on this phone — your saves never leave it.",
            "Today's picks: once a morning, never on a day you've already seen them."
        ]
    )

    /// The one shape a settings screen uses for something you can press.
    ///
    /// A rule under a line of type rather than a filled `.bordered` button: the page is
    /// paper, and a system button on it reads as a fragment of another app.
    ///
    /// File scope rather than nested, since `AboutSection` presses things too and two
    /// copies of one shape is how two shapes happen.
    struct SettingsAction: View {
        let title: String

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.editorial(17))
                    .foregroundStyle(Color.ink)
                Rectangle()
                    .fill(Color.ink)
                    .frame(height: 1)
            }
            .fixedSize()
        }
    }

    /// Asks the server whether a push could actually reach anyone.
    private func checkDelivery() async -> DeliveryState {
        guard let baseURL = settings.baseURL else { return .unreachable }
        do {
            // Asks about *this* device rather than about everybody. The old check read
            // `/status`, which reports the environment, the user count and the database
            // error verbatim — a description of the deployment handed to anyone who asked,
            // for two booleans. It also answered the wrong question: a global
            // `devicesWithToken > 0` is satisfied by somebody else's phone while yours has
            // no token at all.
            let status = try await StreetwAPI(baseURL: baseURL, token: settings.token).delivery()
            if !status.apnsConfigured { return .noKey }
            if !status.hasToken { return .noToken }
            return .ok
        } catch {
            return .unreachable
        }
    }
}

/// What the app is, where its promises are written down, and which build this is.
///
/// **None of this was reachable from inside the app.** The privacy policy and the support
/// page exist and are live, and App Store Connect has their URLs — but a person holding the
/// app had no route to either, and no build number to quote to anybody. Reviewers look for
/// this and users ask for it, and it costs a section.
///
/// The privacy line is here rather than scattered because the app makes a real promise and
/// was making it in three places at once ("Boards are private", "Nothing is shared
/// anywhere", "Saved as a link, never scraped") without ever saying the whole of it.
struct AboutSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(AIStore.self) private var ai: AIStore

    private static let privacy = URL(string: "https://www.hottorun.com/dropwall/privacy")!
    private static let support = URL(string: "https://www.hottorun.com/dropwall/support")!

    /// Read from the bundle rather than hardcoded, so it cannot drift from what was shipped.
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// The promise, said whole, once — the app was making it in pieces in three places
    /// ("Boards are private", "Nothing is shared anywhere", "Saved as a link, never scraped").
    private var privacyNote: InfoNote {
        InfoNote(
            title: "What stays on this phone",
            lines: [
                "Your saves, boards, fits and what you write about your style stay on this phone.",
                "Only the brands you follow and your sizes reach the server, so it knows what to watch and when to wake you.",
                "Signed in with Apple, the server also keeps the anonymous ID Apple gives Dropwall — no name, no email."
            ],
            link: .init(title: "Privacy policy", url: Self.privacy)
        )
    }

    private var aiNote: InfoNote {
        InfoNote(
            title: "What goes to the AI",
            lines: [
                "What you ask Dropwall's AI — a description, a reply, a photograph you choose to send — goes through the server to Anthropic, which answers it.",
                "The server keeps none of it.",
                "Today's picks send a short description of your piece, never a photograph."
            ],
            link: .init(title: "Privacy policy", url: Self.privacy)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "About",
                note: "DROPWALL \(version)"
            )

            VStack(spacing: 0) {
                PlainInfoRow(title: "What stays on this phone", note: privacyNote)
                // Only where there is an AI to ask: the exception to the promise above.
                if ai.isAvailable {
                    PlainInfoRow(title: "What goes to the AI", note: aiNote)
                }
            }

            Button { openURL(Self.privacy) } label: {
                NotificationsSection.SettingsAction(title: "Privacy policy")
            }
            .buttonStyle(.borderless)

            Button { openURL(Self.support) } label: {
                NotificationsSection.SettingsAction(title: "Support")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// A row that opens a short sheet — the You page's way of keeping a statement a tap away.
struct PlainInfoRow: View {
    let title: String
    let note: InfoNote

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            YouRow(title: title, chevron: true)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $isShowing) { InfoSheet(note: note) }
    }
}
