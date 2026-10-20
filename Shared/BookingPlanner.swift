import Foundation

/// One thing the registration form needs: a built-in field (name, email, phone)
/// or one of the host's questions.
struct PlanField: Identifiable {
    enum Kind {
        case text(multiline: Bool)
        case single([String])
        case multi([String])
        case agree(termsURL: URL?)
    }

    let id: String
    let label: String
    let kind: Kind
    let required: Bool
    /// Where the answer is remembered. Nil for things confirmed each time.
    var saveKey: String?
    var text = ""
    var choices: [String] = []
    var agreed = false
    var remember = true
    /// Filled from memory rather than typed now.
    var fromMemory = false
    /// A remembered answer that did not fit this question's options.
    var hint: String?
    var placeholder: String?

    var isFilled: Bool {
        switch kind {
        case .text, .single: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .multi: !choices.isEmpty
        case .agree: agreed
        }
    }

    /// Asked on the card screen: required and not yet answered.
    var needsInput: Bool { required && !isFilled }

    var isAgree: Bool { if case .agree = kind { true } else { false } }
}

struct BookingPlan {
    let reference: String
    let page: LumaEventPage
    var fields: [PlanField]
    let ticketTypeId: String?
    var inviteId: String? = nil
    var couponCode: String? = nil

    var requiresApproval: Bool {
        page.ticketTypes?.first(where: { $0.apiId == ticketTypeId })?.requireApproval == true
    }

    func field(_ id: String) -> PlanField? { fields.first { $0.id == id } }
}

enum PlanBlocker: LocalizedError {
    case alreadyBooked(BookingStatus)
    case paid
    case wallet

    var errorDescription: String? {
        switch self {
        case .alreadyBooked(let status): "Already done: \(status.title.lowercased())."
        case .paid: "This one has paid tickets. Doorlist only books free events, so finish it on Luma."
        case .wallet: "This event checks a crypto wallet, which needs Luma itself."
        }
    }
}

enum BookingPlanner {

