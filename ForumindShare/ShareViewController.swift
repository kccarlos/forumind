import SwiftUI
import UIKit

/// Principal class of the share extension. Hosts `ShareSheetView`, hands the
/// chosen action to the app through `SharedInbox` and a deep link.
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

    private func hand(off action: IncomingLinkRequest.Action) {
        guard case .ready(let page) = model.phase else { return }
        let request = IncomingLinkRequest(url: page.url, action: action, title: page.title)
        let saved = SharedInbox.enqueue(request)
        model.phase = .handingOff(page, action)

        openContainingApp(IncomingLink.url(for: request)) { [weak self] opened in
            guard let self else { return }
            if opened {
                self.finish()
            } else if saved {
                self.model.phase = .saved(page)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.finish() }
            } else {
                self.model.phase = .failed(page)
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Best effort: extensions can't call `UIApplication.shared`, but the
    /// host's application object is reachable through the responder chain.
    /// Reports back on main; `false` when it failed, was declined, or never answered.
    private func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        var reported = false
        let report: (Bool) -> Void = { opened in
            DispatchQueue.main.async {
                guard !reported else { return }
                reported = true
                completion(opened)
            }
        }

        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder, !(current is UIApplication) {
            responder = current.next
        }
        guard let application = responder, application.responds(to: selector) else {
            report(false)
            return
        }

        typealias OpenURL = @convention(c) (
            AnyObject,
            Selector,
            NSURL,
            NSDictionary,
            (@convention(block) (Bool) -> Void)?
        ) -> Void
        let implementation = application.method(for: selector)
        let open = unsafeBitCast(implementation, to: OpenURL.self)
        let handler: @convention(block) (Bool) -> Void = { opened in report(opened) }
        open(application, selector, url as NSURL, NSDictionary(), handler)

        // iOS may first ask "Open in Forumind?", so the handler can
        // take as long as the user does; only guard against it never firing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { report(false) }
    }
}
