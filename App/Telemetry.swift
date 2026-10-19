import Foundation
import PostHog
import Sentry

/// Product analytics (PostHog) and crash reports (Sentry). Each starts only when its key is set in
/// project.yml (POSTHOG_API_KEY, SENTRY_DSN), so a build without keys sends nothing.
///
/// Nothing personal goes out: no answers, names, emails or phone numbers, no IP-based person
/// profiles, no screen recordings. Events carry only what they're about (a source, a topic).
enum Telemetry {
    static func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let key = info["PostHogAPIKey"] as? String, !key.isEmpty {
            let config = PostHogConfig(apiKey: key, host: (info["PostHogHost"] as? String) ?? "https://us.i.posthog.com")
            config.captureApplicationLifecycleEvents = true
            config.captureScreenViews = false   // SwiftUI screens are tracked by name below instead
            config.personProfiles = .identifiedOnly
            config.sessionReplay = false
            // In-app surveys: written and targeted in PostHog, shown natively here.
            config.surveys = true
            PostHogSDK.shared.setup(config)
            if Account.isSignedIn { identify() }
            HistoryStore.onAdd = { record in
                capture("event_booked", ["site": record.site.rawValue, "status": record.status.rawValue,
                                         "answers_sent": record.answers?.count ?? 0])
            }
        }
        if let dsn = info["SentryDSN"] as? String, !dsn.isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                options.sendDefaultPii = false
                options.tracesSampleRate = 0.2
                #if DEBUG
                options.environment = "debug"
                #endif
            }
        }
    }

    /// Ties this phone's events to the account, by the anonymous id the server gave at sign in,
    /// so the server's search-quality events and the app's line up. Never the Apple id or an email.
    static func identify() {
        guard let id = UserDefaults.standard.string(forKey: "analyticsId") else { return }
        PostHogSDK.shared.identify(id)
    }

    /// Signed out or account deleted: the next person on this phone starts anonymous.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: "analyticsId")
        PostHogSDK.shared.reset()
    }

    /// One thing that happened, e.g. "explore_event_opened" with ["source": "luma"].
    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }
}
