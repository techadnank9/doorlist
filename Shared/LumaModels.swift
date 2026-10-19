import Foundation

/// The parts of Luma's event payload (`GET /url?url=<slug>`) that booking needs.
/// Field names mirror Luma's JSON; decoded with `.convertFromSnakeCase`.
struct LumaEventPage: Decodable {
    let apiId: String?
    let event: LumaEvent
    let ticketTypes: [LumaTicketType]?
    let registrationQuestions: [LumaQuestion]?
    let nameRequirement: String?
    let phoneNumberRequirement: String?
    let ethAddressRequirement: String?
    let solanaAddressRequirement: String?
    let soldOut: Bool?
    let waitlistActive: Bool?

    var eventApiId: String { apiId ?? event.apiId }
    var questions: [LumaQuestion] { registrationQuestions ?? [] }
    var wantsFirstLast: Bool { nameRequirement == "first-last" }
    var needsWallet: Bool { ethAddressRequirement == "required" || solanaAddressRequirement == "required" }
}

struct LumaEvent: Decodable {
    let apiId: String
    let name: String
    let startAt: String?
    let endAt: String?
    let timezone: String?
    let url: String?
    let coverUrl: String?
    let geoAddressInfo: GeoAddress?

    struct GeoAddress: Decodable {
        let cityState: String?
        let city: String?
    }

    var startDate: Date? { Self.date(startAt) }
    var endDate: Date? { Self.date(endAt) }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return (try? fractional.parse(raw)) ?? (try? plain.parse(raw))
    }

    var place: String? { geoAddressInfo?.cityState ?? geoAddressInfo?.city }
}

struct LumaTicketType: Decodable {
    let apiId: String
    let name: String?
    let cents: Int?
    let isFlexible: Bool?
    let isHidden: Bool?
    let isDisabled: Bool?
    let requireApproval: Bool?

    var isFree: Bool { (cents ?? 0) == 0 && isFlexible != true }
    var isSelectable: Bool { isHidden != true && isDisabled != true }
}

struct LumaQuestion: Decodable, Identifiable {
    let id: String
    let label: String
    let required: Bool?
    let questionType: String
    let options: [String]?
    let multiple: Bool?
    let multiline: Bool?
    let collectJobTitle: Bool?
    let jobTitleLabel: String?
    let terms: Terms?

    struct Terms: Decodable {
        let contentType: String?
        let url: String?
        let collectSignature: Bool?
    }

    var isRequired: Bool { required ?? false }
}

/// Luma's question types, as listed in their web client.
enum LumaQuestionType: String {
    case agreeCheck = "agree-check"
    case company
    case dropdown
    case github
    case instagram
    case linkedin
    case longText = "long-text"
    case multiSelect = "multi-select"
    case phoneNumber = "phone-number"
    case select
    case telegram
    case text
    case twitter
    case url
    case youtube
    case terms
}

extension LumaQuestion {
    var type: LumaQuestionType? { LumaQuestionType(rawValue: questionType) }

    var isMultiChoice: Bool {
        type == .multiSelect || (type == .select && multiple == true)
    }

    var isSingleChoice: Bool {
        type == .dropdown || (type == .select && multiple != true)
    }

    var isLongText: Bool {
        type == .longText || (type == .text && multiline == true)
    }
}

/// What the person signed into Luma is called, read from `GET /user`.
struct LumaUser {
    var name: String?
    var firstName: String?
    var lastName: String?
    var email: String?
    var phoneNumber: String?
}