    static func makePlan(_ fetched: LumaClient.FetchedEvent, reference: String, couponCode: String? = nil,
                         store: AnswerStore = .shared) async throws -> BookingPlan {
        let page = fetched.page
        // An invite isn't a spot yet: booking it is what accepts it.
        if let status = fetched.existingStatus, status != .declined, status != .invited {
            throw PlanBlocker.alreadyBooked(status)
        }
        if page.needsWallet { throw PlanBlocker.wallet }

        let types = page.ticketTypes ?? []
        // With a code, a paid ticket may come out free; Luma says so if it doesn't.
        let ticket = types.first { $0.isSelectable && $0.isFree } ?? types.first { $0.isFree }
            ?? (couponCode != nil ? types.first { $0.isSelectable } : nil)
        if !types.isEmpty && ticket == nil { throw PlanBlocker.paid }

        let saved = store.all()
        var fields: [PlanField] = []
        var modelBudget = 3

        func remembered(_ key: String, label: String, kind: PlanField.Kind = .text(multiline: false),
                        required: Bool = true, id: String? = nil, placeholder: String? = nil) -> PlanField {
            var f = PlanField(id: id ?? key, label: label, kind: kind, required: required, saveKey: key)
            f.placeholder = placeholder
            if let answer = saved[key] {
                f.text = answer.value
                f.fromMemory = true
            }
            return f
        }

        // Built-in fields every Luma form has.
        if page.wantsFirstLast {
            var first = remembered("first_name", label: "First name")
            var last = remembered("last_name", label: "Last name")
            if let full = saved["name"]?.value, !first.isFilled || !last.isFilled {
                let split = splitName(full)
                if !first.isFilled { first.text = split.first; first.fromMemory = true }
                if !last.isFilled { last.text = split.last; last.fromMemory = true }
            }
            fields += [first, last]
        } else {
            var name = remembered("name", label: "Full name")
            if !name.isFilled, let first = saved["first_name"]?.value {
                name.text = [first, saved["last_name"]?.value ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                name.fromMemory = true
            }
            fields.append(name)
        }
        fields.append(remembered("email", label: "Email", placeholder: "you@example.com"))
        if let requirement = page.phoneNumberRequirement {
            fields.append(remembered("phone", label: "Phone number", required: requirement == "required",
                                     placeholder: "+1 415 555 0100"))
        }

        // The host's own questions.
        for q in page.questions {
            if QuestionMatcher.asksEveryTime(q) {
                let url = q.terms?.url.flatMap(URL.init(string:))
                let label = q.type == .terms ? "I agree to the \(q.label)" : q.label
                var field = PlanField(id: q.id, label: label, kind: .agree(termsURL: url),
                                      required: q.isRequired, saveKey: nil)
                // Only required boxes are ticked for the person; optional ones
                // (newsletters and the like) stay off.
                if q.isRequired && Preferences.autoAgree {
                    field.agreed = true
                    field.fromMemory = true
                }
                fields.append(field)
                continue
            }
            if q.type == .company {
                fields.append(remembered("company", label: q.label, required: q.isRequired, id: q.id + "#company"))
                if q.collectJobTitle == true {
                    fields.append(remembered("job_title", label: q.jobTitleLabel ?? "What is your job title?",
                                             required: q.isRequired, id: q.id + "#job_title"))
                }
                continue
            }

            let key = await resolveKey(for: q, saved: saved, useModel: modelBudget > 0) { modelBudget -= 1 }
            let options = q.options ?? []
            let kind: PlanField.Kind = q.isMultiChoice ? .multi(options)
                : q.isSingleChoice ? .single(options)
                : .text(multiline: q.isLongText)
            var field = PlanField(id: q.id, label: q.label, kind: kind, required: q.isRequired, saveKey: key)
            field.placeholder = placeholder(for: q)

            if let answer = saved[key] {
                switch kind {
                case .single(let options):
                    if let pick = QuestionMatcher.choose(answer.value, from: options) {
                        field.text = pick
                        field.fromMemory = true
                    } else {
                        // Keep the general answer intact; remember this pick on its own.
                        field.hint = "You usually say \"\(answer.value)\""
                        field.saveKey = QuestionMatcher.labelKey(for: q.label)
                    }
                case .multi(let options):
                    let picks = QuestionMatcher.chooseMany(answer.choices ?? [answer.value], from: options)
                    if picks.isEmpty {
                        field.saveKey = QuestionMatcher.labelKey(for: q.label)
                    } else {
                        field.choices = picks
                        field.fromMemory = true
                    }
                case .text:
                    field.text = answer.choices?.joined(separator: ", ") ?? answer.value
                    field.fromMemory = true
                case .agree:
                    break
                }
            }
            fields.append(field)
        }

        return BookingPlan(reference: reference, page: page, fields: fields, ticketTypeId: ticket?.apiId,
                           inviteId: fetched.inviteId, couponCode: couponCode)
    }

    /// Typed key, then wording rules, then a saved question with the same or
    /// similar wording, then the on-device model, then a fresh key.
    private static func resolveKey(for q: LumaQuestion, saved: [String: SavedAnswer],
                                   useModel: Bool, spendModel: () -> Void) async -> String {
        if let key = QuestionMatcher.typedKey(q) ?? QuestionMatcher.ruleKey(for: q.label) { return key }
        let own = QuestionMatcher.labelKey(for: q.label)
        if saved[own] != nil { return own }
        if let close = QuestionMatcher.closestSavedKey(for: q.label, in: saved) { return close }
        // Only questions people answered before can match, so skip the model when there are none.
        let candidates = saved.filter { $0.key.hasPrefix("q:") || QuestionMatcher.ruleKey(for: $0.value.label) != nil }
        guard useModel, !candidates.isEmpty else { return own }
        spendModel()
        return await QuestionMatcher.modelMatch(for: q.label, in: candidates) ?? own
    }

    private static func placeholder(for q: LumaQuestion) -> String? {
        switch q.type {
        case .linkedin: "linkedin.com/in/you"
        case .twitter, .instagram, .telegram: "@handle"
        case .github: "username"
        case .url: "https://"
        case .phoneNumber: "+1 415 555 0100"
        default: nil
        }
    }

    // MARK: After the person answers

    /// Saves every newly typed or changed answer that has Remember switched on.
    static func remember(_ plan: BookingPlan, original: BookingPlan, store: AnswerStore = .shared) {
        // Answers reused as they were still learn this event's wording of the question.
        store.noteAsked(plan.fields.compactMap { f in
            guard f.fromMemory, let key = f.saveKey, original.field(f.id)?.text == f.text else { return nil }
            return (key, f.label)
        })
        for field in plan.fields {
            if field.isAgree, field.agreed, field.remember, !field.fromMemory {
                Preferences.autoAgree = true
            }
            guard field.remember, let key = field.saveKey, field.isFilled else { continue }
            let before = original.field(field.id)
            let changed = before?.text != field.text || before?.choices != field.choices || before?.fromMemory != true
            guard changed else { continue }
            if case .multi = field.kind {
                store.set(key, label: field.label, value: field.choices.joined(separator: ", "), choices: field.choices)
            } else {
                store.set(key, label: field.label, value: field.id == "phone" ? normalizePhone(field.text) : field.text)
            }
        }
    }

    static func registration(for plan: BookingPlan) -> LumaClient.Registration {
        func value(_ id: String) -> String {
            plan.field(id)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var first = value("first_name"), last = value("last_name")
        var name = value("name")
        if plan.page.wantsFirstLast {
            name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            (first, last) = splitName(name)
        }
        let phone = normalizePhone(value("phone"))

        var answers: [[String: Any]] = []
        for q in plan.page.questions {
            var answer: [String: Any] = ["label": q.label, "question_id": q.id, "question_type": q.questionType]
            if q.type == .select, q.multiple == true { answer["multiple"] = true }
            if q.type == .text, q.multiline == true { answer["multiline"] = true }

            switch q.type {
            case .company:
                let company = value(q.id + "#company"), job = value(q.id + "#job_title")
                answer["value"] = [
                    "company": company.isEmpty ? NSNull() : company,
                    "job_title": job.isEmpty ? NSNull() : job,
                ] as [String: Any]
            case .terms:
                let agreed = plan.field(q.id)?.agreed ?? false
                answer["value"] = q.terms?.collectSignature == true ? (agreed ? name : "") : agreed
            case .agreeCheck:
                answer["value"] = plan.field(q.id)?.agreed ?? false
            case .phoneNumber:
                let p = normalizePhone(value(q.id))
                answer["value"] = p.isEmpty ? NSNull() : p
            default:
                if q.isMultiChoice {
                    answer["value"] = plan.field(q.id)?.choices ?? []
                } else {
                    answer["value"] = value(q.id)
                }
            }
            answers.append(answer)
        }

        return LumaClient.Registration(
            eventApiId: plan.page.eventApiId, reference: plan.reference,
            name: name, firstName: first, lastName: last,
            email: value("email"), phoneNumber: phone,
            ticketTypeId: plan.ticketTypeId, answers: answers, inviteId: plan.inviteId, couponCode: plan.couponCode
        )
    }

    // MARK: Helpers

    static func splitName(_ full: String) -> (first: String, last: String) {
        let parts = full.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    /// Luma stores phone numbers in international form, like +14155550100.
    static func normalizePhone(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("+") { return "+" + digits }
        if trimmed.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        let region = Locale.current.region?.identifier ?? "US"
        if digits.count == 10, ["US", "CA"].contains(region) { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return "+" + digits
    }
}
