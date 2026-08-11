// ShareViewController.swift
// "Share to streetw" from Safari, or anywhere else that offers a link.
//
// The extension does as little as possible: pull the URL out, write it to the App Group
// inbox, confirm, dismiss. No network, no SwiftData, no image fetching — an extension
// runs under a hard memory limit and is expected back almost immediately, and a share
// sheet that spins is one people stop using. The app enriches the link with its title
// and photograph when it next comes to the foreground (`SharedSaveImporter`).

import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        Task {
            let outcome = await save()
            present(outcome)
        }
    }

    // MARK: - Extracting the link

    private func save() async -> Outcome {
        guard let url = await sharedURL() else { return .noLink }
        guard SharedInbox.isAvailable else { return .noContainer }

        let title = (extensionContext?.inputItems.first as? NSExtensionItem)?
            .attributedContentText?.string
        return SharedInbox.append(SharedSave(url: url, title: title)) ? .saved : .failed
    }

    /// Safari offers the page as a URL; Notes and Messages often offer it as text with a
    /// link inside. Both are worth accepting — the second is how a link pasted by a
    /// friend usually arrives.
    private func sharedURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    return url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(
                    forTypeIdentifier: UTType.plainText.identifier
                   ) as? String,
                   let url = firstURL(in: text) {
                    return url
                }
            }
        }
        return nil
    }

    private func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    // MARK: - Confirming

    private func present(_ outcome: Outcome) {
        let confirmation = UIHostingController(rootView: ShareConfirmation(outcome: outcome))
        confirmation.view.backgroundColor = .clear
        addChild(confirmation)
        confirmation.view.frame = view.bounds
        confirmation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(confirmation.view)
        confirmation.didMove(toParent: self)

        // Long enough to read, short enough not to be in the way. A failure gets longer,
        // because it is the only chance to say what went wrong.
        Task {
            try? await Task.sleep(for: .seconds(outcome == .saved ? 0.9 : 1.8))
            finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        if outcome == .saved || outcome == .noLink {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            // Cancelling surfaces as "the share didn't happen", which is the truth when
            // the inbox couldn't be written.
            extensionContext?.cancelRequest(withError: NSError(domain: "streetw", code: 1))
        }
    }

    enum Outcome: Equatable {
        case saved
        case noLink
        case noContainer
        case failed

        var headline: String {
            switch self {
            case .saved: "Saved"
            case .noLink: "Nothing to save"
            case .noContainer: "streetw can't reach its storage"
            case .failed: "Couldn't save that"
            }
        }

        var detail: String {
            switch self {
            case .saved: "IT'S IN YOUR COLLECTION"
            case .noLink: "THIS DOESN'T CONTAIN A LINK"
            case .noContainer: "REINSTALL THE APP TO FIX IT"
            case .failed: "TRY AGAIN"
            }
        }
    }
}

/// Same voice as the app: a serif line for what happened, mono for the detail.
/// The design system lives in the app target, so the few values it needs are restated
/// here rather than dragging the whole file into a second target.
private struct ShareConfirmation: View {
    let outcome: ShareViewController.Outcome

    private var ink: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black }) }

    var body: some View {
        VStack(spacing: 8) {
            Text(outcome.headline)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(ink)
            Text(outcome.detail)
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
