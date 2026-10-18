import Foundation
import UserNotifications

/// Local notifications: "you're in" after a booking, and "tap to finish" when
/// a link needs the app. Nothing goes through a server.
enum Notifier {
    /// The event link a notification opens, read by the app when it's tapped.
    static let linkKey = "doorlistLink"
    /// Which open question a "needs an answer" notification is about.
    static let questionKey = "doorlistQuestion"
    static let answerCategory = "DOORLIST_ANSWER"
    static let answerAction = "DOORLIST_ANSWER_REPLY"

    /// "Answer" lets the person reply from the notification itself; tapping
    /// the notification opens the question in the app.
    static func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: answerAction, title: "Answer", options: [.foreground],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let category = UNNotificationCategory(identifier: answerCategory, actions: [reply], intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// A booking is waiting on one answer Doorlist doesn't know yet.
    static func needsAnswer(_ question: String, event: String?, token: String, choices: [String]? = nil) {
        let content = UNMutableNotificationContent()
        content.title = event.map { "\($0) needs one answer" } ?? "Doorlist needs one answer"
        var body = question
        if let choices, !choices.isEmpty { body += "\n" + choices.prefix(4).joined(separator: " · ") }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = answerCategory
        content.interruptionLevel = .timeSensitive
        content.userInfo = [questionKey: token]
        // One pending question at a time: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: "doorlist-question", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clearQuestion() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["doorlist-question"])
    }

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func booked(_ eventName: String, status: BookingStatus, platform: EventPlatform, url: URL?) {
        let body: String = switch status {
        case .approved: "You're in. \(platform == .web ? "The host" : platform.name) has your spot."
        case .pendingApproval: "Request sent. The host will decide."
        case .waitlist: "It's full, so you're on the waitlist."
        case .invited, .declined: status.title
        }
        post(title: eventName, body: body, link: url)
    }

    static func finishInApp(_ eventTitle: String?, url: URL) {
        post(title: "Finish booking in Doorlist",
             body: "Tap to book \(eventTitle ?? "this event"). Your saved answers are ready.", link: url)
    }

    static func found(_ eventName: String, url: URL) {
        post(title: "Found it: \(eventName)", body: "Tap to book it.", link: url)
    }

    private static func post(title: String, body: String, link: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let link { content.userInfo = [linkKey: link.absoluteString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Links the share extension couldn't book itself (Partiful, Eventbrite), waiting
/// for the app to open. Kept in the app group so both sides see it.
enum PendingLinks {
    private static let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard
    private static let key = "pendingLinks"

    static func add(_ url: URL) {
        var all = defaults.stringArray(forKey: key) ?? []
        all.removeAll { $0 == url.absoluteString }
        all.append(url.absoluteString)
        defaults.set(all, forKey: key)
    }

    /// The newest waiting link, removed as it's read.
    static func take() -> URL? {
        var all = defaults.stringArray(forKey: key) ?? []
        guard let last = all.popLast() else { return nil }
        defaults.set(all, forKey: key)
        return URL(string: last)
    }
}

/// Answers typed into a notification, handed to whichever booking asked.
enum AnswerInbox {
    static let name = Notification.Name("doorlistAnswer")

    static func post(token: String, text: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["token": token, "text": text])
    }

    static func read(_ note: Notification) -> (token: String, text: String)? {
        guard let token = note.userInfo?["token"] as? String, let text = note.userInfo?["text"] as? String else { return nil }
        return (token, text)
    }
}
