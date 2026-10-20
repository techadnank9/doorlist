import Foundation

/// Where an event lives. Luma books through its API; everything else books on
/// the event's own page inside Doorlist's browser.
enum EventPlatform: String, Codable, Hashable {
    case luma
    case partiful
    case eventbrite
    case cerebralValley
    case web

    var name: String {
        switch self {
        case .luma: "Luma"
        case .partiful: "Partiful"
        case .eventbrite: "Eventbrite"
        case .cerebralValley: "Cerebral Valley"
        case .web: "the event site"
        }
    }

    /// "Open on Luma", "Open on Partiful", "Open event page".
    var openTitle: String { self == .web ? "Open event page" : "Open on \(name)" }

    init(host: String) {
        let h = host.lowercased()
        if h == "lu.ma" || h.hasSuffix("luma.com") { self = .luma }
        else if h.hasSuffix("partiful.com") { self = .partiful }
        else if h.range(of: #"(^|\.)eventbrite\.[a-z.]+$"#, options: .regularExpression) != nil { self = .eventbrite }
        else if h == "cerebralvalley.ai" || h.hasSuffix(".cerebralvalley.ai") { self = .cerebralValley }
        else { self = .web }
    }
}

/// An event link pulled out of pasted or shared text.
struct EventLink: Hashable {
    let platform: EventPlatform
    let url: URL

    /// Finds the first event link in `text`. Luma, Partiful and Eventbrite links
    /// are checked for an event path; with `allowAnySite`, any web page counts.
    static func find(in text: String, allowAnySite: Bool = false) -> EventLink? {
        if let ref = LumaClient.eventReference(from: text) {
            return EventLink(platform: .luma, url: LumaClient.eventURL(for: ref))
        }
        let pattern = #"(?:https?://)?(?:localhost|(?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(?:/[^\s"'<>]*)?"#
        let ns = text as NSString
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for match in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            var raw = ns.substring(with: match.range)
            if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
            guard let url = URL(string: raw), let host = url.host else { continue }
            let platform = EventPlatform(host: host)
            let path = url.path.lowercased()
            switch platform {
            case .luma:
                continue
            case .partiful:
                if path.hasPrefix("/e/"), path.count > 3 { return EventLink(platform: .partiful, url: url) }
            case .eventbrite:
                if path.contains("/e/") { return EventLink(platform: .eventbrite, url: url) }
            case .cerebralValley:
                // Its own events live at /e/<slug>; /events and /e/events are listings.
                let parts = path.split(separator: "/")
                if parts.count == 2, parts[0] == "e", parts[1] != "events" {
                    return EventLink(platform: .cerebralValley, url: url)
                }
            case .web:
                // Bare domains like "example.com" in a sentence aren't event pages.
                if allowAnySite, ns.substring(with: match.range).lowercased().hasPrefix("http"),
                   !path.isEmpty, path != "/" {
                    return EventLink(platform: .web, url: url)
                }
            }
        }
        return nil
    }
}


/// A promo, discount or access code pasted along with a link, like "Free Code: AICAMP".
enum PromoCode {
    static func find(in text: String) -> String? {
        let pattern = #"(?i)\b(?:promo|discount|coupon|access|voucher|free|registration|ticket)?\s*code\s*[:=\-]?\s*([A-Z0-9][A-Z0-9_-]{2,31})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: match.range(at: 1))
            // Skip a word that just follows "code" in a sentence ("code of conduct"), and anything inside the link.
            guard code.rangeOfCharacter(from: .decimalDigits) != nil || code == code.uppercased(),
                  !["OF", "FOR", "IS", "THE"].contains(code.uppercased()) else { continue }
            if let link = EventLink.find(in: text, allowAnySite: true), link.url.absoluteString.contains(code) { continue }
            return code
        }
        return nil
    }
}
