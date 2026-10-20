import Foundation

enum LumaError: LocalizedError {
    case notALumaLink
    case signedOut
    case eventFullWaitlist
    case server(code: String?, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notALumaLink: "That doesn't look like a Luma event link."
        case .signedOut: "Your Luma sign-in expired. Connect Luma again."
        case .eventFullWaitlist: "This event is full."
        case .server(_, let message): message
        case .badResponse: "Luma sent something unexpected. Try again in a moment."
        }
    }
}

/// Talks to the same endpoints luma.com's own web client uses, with the
/// signed-in person's session cookie. One request per action the person takes.
struct LumaClient {
    static let apiBase = URL(string: "https://api.luma.com")!

    var session: LumaSession?

    init(session: LumaSession? = SessionStore.load()) {
        self.session = session
    }

    // MARK: Links

    /// Pulls the event slug (or `evt-` id) out of a link or a shared blob of text.
    static func eventReference(from text: String) -> String? {
        let pattern = #"(?:https?://)?(?:www\.)?(?:lu\.ma|luma\.com)/[^\s"'<>]+"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var raw = String(text[range])
        if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if let first = parts.first, ["e", "event"].contains(first.lowercased()) { parts.removeFirst() }
        guard let slug = parts.first, !slug.isEmpty else { return nil }
        let reserved: Set<String> = ["discover", "home", "signin", "calendar", "user", "settings", "create", "explore"]
        return reserved.contains(slug.lowercased()) ? nil : slug
    }

    static func eventURL(for reference: String) -> URL {
        URL(string: "https://luma.com/\(reference)")!
    }

    // MARK: Reading

    struct FetchedEvent {
        var page: LumaEventPage
        /// Set when the signed-in person already has a ticket or request.
        var existingStatus: BookingStatus?
        /// Set when a host invited the signed-in person; registering with it accepts the invite.
        var inviteId: String?
    }

    func fetchEvent(_ reference: String) async throws -> FetchedEvent {
        var components = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
        if reference.hasPrefix("evt-") {
            components.path = "/event/get"
            components.queryItems = [URLQueryItem(name: "event_api_id", value: reference)]
        } else {
            components.path = "/url"
            components.queryItems = [URLQueryItem(name: "url", value: reference)]
        }
        let json = try await send(request(components.url!, referer: reference))
        guard let root = json as? [String: Any] else { throw LumaError.badResponse }
        let data = (root["data"] as? [String: Any]) ?? root
        if let kind = root["kind"] as? String, kind != "event" { throw LumaError.notALumaLink }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try JSONSerialization.data(withJSONObject: data)
        guard let page = try? decoder.decode(LumaEventPage.self, from: body) else { throw LumaError.badResponse }

        let guest = data["guest_data"] as? [String: Any]
        let status = (guest?["approval_status"] as? String).flatMap(BookingStatus.init(rawValue:))
        let invite = (data["event_invite"] as? [String: Any])?["api_id"] as? String
        return FetchedEvent(page: page, existingStatus: status, inviteId: invite)
    }

    func fetchUser() async throws -> LumaUser {
        let json = try await send(request(Self.apiBase.appendingPathComponent("user"), referer: nil))
        guard let root = json as? [String: Any] else { throw LumaError.badResponse }
        let user = (root["user"] as? [String: Any]) ?? root
        return LumaUser(
            name: user["name"] as? String,
            firstName: user["first_name"] as? String,
            lastName: user["last_name"] as? String,
            email: user["email"] as? String,
            phoneNumber: user["phone_number"] as? String
        )
    }

    // MARK: Booking

    struct Registration {
        var eventApiId: String
        var reference: String
        var name: String
        var firstName: String
        var lastName: String
        var email: String
        var phoneNumber: String
        var ticketTypeId: String?
        var answers: [[String: Any]]
        var inviteId: String?
        var couponCode: String?
    }

    /// Mirrors the payload luma.com builds in its registration form. Joins the
    /// waitlist automatically when Luma says the event is full.
    func register(_ r: Registration) async throws -> BookingStatus {
        do {
            return try await postRegistration(r, forWaitlist: false)
        } catch LumaError.eventFullWaitlist {
            return try await postRegistration(r, forWaitlist: true)
        }
    }

    private func postRegistration(_ r: Registration, forWaitlist: Bool) async throws -> BookingStatus {
        let null = NSNull()
        var tickets: [String: Any] = [:]
        if let id = r.ticketTypeId { tickets[id] = ["count": 1, "amount": 0] }
        let payload: [String: Any] = [
            "name": r.name,
            "first_name": r.firstName,
            "last_name": r.lastName,
            "email": r.email,
            "event_api_id": r.eventApiId,
            "for_waitlist": forWaitlist,
            "payment_method": null,
            "payment_currency": null,
            "registration_answers": r.answers,
            "coupon_code": r.couponCode ?? null,
            "token_gate_info": null,
            "eth_address_info": null,
            "phone_number": r.phoneNumber,
            "solana_address_info": null,
            "expected_amount_cents": 0,
            "expected_amount_tax": 0,
            "currency": null,
            "event_invite_api_id": r.inviteId ?? null,
            "ticket_type_to_selection": tickets,
            "solana_address": null,
            "solana_wallet_type": null,
        ]
        var req = request(Self.apiBase.appendingPathComponent("event/register"), referer: r.reference)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let json = try await send(req)
        guard let root = json as? [String: Any] else { throw LumaError.badResponse }
        if let status = root["status"] as? String, status != "success" {
            // "require-payment-confirmation" and crypto flows land here; we only book free tickets.
            throw LumaError.server(code: status, message: "This event needs a payment step. Finish it on Luma.")
        }
        if let found = Self.findApprovalStatus(in: root) { return found }
        return forWaitlist ? .waitlist : .approved
    }

    private static func findApprovalStatus(in value: Any) -> BookingStatus? {
        if let dict = value as? [String: Any] {
            if let raw = dict["approval_status"] as? String, let status = BookingStatus(rawValue: raw) { return status }
            for child in dict.values { if let s = findApprovalStatus(in: child) { return s } }
        } else if let array = value as? [Any] {
            for child in array { if let s = findApprovalStatus(in: child) { return s } }
        }
        return nil
    }

    // MARK: Transport

    private func request(_ url: URL, referer reference: String?) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://luma.com", forHTTPHeaderField: "Origin")
        req.setValue(reference.map { "https://luma.com/\($0)" } ?? "https://luma.com/", forHTTPHeaderField: "Referer")
        req.setValue("luma-web", forHTTPHeaderField: "x-luma-client-type")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-luma-timezone")
        if let session {
            req.setValue("\(LumaSession.cookieName)=\(session.token)", forHTTPHeaderField: "Cookie")
            if let ua = session.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        }
        req.httpShouldHandleCookies = false
        return req
    }

    private func send(_ req: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        if (200..<300).contains(status) {
            guard let json else { throw LumaError.badResponse }
            return json
        }
        let body = json as? [String: Any]
        let code = body?["code"] as? String
        let message = (body?["message"] as? String) ?? "Luma couldn't do that (error \(status))."
        if code == "event/full-waitlist-available" { throw LumaError.eventFullWaitlist }
        if status == 401 || code == "event_sign_in_required" || code?.hasPrefix("auth/") == true {
            throw LumaError.signedOut
        }
        throw LumaError.server(code: code, message: message)
    }
}
