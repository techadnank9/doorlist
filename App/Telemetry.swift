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
            PostHogSDK.shared.setup(config)
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

    /// One thing that happened, e.g. "explore_event_opened" with ["source": "luma"].
    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }
}
