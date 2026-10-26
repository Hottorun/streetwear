// AccountSection.swift
// Sign in with Apple, optional until something needs it.
//
// Nothing in the app requires an account yet. What one buys today is the one thing an
// anonymous install cannot have: a reinstall that comes back with its follows, sizes and
// watches, because the server keeps them under an identity Apple hands back. Credits and
// profiles will need it; until then it is a quiet offer near the top of You, and once taken,
// the account and the way to delete it, which Apple requires of an app that makes one.
//
// **Hidden where it cannot work.** Standalone mode has no server to keep anything on, and a
// server that cannot verify Apple's tokens refuses every sign-in — so the button is drawn only
// once the server has said it can (`AccountStatus.signInAvailable`). A signed-in account is
// always shown, so it can always be deleted.
//
// What the server says is asked by `YouView`, not here: when the section draws nothing there
// is no view for a `.task` to hang off.

import AuthenticationServices
import CryptoKit
import StreetwCore
import SwiftUI

struct AccountSection: View {
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(\.colorScheme) private var colorScheme

    /// The raw nonce for the sheet in flight. Its hash goes to Apple; the value itself goes
    /// to the server, which hashes it again and compares — see `AppleSignIn`.
    @State private var nonce: String?
    @State private var isWorking = false
    @State private var isConfirmingDelete = false
    @State private var failure: String?

    var body: some View {
        Group {
            if settings.isConfigured, settings.account != nil || remote.signInAvailable {
                VStack(alignment: .leading, spacing: 14) {
                    if let account = settings.account {
                        signedIn(account)
                    } else {
                        signedOut
                    }
                    if let failure {
                        DataLabel(text: failure.uppercased(), size: 10, color: .signal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "Account",
                note: "Sign in with Apple — keeps your follows, sizes and watches if you reinstall."
            )
            signInControl
                .disabled(isWorking)
                .opacity(isWorking ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var signInControl: some View {
        #if DEBUG
        if let subject = DebugAppleSignIn.subject(for: settings) {
            Button {
                let raw = Self.makeNonce()
                run {
                    try await signIn(
                        identityToken: DebugAppleSignIn.identityToken(subject: subject, nonce: raw),
                        authorizationCode: nil,
                        nonce: raw
                    )
                }
            } label: {
                NotificationsSection.SettingsAction(title: "Sign in as \(subject) (debug)")
            }
            .buttonStyle(.borderless)
        } else {
            appleButton
        }
        #else
        appleButton
        #endif
    }

    /// Apple's own button, as its guidelines ask, in the page's ink.
    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            let raw = Self.makeNonce()
            nonce = raw
            // No name and no email: the server stores neither, and asking for what will be
            // thrown away is asking for nothing.
            request.requestedScopes = []
            request.nonce = Self.sha256(raw)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                      let raw = nonce
                else {
                    failure = "Apple did not return a sign-in token"
                    return
                }
                let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                run { try await signIn(identityToken: token, authorizationCode: code, nonce: raw) }
            case .failure(let error):
                // Closing the sheet is a choice, not a failure.
                if (error as? ASAuthorizationError)?.code != .canceled {
                    failure = error.localizedDescription
                }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 46)
        .frame(maxWidth: 360)
    }

    private func signIn(identityToken: String, authorizationCode: String?, nonce: String) async throws {
        _ = try await remote.signInWithApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            nonce: nonce,
            sizes: sizes
        )
        self.nonce = nil
        // What the account kept — another phone's follows, a reinstall's whole list — arrives
        // with the follow list, so read it now rather than at the next foreground.
        await remote.sync(sizes: sizes.profile)
    }

    // MARK: - Signed in

    private func signedIn(_ account: AccountDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(
                title: "Account",
                note: "Your follows, sizes and watches are kept on your account, and come back if you reinstall."
            )

            VStack(alignment: .leading, spacing: 0) {
                YouRow(title: "Signed in with Apple", detail: since(account), detailColor: .ink)
            }

            Button { isConfirmingDelete = true } label: {
                NotificationsSection.SettingsAction(title: "Delete account")
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .padding(.top, 4)
            .confirmationDialog(
                "Delete your account?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    run {
                        try await remote.deleteAccount(sizes: sizes.profile)
                        // Puts this phone's brands back on the new anonymous device now,
                        // rather than at the next foreground — until then nothing would
                        // be watched for it.
                        await remote.sync(sizes: sizes.profile)
                    }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("""
                    Dropwall's server deletes your account and everything it keeps under it — \
                    follows, sizes, watches and drop dates — on every phone signed in. This phone \
                    keeps its brands and saves, and carries on without an account.
                    """)
            }
        }
    }

    private func since(_ account: AccountDTO) -> String? {
        account.createdAt.map { "SINCE \($0.formatted(.dateTime.month(.abbreviated).year()).uppercased())" }
    }

    // MARK: - Running

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            isWorking = true
            failure = nil
            do {
                try await work()
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// 32 random bytes, URL-safe. A nonce only has to be unguessable and used once.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex, which is what Apple copies into the token's `nonce` claim and what
    /// the server compares against.
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#if DEBUG
/// Sign in without Apple, for driving sign-in → merge → delete in a simulator with no Apple ID.
///
/// `-fakeAppleSignIn <subject>` builds an **unsigned** identity token naming that subject. Two
/// locks, either of which is enough: this type does not exist in a release build, and only a
/// server started with `SIWA_TEST_TOKENS=true` outside production accepts such a token —
/// every other server refuses it. It is also offered only against a server on this machine,
/// so a debug build pointed anywhere else draws Apple's real button.
enum DebugAppleSignIn {
    static func subject(for settings: ServerSettings) -> String? {
        guard let subject = UserDefaults.standard.string(forKey: "fakeAppleSignIn"), !subject.isEmpty,
              let host = settings.baseURL?.host(),
              host == "127.0.0.1" || host == "localhost"
        else { return nil }
        return subject
    }

    static func identityToken(subject: String, nonce: String) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = encode(["alg": "none"])
        let claims = encode([
            "iss": "https://appleid.apple.com",
            "aud": Bundle.main.bundleIdentifier ?? "",
            "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
            "sub": subject,
            "nonce": AccountSection.sha256(nonce)
        ])
        return "\(header).\(claims).unsigned"
    }
}
#endif
