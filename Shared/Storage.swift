import Foundation
import Security

enum AppGroup {
    static let id = "group.com.doorlist.app"

    /// The folder the app and the share extension both read. Falls back to the
    /// app's own Application Support when the group is not provisioned (unsigned
    /// simulator builds), which keeps the app working but stops the sharing.
    static let folder: URL = {
        let fm = FileManager.default
        #if os(iOS)
        // The group path can come back before the folder exists; saves would then
        // fail silently, so make sure it's there and fall back if it can't be.
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: id),
           (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
            return url
        }
        #endif
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

// MARK: - Preferences

enum Preferences {
    private static let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard

    /// Tick required terms and consent boxes without asking. Off until the
    /// person says yes once, on their first event with terms.
    static var autoAgree: Bool {
        get { defaults.bool(forKey: "autoAgree") }
        set { setAutoAgree(newValue, at: Date()); notifyDataChanged() }
    }

    /// When autoAgree last changed, so the newest choice wins across devices.
    static var autoAgreeUpdatedAt: Date? { defaults.object(forKey: "autoAgreeUpdatedAt") as? Date }

    static func setAutoAgree(_ on: Bool, at date: Date) {
        defaults.set(on, forKey: "autoAgree")
        defaults.set(date, forKey: "autoAgreeUpdatedAt")
    }
}

/// Tells the app a sync is due. Posted on the main queue; harmless in the extension.
func notifyDataChanged() {
    Task { @MainActor in NotificationCenter.default.post(name: .doorlistDataChanged, object: nil) }
}

// MARK: - Luma session

/// The Luma sign-in cookie, kept in the Keychain and shared with the extension
/// through the app group. It never leaves the phone.
struct LumaSession: Codable {
    static let cookieName = "luma.auth-session-key"

    var token: String
    var userAgent: String?
}

enum SessionStore {
    private static let service = "com.doorlist.app.luma"
    private static let account = "session"

    static func load() -> LumaSession? {
        for group in [AppGroup.id, nil] as [String?] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let group { query[kSecAttrAccessGroup as String] = group }
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let session = try? JSONDecoder().decode(LumaSession.self, from: data) {
                return session
            }
        }
        return nil
    }

