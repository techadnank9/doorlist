import Foundation

// MARK: - Results

/// One event the search found, with what its own page says filled in.
struct FoundEvent: Identifiable, Hashable, Decodable {
    let url: String
    var title: String
    var start: Date?
    var end: Date?
    var place: String?
    var image: String?
    var priceText: String?
    var isFree: Bool?
    var why: String?
    var match: Double
    var soldOut: Bool
    /// The server opened its page and read a date. Unverified results are shown but never auto booked.
    var verified: Bool
    /// Checked on the phone after the search.
    var clashes = false
    var alreadyBooked = false

    var id: String { url }
    var link: EventLink? { EventLink.find(in: url, allowAnySite: true) }
    var platform: EventPlatform { link?.platform ?? .web }
    var free: Bool { isFree == true }

    var siteName: String {
        guard platform == .web else { return platform.name }
        guard let host = URL(string: url)?.host, host.contains(".") else { return "the event site" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Safe to book without the person picking: checked, free, open, fits, no clash.
    var canAutoBook: Bool {
        verified && free && !soldOut && !clashes && !alreadyBooked && match >= 0.75 && link != nil
    }

    enum CodingKeys: String, CodingKey {
        case url, title, start, end, place, image, priceText, isFree, why, match, soldOut, verified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        start = (try c.decodeIfPresent(String.self, forKey: .start)).flatMap(WebBookingModel.date)
        end = (try c.decodeIfPresent(String.self, forKey: .end)).flatMap(WebBookingModel.date)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        priceText = try c.decodeIfPresent(String.self, forKey: .priceText)
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        match = (try c.decodeIfPresent(Double.self, forKey: .match)) ?? 0.5
        soldOut = (try c.decodeIfPresent(Bool.self, forKey: .soldOut)) ?? false
        verified = (try c.decodeIfPresent(Bool.self, forKey: .verified)) ?? false
    }
}

enum SearchOutcome {
    case events([FoundEvent])
    /// The request was too vague; ask this first.
    case question(String, options: [String])
}

struct Clarification: Hashable, Encodable {
    let question: String
    let answer: String
}

enum SearchStage: Equatable {
    case locating
    /// Not a step of its own: the server found a place in the request and searches there.
    case searchingIn(String)
    case searching
    case checking(Int)
    case ranking
}

enum SearchError: LocalizedError {
    case server(String)
    case unreadable
    /// The connection dropped mid-search, usually because iOS suspended the app. The server
    /// keeps going, so asking again with the same request id picks the search back up.
    case connectionLost

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .unreadable: "The search came back in a shape Doorlist couldn't read. Try again."
        case .connectionLost: "Lost the connection while searching. Try again to pick it back up."
        }
    }
}

// MARK: - Search

/// Asks Doorlist's server to find events for a plain-language request. The
/// server searches with OpenAI and Exa, opens every page to check it, and
/// ranks what's left; it streams how far it's got so the screen can say.
/// Only the request, the town and the names of past events are sent. The
/// calendar check and "already booked" check happen here, on the phone.
enum EventSearch {

    static func run(_ request: String, clarifications: [Clarification] = [], requestId: String,
                    progress: @escaping @MainActor (SearchStage) -> Void) async throws -> SearchOutcome {
        await progress(.locating)
        let place = await LocationProvider.shared.current()

        var body: [String: Any] = [
            "request": request,
            "clarifications": clarifications.map { ["question": $0.question, "answer": $0.answer] },
            "taste": TasteProfile.recent(),
            "requestId": requestId,
        ]
        if let place {
            var p: [String: Any] = [:]
            p["city"] = place.city
            p["region"] = place.region
            p["country"] = place.country
            p["timezone"] = place.timezone ?? TimeZone.current.identifier
            body["place"] = p
        } else {
            body["place"] = ["timezone": TimeZone.current.identifier]
        }

        var req = DoorlistAPI.request("v1/search", timeout: 180)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw SearchError.server("Can't reach Doorlist right now. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw SearchError.server(DoorlistAPI.message(from: data, status: status))
        }

        do {
            for try await line in bytes.lines {
                if let outcome = try await handle(line, progress: progress) { return outcome }
            }
        } catch is URLError {
            throw SearchError.connectionLost
        }
        throw SearchError.unreadable
    }

    /// One line of the stream: a stage, an error, or the result.
    private static func handle(_ line: String, progress: @MainActor (SearchStage) -> Void) async throws -> SearchOutcome? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if let stage = object["stage"] as? String {
            switch stage {
            case "searching":
                // The place named in the request ("in bay area"), when there is one.
                if let area = object["area"] as? String, !area.isEmpty { await progress(.searchingIn(area)) }
                await progress(.searching)
            case "checking": await progress(.checking(object["count"] as? Int ?? 0))
            case "ranking": await progress(.ranking)
            default: break
            }
        } else if let message = object["error"] as? String {
            throw SearchError.server(message)
        } else if let result = object["result"] as? [String: Any] {
            return try outcome(from: result)
        }
        return nil
    }

    /// The single JSON body iOS fetched in the background: `{"result": ...}` or `{"error": "..."}`.
    @MainActor static func finished(_ data: Data) throws -> SearchOutcome {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SearchError.unreadable }
        if let message = object["error"] as? String { throw SearchError.server(message) }
        guard let result = object["result"] as? [String: Any] else { throw SearchError.unreadable }
        return try outcome(from: result)
    }

    private static func outcome(from result: [String: Any]) throws -> SearchOutcome {
        if let question = result["question"] as? String {
            return .question(question, options: result["options"] as? [String] ?? [])
        }
        guard let raw = result["events"] else { throw SearchError.unreadable }
        let data = try JSONSerialization.data(withJSONObject: raw)
        var events = try JSONDecoder().decode([FoundEvent].self, from: data)

        let busy = CalendarGuard.busy()
        let booked = Set(HistoryStore.shared.all().filter { $0.status != .declined }.map { normalize($0.url) })
        for i in events.indices {
            events[i].clashes = CalendarGuard.clashes(start: events[i].start, end: events[i].end, busy: busy)
            events[i].alreadyBooked = booked.contains(normalize(events[i].url))
        }
        return .events(events)
    }

    /// Same event, different link dressing: no query, no trailing slash, no www.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw.lowercased() }
        c.host = c.host?.lowercased()
        if let host = c.host, host.hasPrefix("www.") { c.host = String(host.dropFirst(4)) }
        if c.host == "lu.ma" { c.host = "luma.com" }
        c.query = nil
        c.fragment = nil
        c.scheme = "https"
        var s = c.string ?? raw
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
