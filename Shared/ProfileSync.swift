import Foundation

/// Keeps the person's answers, bookings and preferences with their account,
/// so a new phone signed into the same Apple ID has everything. The server
/// merges (newest edit per answer wins, every booking kept) and the phone
/// takes the merged copy back. Site logins never sync; they stay per device.
@MainActor
enum ProfileSync {
    private static var running = false
    private static var again = false
    private static var debounce: Task<Void, Never>?

    /// Something changed locally; sync in a moment (edits often come in bursts).
    static func soon() {
        guard Account.isSignedIn else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await now()
        }
    }

    /// Sync now. Quietly does nothing when signed out or offline; the next try catches up.
    @discardableResult
    static func now() async -> Bool {
        guard Account.isSignedIn else { return false }
        if running { again = true; return false }
        running = true
        defer { running = false }
        repeat {
            again = false
            guard await roundTrip() else { return false }
        } while again
        return true
    }

    private struct Payload: Codable {
        var answers: [String: SavedAnswer]
        var history: [BookingRecord]
        var prefs: Prefs

        struct Prefs: Codable {
            var autoAgree: Bool?
            var updatedAt: Date?
        }
    }

    private static func roundTrip() async -> Bool {
        let payload = Payload(answers: AnswerStore.shared.everything(), history: HistoryStore.shared.all(),
                              prefs: .init(autoAgree: Preferences.autoAgree, updatedAt: Preferences.autoAgreeUpdatedAt))
        var req = DoorlistAPI.request("v1/sync", timeout: 30)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder.iso.encode(payload) else { return false }
        req.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { Account.session = nil; return false }
        guard status == 200, let merged = try? JSONDecoder.iso.decode(Payload.self, from: data) else { return false }

        AnswerStore.shared.replaceAll(merged.answers)
        HistoryStore.shared.replaceAll(merged.history)
        if let agree = merged.prefs.autoAgree, let at = merged.prefs.updatedAt,
           at > (Preferences.autoAgreeUpdatedAt ?? .distantPast) {
            Preferences.setAutoAgree(agree, at: at)
        }
        NotificationCenter.default.post(name: .doorlistSynced, object: nil)
        return true
    }

    /// Apple's required "delete my account": wipes the server copy, then this phone's sign in.
    static func deleteAccount() async throws {
        var req = DoorlistAPI.request("v1/account", method: "DELETE", timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 401 else {
            throw VoiceError.message(DoorlistAPI.message(from: data, status: status))
        }
        Account.session = nil
    }
}

extension Notification.Name {
    /// Local data was replaced by a sync; screens should re-read it.
    static let doorlistSynced = Notification.Name("doorlistSynced")
    /// Local data changed; a sync should follow.
    static let doorlistDataChanged = Notification.Name("doorlistDataChanged")
}
