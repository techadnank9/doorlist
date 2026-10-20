import SwiftUI
import WebKit

/// The event sites besides Luma that Doorlist can book on. Signing in here, on the site's own page,
/// leaves the site's login in the app's web storage, which the booking browser shares, so a later
/// booking on that site starts signed in. Luma stays the main flow and has its own row above this.
struct ConnectedSite: Identifiable {
    let id: String
    let name: String
    let signIn: URL
    /// Cookie domains that belong to the site, for checking and forgetting its login.
    let domains: [String]

    static let all: [ConnectedSite] = [
        .init(id: "partiful", name: "Partiful", signIn: URL(string: "https://partiful.com/login")!, domains: ["partiful.com"]),
        .init(id: "cerebralvalley", name: "Cerebral Valley", signIn: URL(string: "https://cerebralvalley.ai/auth/login")!, domains: ["cerebralvalley.ai"]),
        .init(id: "yc", name: "Y Combinator", signIn: URL(string: "https://account.ycombinator.com/")!, domains: ["ycombinator.com"]),
        .init(id: "eventbrite", name: "Eventbrite", signIn: URL(string: "https://www.eventbrite.com/signin/")!, domains: ["eventbrite.com"]),
        .init(id: "meetup", name: "Meetup", signIn: URL(string: "https://www.meetup.com/login/")!, domains: ["meetup.com"]),
        .init(id: "devpost", name: "Devpost", signIn: URL(string: "https://devpost.com/users/login")!, domains: ["devpost.com"]),
        .init(id: "mlh", name: "MLH", signIn: URL(string: "https://www.mlh.com/signin")!, domains: ["mlh.com", "mlh.io"]),
        .init(id: "devfolio", name: "Devfolio", signIn: URL(string: "https://devfolio.co/signin")!, domains: ["devfolio.co"]),
    ]

    private var key: String { "connectedSite.\(id)" }

    /// Set when the person taps Done after signing in. Sites set cookies before anyone signs in,
    /// so there's no reliable way to check a login from outside; this records what the person did.
    var isConnected: Bool { UserDefaults.standard.bool(forKey: key) }

    func markConnected(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }

    /// Forgets this site's login in the app's web storage.
    @MainActor func forget() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { record in domains.contains { record.displayName.contains($0.components(separatedBy: ".").first ?? $0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
        markConnected(false)
    }
}

struct ConnectedSitesView: View {
    @State private var signingIn: ConnectedSite?
    /// Ids of the sites marked connected, re-read whenever that may have changed.
    @State private var connected: Set<String> = []
    @State private var disconnecting: ConnectedSite?

    var body: some View {
        List {
            Section {
                ForEach(ConnectedSite.all) { site in
                    let isConnected = connected.contains(site.id)
                    Button {
                        if isConnected { disconnecting = site } else { signingIn = site }
                    } label: {
                        HStack {
                            Text(site.name).foregroundStyle(.primary)
                            Spacer()
                            if isConnected {
                                Label("Connected", systemImage: "checkmark.seal.fill")
                                    .labelStyle(.titleAndIcon).font(.subheadline).foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .swipeActions {
                        if isConnected {
                            Button("Disconnect", role: .destructive) {
                                Task { await site.forget(); reloadConnected() }
                            }
                        }
                    }
                    .accessibilityHint(isConnected ? "Asks to disconnect \(site.name)" : "Opens \(site.name)'s sign-in page")
                }
            } footer: {
                Text("Sign in once on the site's own page and bookings there start signed in. Logins stay on this phone and never sync. Tap a connected site to disconnect it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .listStyle(.insetGrouped)
        .navigationTitle("Other event sites")
        .sheet(item: $signingIn, onDismiss: reloadConnected) { site in
            SiteSignInSheet(site: site)
        }
        .confirmationDialog(disconnecting.map { "Disconnect \($0.name)?" } ?? "",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible, presenting: disconnecting) { site in
            Button("Disconnect", role: .destructive) {
                Task { await site.forget(); reloadConnected() }
            }
        } message: { site in
            Text("Signs Doorlist out of \(site.name) on this phone. Bookings there will ask you to sign in again.")
        }
        .onAppear(perform: reloadConnected)
    }

    private func reloadConnected() {
        connected = Set(ConnectedSite.all.filter(\.isConnected).map(\.id))
    }
}

private struct SiteSignInSheet: View {
    let site: ConnectedSite
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Label("This is \(site.name)'s own sign-in page. Tap Done when you're signed in.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                ProgressView(value: progress).progressViewStyle(.linear)
                    .opacity(progress > 0 && progress < 1 ? 1 : 0)
                SiteWebView(url: site.signIn, progress: $progress)
            }
            .navigationTitle(site.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        site.markConnected(true)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SiteWebView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double

    final class Coordinator { var observation: NSKeyValueObservation? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The same storage the booking browser uses, which is the whole point.
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        context.coordinator.observation = view.observe(\.estimatedProgress) { [progress = $progress] web, _ in
            let value = web.estimatedProgress
            Task { @MainActor in progress.wrappedValue = value }
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