    static func save(_ session: LumaSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clear()
        // Prefer the shared group so the extension can book; fall back to the
        // app-only keychain when the entitlement is missing.
        for group in [AppGroup.id, nil] as [String?] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            if let group { query[kSecAttrAccessGroup as String] = group }
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return }
        }
    }

    static func clear() {
        for group in [AppGroup.id, nil] as [String?] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if let group { query[kSecAttrAccessGroup as String] = group }
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - Remembered answers

struct SavedAnswer: Codable, Hashable {
    var label: String
    var value: String
    var choices: [String]?
    var updatedAt: Date
    /// Every wording of the question this answer has been used for.
    var askedAs: [String]?
    /// Forgotten. Kept as a marker so the account's other devices forget it too.
    var deleted: Bool?

    var questions: [String] {
        var all = askedAs ?? []
        if !all.contains(label) { all.insert(label, at: 0) }
        return all
    }
}

/// Every answer the person told us to remember, keyed by `QuestionMatcher` keys.
final class AnswerStore: @unchecked Sendable {
    static let shared = AnswerStore()

    private let url = AppGroup.folder.appendingPathComponent("answers.json")
    private let lock = NSLock()

    /// Every live answer.
    func all() -> [String: SavedAnswer] {
        lock.lock(); defer { lock.unlock() }
        return read().filter { $0.value.deleted != true }
    }

    /// Live answers plus forgotten markers, for sync.
    func everything() -> [String: SavedAnswer] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Takes the account's merged copy after a sync, keeping anything changed here since it was sent.
    func replaceAll(_ answers: [String: SavedAnswer]) {
        lock.lock(); defer { lock.unlock() }
        var merged = answers
        for (key, local) in read() where local.updatedAt > (answers[key]?.updatedAt ?? .distantPast) {
            merged[key] = local
        }
        write(merged)
    }

    func get(_ key: String) -> SavedAnswer? { all()[key] }


    func set(_ key: String, label: String, value: String, choices: [String]? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(choices ?? []).isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var answers = read()
        var asked = answers[key]?.askedAs ?? []
        if !asked.contains(label) { asked.append(label) }
        answers[key] = SavedAnswer(label: answers[key]?.label ?? label, value: trimmed, choices: choices,
                                   updatedAt: Date(), askedAs: asked)
        write(answers)
        notifyDataChanged()
    }

    /// Notes which question wordings a remembered answer was just used for.
    func noteAsked(_ pairs: [(key: String, label: String)]) {
        lock.lock(); defer { lock.unlock() }
        var answers = read()
        var changed = false
        for (key, label) in pairs {
            guard var answer = answers[key], answer.deleted != true else { continue }
            var asked = answer.askedAs ?? [answer.label]
            guard !asked.contains(label) else { continue }
            asked.append(label)
            answer.askedAs = asked
            answer.updatedAt = Date()
            answers[key] = answer
            changed = true
        }
        if changed {
            write(answers)
            notifyDataChanged()
        }
    }

    /// Fills a key only if nothing is saved there yet (used for Luma profile data).
    func seed(_ key: String, label: String, value: String?) {
        guard let value, !value.isEmpty, all()[key] == nil else { return }
        set(key, label: label, value: value)
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var answers = read()
        guard let old = answers[key] else { return }
        answers[key] = SavedAnswer(label: old.label, value: "", choices: nil, updatedAt: Date(), askedAs: nil, deleted: true)
        write(answers)
        notifyDataChanged()
    }

    private func read() -> [String: SavedAnswer] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let answers = try? JSONDecoder.iso.decode([String: SavedAnswer].self, from: data) else {
            setAside(url)
            return [:]
        }
        return answers
    }

    private func write(_ answers: [String: SavedAnswer]) {
        guard let data = try? JSONEncoder.iso.encode(answers) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Booking history

struct BookingRecord: Codable, Identifiable, Hashable {
    var id: String
    var eventName: String
    var url: String
    var status: BookingStatus
    var startAt: Date?
    var bookedAt: Date
    var coverUrl: String?
    var place: String?
    /// The questions this event asked and what was sent for each.
    var answers: [SentAnswer]?
    /// Nil on bookings made before Partiful and Eventbrite, which were all Luma.
    var platform: EventPlatform? = nil

    var site: EventPlatform { platform ?? .luma }
}

struct SentAnswer: Codable, Hashable {
    var question: String
    var answer: String
}

enum BookingStatus: String, Codable {
    case approved
    case pendingApproval = "pending_approval"
    case waitlist
    case invited
    case declined

    var title: String {
        switch self {
        case .approved: "You're in"
        case .pendingApproval: "Requested"
        case .waitlist: "Waitlisted"
        case .invited: "Invited"
        case .declined: "Declined"
        }
    }
}

final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private let url = AppGroup.folder.appendingPathComponent("history.json")
    private let lock = NSLock()

    func all() -> [BookingRecord] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func add(_ record: BookingRecord) {
        lock.lock(); defer { lock.unlock() }
        var records = read().filter { $0.id != record.id }
        records.insert(record, at: 0)
        save(records)
        notifyDataChanged()
    }

    /// Takes the account's merged copy after a sync, keeping bookings made here since it was sent.
    func replaceAll(_ records: [BookingRecord]) {
        lock.lock(); defer { lock.unlock() }
        let incoming = Set(records.map(\.id))
        save(read().filter { !incoming.contains($0.id) } + records)
    }

    private func save(_ records: [BookingRecord]) {
        guard let data = try? JSONEncoder.iso.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func read() -> [BookingRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let records = try? JSONDecoder.iso.decode([BookingRecord].self, from: data) else {
            setAside(url)
            return []
        }
        return records
    }
}

/// Moves a file that no longer decodes to `<name>.bad`, so the next write can't silently wipe it.
private func setAside(_ url: URL) {
    let fm = FileManager.default
    let bad = url.appendingPathExtension("bad")
    try? fm.removeItem(at: bad)
    try? fm.moveItem(at: url, to: bad)
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
