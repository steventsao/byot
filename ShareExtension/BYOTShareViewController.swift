import SwiftUI
import UIKit

/// byot's entry in the share sheet. It saves what was shared to the App Group
/// inbox and opens byot, where you choose a session and finish the message.
/// Choosing happens in the app because only the app holds server passwords.
final class BYOTShareViewController: UIViewController {
    private let model = BYOTShareExtensionModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: BYOTShareExtensionView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        model.complete = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.dismissCancelled = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        model.openApp = { [weak self] url in self?.openContainingApp(url) ?? false }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.run(items) }
    }

    /// Share extensions have no public way to open their app. The extension
    /// process's application object still handles `open(_:options:)`, which is
    /// only marked unavailable to extensions at compile time, so it's reached
    /// through the Objective-C runtime. When that fails the share stays in the
    /// inbox and byot offers it the next time it opens.
    private func openContainingApp(_ url: URL) -> Bool {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                guard let method = class_getInstanceMethod(type(of: application), selector) else { return false }
                let open = unsafeBitCast(method_getImplementation(method), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

@MainActor
final class BYOTShareExtensionModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        /// Saved, but byot couldn't be opened from here.
        case saved
        case failed(String)
    }

    @Published private(set) var phase = Phase.preparing
    var complete: () -> Void = {}
    var dismissCancelled: () -> Void = {}
    var openApp: (URL) -> Bool = { _ in false }
    /// Set by Cancel. Reading and saving keep going in the background, so
    /// they check this before handing anything to byot.
    private var isCancelled = false

    func cancel() {
        isCancelled = true
        dismissCancelled()
    }

    func run(_ items: [NSExtensionItem]) async {
        let result = await BYOTShareImport.load(items)
        guard !isCancelled else { return }
        guard !result.isEmpty else {
            phase = .failed(result.notes.first ?? BYOTShareInboxError.empty.localizedDescription)
            return
        }
        guard let inbox = BYOTShareInbox.appGroup else {
            phase = .failed(BYOTShareInboxError.unavailable.localizedDescription)
            return
        }
        do {
            let item = try await Task.detached(priority: .userInitiated) {
                try inbox.save(text: result.text, attachments: result.attachments, notes: result.notes)
            }.value
            guard !isCancelled else {
                inbox.remove(item.id)
                return
            }
            if openApp(BYOTShareLink(shareID: item.id).url) { complete() } else { phase = .saved }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct BYOTShareExtensionView: View {
    @ObservedObject var model: BYOTShareExtensionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BYOTBrand.Space.md) {
                    status
                }
                .frame(maxWidth: 420)
                .padding(BYOTBrand.Space.lg)
                .frame(maxWidth: .infinity, minHeight: 280)
                .accessibilityElement(children: .combine)
            }
            .background(BYOTBrand.canvas)
            .animation(reduceMotion ? nil : .smooth(duration: BYOTBrand.Motion.quick), value: model.phase)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BYOTWordmark() }
                ToolbarItem(placement: model.phase == .preparing ? .cancellationAction : .confirmationAction) {
                    if model.phase == .preparing {
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button("Done", action: model.complete)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .preparing:
            ProgressView()
                .controlSize(.large)
            Text("Getting this ready for byot…")
                .font(.cleanBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(BYOTBrand.accent)
                .accessibilityHidden(true)
            Text("Saved for byot")
                .font(.cleanTitle)
                .multilineTextAlignment(.center)
            Text("Open byot to choose a session and send it. byot keeps it for two days.")
                .font(.cleanBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Couldn’t share to byot")
                .font(.cleanTitle)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.cleanBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
