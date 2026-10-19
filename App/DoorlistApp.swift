import SwiftUI
import UserNotifications

@main
struct DoorlistApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .tint(.accentColor)
        }
    }
}

/// Shows notifications while the app is open, and opens the event a tapped one is about.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Telemetry.start()
        UNUserNotificationCenter.current().delegate = self
        // Explore's covers: keep them on disk so scrolling back never downloads one twice.
        URLCache.shared = URLCache(memoryCapacity: 30_000_000, diskCapacity: 300_000_000)
        Notifier.registerCategories()
        #if DEBUG
        // Test runs can start signed in without Apple (unsigned simulator builds can't use it).
        if let session = ProcessInfo.processInfo.environment["DOORLIST_SESSION"] { Account.session = session }
        #endif
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let token = info[Notifier.questionKey] as? String {
            // Typed straight into the notification: hand it to the waiting booking.
            if let reply = response as? UNTextInputNotificationResponse {
                let text = reply.userText
                await MainActor.run { AnswerInbox.post(token: token, text: text) }
            }
            return
        }
        guard let raw = response.notification.request.content.userInfo[Notifier.linkKey] as? String,
              let url = URL(string: raw) else { return }
        // Booked notifications point at events already in history; only open the rest.
        let booked = HistoryStore.shared.all().contains { $0.url == raw }
        if !booked { PendingLinks.add(url) }
        await MainActor.run { NotificationCenter.default.post(name: .doorlistPendingLink, object: nil) }
    }
}

extension Notification.Name {
    static let doorlistPendingLink = Notification.Name("doorlistPendingLink")
}

@MainActor
final class AppState: ObservableObject {
    @Published var connected = SessionStore.load() != nil
    @Published var history = HistoryStore.shared.all()
    @Published var answers = AnswerStore.shared.all()
    @Published var autoAgree = Preferences.autoAgree
    @Published var clipboardHasLink = UIPasteboard.general.hasURLs

    /// The share extension writes to the same files, so re-read on return.
    func refresh() {
        connected = SessionStore.load() != nil
        history = HistoryStore.shared.all()
        answers = AnswerStore.shared.all()
        autoAgree = Preferences.autoAgree
        signedIn = Account.isSignedIn
        // Checking for a URL doesn't read it, so no paste prompt appears.
        clipboardHasLink = UIPasteboard.general.hasURLs
    }

    @Published var signedIn = Account.isSignedIn

    func setAutoAgree(_ on: Bool) {
        Preferences.autoAgree = on
        autoAgree = on
    }

    func signOut() async {
        SessionStore.clear()
        await LumaSignInWebView.clearLumaData()
        refresh()
    }

    var profileName: String? { answers["name"]?.value ?? answers["first_name"]?.value }
}

struct BookingRequest: Identifiable {
    let id = UUID()
    let input: String
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var showConnect = false
    @State private var booking: BookingRequest?

    private var needsOnboarding: Bool { !onboarded || !state.signedIn }

    var body: some View {
        TabView {
            HomeView(showConnect: $showConnect, booking: $booking)
                .tabItem { Label("Events", systemImage: "ticket.fill") }
            ExploreView(booking: $booking)
                .tabItem { Label("Explore", systemImage: "safari.fill") }
            FindView(booking: $booking)
                .tabItem { Label("Find", systemImage: "sparkle.magnifyingglass") }
            AnswersView(showConnect: $showConnect)
                .tabItem { Label("Answers", systemImage: "person.text.rectangle.fill") }
        }
        .sheet(isPresented: $showConnect) {
            ConnectLumaView { state.refresh() }
        }
        .sheet(item: $booking, onDismiss: { state.refresh() }) { request in
            if let link = EventLink.find(in: request.input, allowAnySite: true), link.platform != .luma {
                WebBookingView(link: link) { booking = nil }
                    .interactiveDismissDisabled()
            } else {
                BookingSheet(request: request, showConnect: $showConnect, booking: $booking)
            }
        }
        // Doorlist needs an account: first launch, a skipped sign in on an older build, signing out
        // and deleting the account all land here until Sign in with Apple succeeds.
        // Drawn over the tabs from the first frame, rather than a cover that slides up after them.
        .accessibilityHidden(needsOnboarding)
        .overlay {
            if needsOnboarding {
                OnboardingView(returning: onboarded) { onboarded = true; state.refresh() }
                    .environmentObject(state)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: needsOnboarding)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                state.refresh()
                openPending()
                Task { if await ProfileSync.now() { state.refresh() } }
            }
        }
        .task {
            // scenePhase changes don't fire for the launch itself, so sync here too.
            if await ProfileSync.now() { state.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .doorlistDataChanged)) { _ in ProfileSync.soon() }
        .onReceive(NotificationCenter.default.publisher(for: .doorlistSynced)) { _ in state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .doorlistPendingLink)) { _ in openPending() }
        .onOpenURL { url in
            if EventLink.find(in: url.absoluteString, allowAnySite: true) != nil {
                booking = BookingRequest(input: url.absoluteString)
            }
        }
    }
}

extension RootView {
    /// A link the share extension or a notification left for the app to book.
    fileprivate func openPending() {
        guard booking == nil, onboarded, let url = PendingLinks.take() else { return }
        booking = BookingRequest(input: url.absoluteString)
    }
}

private struct BookingSheet: View {
    let request: BookingRequest
    @Binding var showConnect: Bool
    @Binding var booking: BookingRequest?
    @StateObject private var model: BookingFlowModel

    init(request: BookingRequest, showConnect: Binding<Bool>, booking: Binding<BookingRequest?>) {
        self.request = request
        _showConnect = showConnect
        _booking = booking
        _model = StateObject(wrappedValue: BookingFlowModel(input: request.input))
    }

    var body: some View {
        BookingFlowView(model: model, onConnect: {
            booking = nil
            Task {
                // Let the booking sheet finish closing before the next one opens.
                try? await Task.sleep(for: .milliseconds(450))
                showConnect = true
            }
        }, onClose: { booking = nil })
    }
}
