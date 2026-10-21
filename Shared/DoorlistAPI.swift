import Foundation
import Security

/// Doorlist's own server. It holds the OpenAI, Exa and ElevenLabs keys and does
/// the search; the app only ever talks to it. The base URL and app token come
/// from Info.plist (set in project.yml), overridable in debug builds.
enum DoorlistAPI {
    static var base: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DOORLIST_API_BASE"], let url = URL(string: override) {
            return url
        }
        #endif
        let raw = Bundle.main.object(forInfoDictionaryKey: "DoorlistAPIBase") as? String
        return URL(string: raw ?? "") ?? URL(string: "http://localhost:8787")!
    }

    private static var appToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "DoorlistAppToken") as? String) ?? ""
    }

    /// A random id for this install, so limits work before (or without) sign in.
    static var installID: String {
        let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard
        if let id = defaults.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "installID")
        return id
    }

    static func request(_ path: String, method: String = "POST", timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(appToken, forHTTPHeaderField: "x-doorlist-token")
        req.setValue(installID, forHTTPHeaderField: "x-doorlist-install")
        if let session = Account.session { req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// The server's error message, or a plain fallback.
    static func message(from data: Data, status: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? String { return error }
        return status == 0 ? "Can't reach Doorlist right now. Check your connection." : "Doorlist's server had a problem (\(status))."
    }

    // MARK: Voice

    /// Where to stream the microphone for live dictation: an ElevenLabs Scribe v2 Realtime socket with a
    /// single use token from Doorlist's server.
    static func voiceSession() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(for: request("v1/voice/session", timeout: 15))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["url"] as? String, let url = URL(string: raw) else {
            throw VoiceError.message(message(from: data, status: status))
        }
        return url
    }

    // MARK: Sign in with Apple

    /// Swaps Apple's identity token for a Doorlist session. Returns the email
    /// Apple shared, if any.
    static func signIn(identityToken: String) async throws -> String? {
        var req = request("v1/session", timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["identityToken": identityToken])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = json["session"] as? String else {
            throw VoiceError.message(message(from: data, status: status))
        }
        Account.session = session
        if let id = json["analyticsId"] as? String { UserDefaults.standard.set(id, forKey: "analyticsId") }
        return json["email"] as? String
    }
}

/// The signed-in Doorlist account: just the server session, in the Keychain.
/// The person's details stay in AnswerStore on the phone.
enum Account {
    private static let service = "com.doorlist.app.session"

    static var isSignedIn: Bool { session != nil }

    static var session: String? {
        get {
            for group in [AppGroup.id, nil] as [String?] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                if let group { query[kSecAttrAccessGroup as String] = group }
                var item: CFTypeRef?
                if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
                    return String(data: data, encoding: .utf8)
                }
            }
            return nil
        }
        set {
            for group in [AppGroup.id, nil] as [String?] {
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
                if let group { query[kSecAttrAccessGroup as String] = group }
                SecItemDelete(query as CFDictionary)
            }
            guard let newValue, !newValue.isEmpty else { return }
            for group in [AppGroup.id, nil] as [String?] {
                var add: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecValueData as String: Data(newValue.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                ]
                if let group { add[kSecAttrAccessGroup as String] = group }
                if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return }
            }
        }
    }
}
