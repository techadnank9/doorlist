import SwiftUI
import WebKit

/// Luma's own sign-in page. The person types their email and the code Luma
/// sends; Doorlist only picks up the resulting session cookie.
struct ConnectLumaView: View {
    var onConnected: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finishing = false
    @State private var progress = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            Label("This is Luma's own sign-in page. Use the email and code Luma sends you.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .opacity(progress > 0 && progress < 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: progress)
            LumaSignInWebView(progress: $progress) { session in
                guard !finishing else { return }
                finishing = true
                SessionStore.save(session)
                Task {
                    await seedProfile(session)
                    onConnected()
                    dismiss()
                }
            }
            }
            .overlay {
                if finishing {
                    ProgressView("Connecting").padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .navigationTitle("Connect Luma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// Fills name, email and phone from the Luma profile so the first booking asks less.
    private func seedProfile(_ session: LumaSession) async {
        guard let user = try? await LumaClient(session: session).fetchUser() else { return }
        let store = AnswerStore.shared
        store.seed("name", label: "Full name", value: user.name)
        store.seed("first_name", label: "First name", value: user.firstName)
        store.seed("last_name", label: "Last name", value: user.lastName)
        store.seed("email", label: "Email", value: user.email)
        store.seed("phone", label: "Phone number", value: user.phoneNumber)
    }
}

struct LumaSignInWebView: UIViewRepresentable {
    @Binding var progress: Double
    var onSession: (LumaSession) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSession: onSession) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://luma.com/signin")!))
        context.coordinator.watch(view)
        context.coordinator.progressObservation = view.observe(\.estimatedProgress) { [progress = $progress] web, _ in
            DispatchQueue.main.async { progress.wrappedValue = web.estimatedProgress }
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSession: (LumaSession) -> Void
        private var timer: Timer?
        private var done = false
        private weak var webView: WKWebView?
        var progressObservation: NSKeyValueObservation?

        init(onSession: @escaping (LumaSession) -> Void) { self.onSession = onSession }

        func watch(_ view: WKWebView) {
            webView = view
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        }

        func stop() { timer?.invalidate() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }

        private func check() {
            guard !done, let view = webView else { return }
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done,
                      let cookie = cookies.first(where: {
                          $0.name == LumaSession.cookieName && $0.domain.contains("luma")
                      }), !cookie.value.isEmpty
                else { return }
                self.done = true
                self.stop()
                view.evaluateJavaScript("navigator.userAgent") { ua, _ in
                    self.onSession(LumaSession(token: cookie.value, userAgent: ua as? String))
                }
            }
        }
    }

    /// Forgets the Luma login inside the app's web views.
    static func clearLumaData() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let luma = records.filter { $0.displayName.contains("luma") || $0.displayName.contains("lu.ma") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: luma)
    }
}
