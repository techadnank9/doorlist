import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry: pull the Luma link out of what was shared and run the
/// same booking flow as the app, right inside the sheet.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor in
            let text = await sharedText()
            // A screenshot (and no event link): write the reply to what's on it.
            if text.flatMap({ EventLink.find(in: $0, allowAnySite: true) }) == nil, let image = await sharedImage() {
                let close: () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
                embed(ReplyView(image: image, onClose: close))
                return
            }
            show(input: text ?? "")
        }
    }

    private func show(input: String) {
        let close: () -> Void = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        // Partiful, Eventbrite and other sites book on their own page, which needs the app.
        if let link = EventLink.find(in: input, allowAnySite: true), link.platform != .luma {
            PendingLinks.add(link.url)
            Notifier.finishInApp(nil, url: link.url)
            embed(HandOffView(platform: link.platform, onClose: close))
            return
        }
        embed(BookingFlowView(model: BookingFlowModel(input: input), inExtension: true, onClose: close))
    }

    private func embed<V: View>(_ root: V) {
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// The first image shared, as Photos and the screenshot editor hand it over (a file URL, data or an image).
    private func sharedImage() async -> UIImage? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { continue }
            if let image = item as? UIImage { return image }
            if let data = item as? Data, let image = UIImage(data: data) { return image }
            if let url = item as? URL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
        }
        return nil
    }

    /// The first URL or text in the shared items that contains a Luma link.
    private func sharedText() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var fallback: String?
        for provider in providers {
            for type in [UTType.url, UTType.plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { continue }
                let text: String? = (item as? URL)?.absoluteString ?? (item as? String)
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text else { continue }
                if EventLink.find(in: text, allowAnySite: true) != nil { return text }
                fallback = fallback ?? text
            }
        }
        return fallback
    }
}

/// Shown when a link needs the app to book: it's saved and a notification opens it.
private struct HandOffView: View {
    let platform: EventPlatform
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Saved for Doorlist").font(.title2.weight(.bold))
            Text("\(platform == .web ? "This site" : platform.name) books on its own page, so it finishes in the app. Tap the notification or open Doorlist and it'll be waiting with your answers filled in.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done", action: onClose).buttonStyle(.primary)
        }
        .padding(Theme.gutter)
    }
}
