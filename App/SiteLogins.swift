import Foundation
import Security

/// Accounts Doorlist made on event sites while booking, one per site, in the phone's Keychain.
/// They never leave the phone and never sync. The person can see, copy and delete them in
/// Other event sites.
struct SiteLogin: Codable, Identifiable, Hashable {
    var site: String
    var email: String
    var password: String
    var createdAt: Date

    var id: String { site }
}

enum SiteLogins {
    private static let service = "com.doorlist.app.site-login"

    /// "events.linuxfoundation.org" and "sso.linuxfoundation.org" share one login: the last two labels.
    static func site(for host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".")
        return labels.count > 2 ? labels.suffix(2).joined(separator: ".") : host
    }

    static func login(for host: String?) -> SiteLogin? {
        guard let site = site(for: host) else { return nil }
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SiteLogin.self, from: data)
    }

    static func all() -> [SiteLogin] {
        var items: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [Data] else { return [] }
        return list.compactMap { try? JSONDecoder().decode(SiteLogin.self, from: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ login: SiteLogin) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        remove(site: login.site)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login.site,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func remove(site: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 20 characters with every kind sites ask for: upper, lower, digit and symbol.
    static func newPassword() -> String {
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), lower = Array("abcdefghijkmnpqrstuvwxyz")
        let digits = Array("23456789"), symbols = Array("!@#$%&*?")
        var chars = [upper.randomElement()!, lower.randomElement()!, digits.randomElement()!, symbols.randomElement()!]
        let all = upper + lower + digits + symbols
        while chars.count < 20 { chars.append(all.randomElement()!) }
        return String(chars.shuffled())
    }
}
