// ProfilesSection.swift
// The people on this account, and which one the app is being right now.
//
// **A profile is a person; a mood is a board** (`ROADMAP.md`). Shopping for somebody else needs
// their own sizes, gender filter, brands, saves, taste and alerts — so a profile is all of
// those, and switching changes every one of them at once. A mood is the same person, and stays
// a board.
//
// Drawn only when signed in: profiles live on the account, so an install that never signed in
// has exactly one implicit profile and this page says nothing about profiles at all. See
// `docs/profiles.md`.

import StreetwCore
import SwiftUI

struct ProfilesSection: View {
    @Environment(ProfileStore.self) private var profiles: ProfileStore
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @State private var isAdding = false
    @State private var newName = ""
    @State private var renaming: ProfileDTO?
    @State private var renameText = ""
    @State private var deleting: ProfileDTO?

    var body: some View {
        if settings.account != nil, !profiles.profiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SettingsHeader(
                    title: "Profiles",
                    note: "Each profile keeps its own sizes, brands, saves and alerts. Alerts for somebody else start with their name."
                )

                VStack(spacing: 0) {
                    ForEach(profiles.profiles) { profile in
                        row(profile)
                    }
                }

                if profiles.profiles.count < Profiles.maxPerAccount {
                    Button {
                        newName = ""
                        isAdding = true
                    } label: {
                        NotificationsSection.SettingsAction(title: "Add a profile")
                    }
                    .buttonStyle(.borderless)
                    .disabled(profiles.isWorking)
                    .padding(.top, 4)
                }

                if let failure = profiles.failure {
                    DataLabel(text: failure.uppercased(), size: 10, color: .signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .alert("Add a profile", isPresented: $isAdding) {
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Add") { Task { await profiles.create(named: newName) } }
                    .disabled(ProfileNaming.clean(newName) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Somebody you shop for. Their sizes, brands and saves start empty.")
            }
            .alert(
                "Rename",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Name", text: $renameText)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    if let profile = renaming {
                        Task { await profiles.rename(profile, to: renameText) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(renaming?.isHolder == true
                    ? "Leave it empty to be \u{201C}You\u{201D}."
                    : "Printed at the start of this profile's alerts.")
            }
            .confirmationDialog(
                "Delete \(deleting.map(Self.title) ?? "this profile")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete profile", role: .destructive) {
                    if let profile = deleting {
                        Task { await profiles.delete(profile) }
                    }
                    deleting = nil
                }
                Button("Keep", role: .cancel) { deleting = nil }
            } message: {
                Text("""
                    Its brands, watches and drop dates are deleted from Dropwall's server, and its \
                    saves, boards and fits from this phone. Your own profile is not touched.
                    """)
            }
        }
    }

    // MARK: - A row

    private func row(_ profile: ProfileDTO) -> some View {
        let isCurrent = profiles.current.id == (profile.isHolder ? nil : profile.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                profiles.switchTo(profile)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.title(profile))
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    if !profile.alertsEnabled {
                        DataLabel(text: "ALERTS OFF", size: 10)
                    }
                    // The accent is for things happening now, and being somebody is not news:
                    // the current profile is said in ink, the others offer to switch.
                    DataLabel(text: isCurrent ? "CURRENT" : "SWITCH", size: 10, color: isCurrent ? .ink : .muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(isCurrent || profiles.isWorking)

            Menu {
                Button("Rename…") {
                    renameText = profile.name ?? ""
                    renaming = profile
                }
                Button(profile.alertsEnabled ? "Turn alerts off" : "Turn alerts on") {
                    Task { await profiles.setAlerts(!profile.alertsEnabled, for: profile) }
                }
                // The holder's profile goes only with the account, which is below.
                if !profile.isHolder {
                    Button("Delete profile…", role: .destructive) { deleting = profile }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.muted)
                    .frame(width: 32, height: 28)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(Self.title(profile)) options")
            .disabled(profiles.isWorking)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rule() }
    }

    /// The holder is "You" until they name themselves.
    static func title(_ profile: ProfileDTO) -> String {
        profile.name ?? (profile.isHolder ? "You" : "Profile")
    }
}
