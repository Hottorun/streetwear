// ShareViewController.swift
// "Share to Dropwall" from Safari, or anywhere else that offers a link.
//
// **The save is written the moment the sheet opens, and the sheet then stays until Done.**
// Saving is never a question — the same rule `SaveConfirmation` follows in the app — so the
// inbox file exists before anything is drawn, and a sheet that is killed loses nothing. What
// the sheet offers is amending it: boards, a watch, or, on a shop's page, following the shop
// instead. Each choice rewrites the same file; Done marks it finished (`SharedSave.isComplete`).
//
// Still no network and no SwiftData. From Safari the page arrives already read
// (`ReadPage.js`), and the sheet parses it with the same `ProductPage` the app uses — so
// what it offers to watch is what the app will store. The app does all fetching when it next
// comes to the foreground (`SharedSaveImporter`). See docs/share-extension.md.

import StreetwCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Done is the way out. A swipe would leave the file marked open, and the app would
        // then wait out `SharedInbox.openSheetGrace` before filing a save that is already made.
        isModalInPresentation = true

        Task {
            let draft = await makeDraft()
            present(draft)
        }
    }

    // MARK: - Reading what was shared

    private func makeDraft() async -> ShareDraft {
        let input = await sharedInput()
        guard let url = input.url ?? input.page?.url else { return ShareDraft(failure: .noLink) }
        guard SharedInbox.isAvailable else { return ShareDraft(failure: .noContainer) }

        let title = (extensionContext?.inputItems.first as? NSExtensionItem)?
            .attributedContentText?.string
        var save = SharedSave(url: url, title: title, profileID: SharedInbox.currentProfile())
        save.version = SharedSave.currentVersion
        save.page = input.page
        save.isComplete = false
        // Into whichever profile was current in the app, so a link shared for somebody else
        // lands on their wall — and offered that profile's boards. See `SharedInbox.currentProfile`.
        let context = SharedInbox.context(for: save.profileID)
        return ShareDraft(save: save, context: context)
    }

    private struct Input {
        var url: URL?
        var page: SharedPage?
    }

    /// Safari offers the page twice: as a URL, and as the result of `ReadPage.js`. Notes and
    /// Messages often offer text with a link inside, which is how a link pasted by a friend
    /// usually arrives. All three are accepted; the page only ever adds to the address.
    private func sharedInput() async -> Input {
        var input = Input()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if input.page == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let list = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                   let results = list[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    input.page = Self.page(from: results)
                }
                if input.url == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    input.url = url
                }
                if input.url == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = firstURL(in: text) {
                    input.url = url
                }
            }
        }
        return input
    }

    /// What `ReadPage.js` returned, typed. Anything of the wrong shape is simply absent.
    private static func page(from results: [String: Any]) -> SharedPage {
        SharedPage(
            url: (results["url"] as? String).flatMap(URL.init(string:)),
            title: results["title"] as? String,
            canonical: results["canonical"] as? String,
            meta: results["meta"] as? [String: String] ?? [:],
            jsonLD: results["jsonLD"] as? [String] ?? [],
            images: results["images"] as? [String] ?? []
        )
    }

    private func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    // MARK: - The sheet

    private func present(_ draft: ShareDraft) {
        draft.start()
        let sheet = UIHostingController(rootView: ShareSheet(draft: draft) { [weak self] in
            self?.finish(draft)
        })
        sheet.view.backgroundColor = .clear
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)
    }

    private func finish(_ draft: ShareDraft) {
        draft.finish()
        if draft.failure == nil || draft.failure == .noLink {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            // Cancelling surfaces as "the share didn't happen", which is the truth when
            // the inbox couldn't be written.
            extensionContext?.cancelRequest(withError: NSError(domain: "streetw", code: 1))
        }
    }
}
