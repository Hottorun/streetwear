// ServerSettingsView.swift
// Point the app at a streetw server, and show honestly whether it's actually working.

import StreetwCore
import SwiftData
import SwiftUI

struct ServerSettingsSection: View {
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    @State private var draft = ""
    @State private var probe: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle
        case checking
        case ok(StatusSummary)
        case failed(String)
    }

    struct StatusSummary: Equatable {
        var database: String
        var connected: Bool
        var brands: Int
        var products: Int
        var pollerRunning: Bool
    }

    var body: some View {
        Section {
                TextField("streetw-server.up.railway.app", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(save)

                HStack {
                    Button("Connect", systemImage: "antenna.radiowaves.left.and.right", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if settings.isRegistered {
                        Label("Device registered", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                switch probe {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack {
                        ProgressView()
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                case .ok(let summary):
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            "Connected · \(summary.database)",
                            systemImage: summary.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(summary.connected ? .green : .orange)
                        Text("\(summary.brands) brands · \(summary.products) products · poller \(summary.pollerRunning ? "running" : "off")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Ephemeral SQLite in production silently loses everything on
                        // redeploy, so say it out loud rather than showing a green tick.
                        if summary.database != "postgres" {
                            Text("Server is not using Postgres — data will be lost on redeploy.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(settings.isConfigured
                     ? "Brands are watched by the server, so drops arrive even when the app is closed."
                     : "Without a server the app checks brands itself, and only while it's open.")
            }
        .task(id: settings.baseURLString) {
            if draft.isEmpty { draft = settings.baseURLString }
            if settings.isConfigured { await check() }
        }
    }

    private func save() {
        settings.baseURLString = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await check() }
    }

    private func check() async {
        guard let baseURL = settings.baseURL else { return }
        probe = .checking
        do {
            let status = try await StreetwAPI(baseURL: baseURL, token: settings.token).status()
            probe = .ok(
                StatusSummary(
                    database: status.database,
                    connected: status.databaseConnected,
                    brands: status.brands,
                    products: status.products,
                    pollerRunning: status.pollerRunning
                )
            )
            // Registering here means the first sync isn't the thing that discovers a
            // broken URL.
            try? await remote.ensureRegistered(sizes: sizes.profile)
        } catch {
            probe = .failed(error.localizedDescription)
        }
    }
}
