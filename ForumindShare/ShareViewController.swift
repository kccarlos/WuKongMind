import SwiftUI
import UIKit

/// Principal class of the share extension. Hosts `ShareSheetView`, hands the
/// chosen action to the app through `SharedInbox`.
final class ShareViewController: UIViewController {
    private let model = ShareSheetModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        model.onCancel = { [weak self] in self?.cancel() }
        model.onChoose = { [weak self] action in self?.hand(off: action) }

        let host = UIHostingController(rootView: ShareSheetView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        SharedPageLoader.load(from: extensionContext?.inputItems ?? []) { [weak self] page in
            self?.model.phase = page.map(ShareSheetModel.Phase.ready) ?? .unsupported
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }

    /// Extensions may not open their app, so the request waits in the App
    /// Group inbox; the app picks it up the next time it becomes active.
    private func hand(off action: IncomingLinkRequest.Action) {
        guard case .ready(let page) = model.phase else { return }
        let request = IncomingLinkRequest(url: page.url, action: action, title: page.title)
        guard SharedInbox.enqueue(request) else {
            model.phase = .failed(page)
            return
        }
        model.phase = .saved(page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
