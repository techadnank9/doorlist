import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a Luma question into the key its remembered answer lives under, so
/// "What's your role?", "Job Title" and "What is your job title?" all share one.
enum QuestionMatcher {

    /// Questions that must be confirmed each time (terms, consent boxes).
    static func asksEveryTime(_ q: LumaQuestion) -> Bool {
        q.type == .terms || q.type == .agreeCheck
    }

    /// Key from Luma's own question type, when it has a meaning of its own.
    static func typedKey(_ q: LumaQuestion) -> String? {
        switch q.type {
        case .linkedin: "linkedin"
        case .twitter: "twitter"
        case .instagram: "instagram"
        case .github: "github"
        case .telegram: "telegram"
        case .youtube: "youtube"
        case .phoneNumber: "phone"
        default: nil
        }
    }

    /// Common concepts recognised from the wording. Order matters: the first match wins.
    private static let rules: [(key: String, patterns: [String])] = [
        ("linkedin", ["linkedin"]),
        ("twitter", ["twitter", #"\bx handle\b"#, #"\bx username\b"#]),
        ("github", ["github"]),
        ("instagram", ["instagram"]),
        ("telegram", ["telegram"]),
        ("whatsapp", ["whatsapp"]),
        ("wechat", ["wechat", "微信"]),
        ("work_email", [#"\b(work|business|company|corporate) e ?mail"#]),
        ("email", [#"^e ?mail( address)?$"#, #"\byour e ?mail\b"#]),
        ("phone", [#"\bphone\b"#, #"\bmobile( number)?\b"#, #"\bcell\b"#, "电话"]),
        ("job_title", [#"\bjob title\b"#, #"\byour (current )?(role|title|position)\b"#, #"^(role|title|position|job title)$"#, #"\boccupation\b"#, "职位"]),
        ("company", [#"\bcompany\b(?! (registration|arr|revenue|size|stage|funding|type|industry|website))"#, #"\borgani[sz]ation\b"#, #"\bemployer\b"#, #"\bwork for\b"#, #"\bstartup name\b"#, "公司"]),
        ("school", [#"\bschool\b"#, #"\buniversity\b"#, #"\bcollege\b"#]),
        ("major", [#"\bmajor\b"#, #"\bfield of study\b"#, #"\barea of study\b"#]),
        ("graduation_year", [#"\bgraduat"#]),
        ("city", [#"\bcity\b"#, #"\bwhere (are you|do you) (based|live)\b"#, "居住"]),
        ("country", [#"\bcountry\b"#]),
        ("website", [#"\bwebsite\b"#, #"\bportfolio\b"#, #"\bpersonal site\b"#]),
        ("heard_about", [#"\bhow did you (hear|find|learn)\b"#, #"\bwhere did you hear\b"#]),
        ("referrer", [#"\bwho (invited|referred|shared)\b"#, #"\binvited by\b"#, #"\breferred by\b"#]),
        ("pronouns", [#"\bpronoun"#]),
        ("gender", [#"\bgender\b"#]),
        ("age", [#"^age\b"#, #"\byour age\b"#, #"\bhow old\b"#]),
        ("years_experience", [#"\byears of experience\b"#, #"\bexperience \(years\)"#]),
        ("building", [#"\bwhat are you (building|working on)\b"#]),
        ("dietary", [#"\bdietary\b"#, #"\ballerg"#, #"\bfood restriction"#]),
        ("tshirt", [#"\bt ?shirt\b"#, #"\bshirt size\b"#]),
    ]

    static func ruleKey(for label: String) -> String? {
        // Bracketed asides ("If you're a student, write your major") describe
        // fallbacks, not what the question is about.
        let main = label.replacingOccurrences(of: #"[(（][^)）]*[)）]"#, with: " ", options: .regularExpression)
        let text = normalize(main)
        for rule in rules {
            for pattern in rule.patterns where text.range(of: pattern, options: .regularExpression) != nil {
                return rule.key
            }
        }
        return nil
    }

    /// The key a brand new question gets when nothing else fits.
    static func labelKey(for label: String) -> String { "q:" + normalize(label) }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let spaced = folded.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Fuzzy matching against saved questions

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "any", "as", "be", "can", "d", "do", "does", "for", "here", "if", "in",
        "is", "it", "like", "love", "me", "of", "optional", "or", "our", "please", "s", "share", "tell",
        "the", "this", "to", "us", "we", "what", "whats", "which", "would", "you", "your", "event",
    ]

    static func tokens(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init).filter { !stopwords.contains($0) })
    }

    /// The saved key whose question reads most like `label`, if it is close enough.
    static func closestSavedKey(for label: String, in saved: [String: SavedAnswer]) -> String? {
        let mine = tokens(label)
        guard !mine.isEmpty else { return nil }
        var best: (key: String, score: Double)?
        for (key, answer) in saved {
            let theirs = tokens(answer.label)
            let shared = mine.intersection(theirs).count
            guard shared > 0 else { continue }
            let score = Double(shared) / Double(mine.union(theirs).count)
            let strong = score >= 0.6 && (shared >= 2 || mine == theirs)
            if strong, score > (best?.score ?? 0) { best = (key, score) }
        }
        return best?.key
    }

    // MARK: Dropdowns

    /// Maps a remembered answer onto one of this question's options.
    static func choose(_ saved: String, from options: [String]) -> String? {
        let want = normalize(saved)
        guard !want.isEmpty else { return nil }
        if let exact = options.first(where: { normalize($0) == want }) { return exact }
        if let contains = options.first(where: {
            let o = normalize($0)
            return !o.isEmpty && (o.contains(want) || want.contains(o))
        }) { return contains }
        let mine = tokens(saved)
        let scored = options.map { option -> (String, Double) in
            let theirs = tokens(option)
            let union = mine.union(theirs).count
            return (option, union == 0 ? 0 : Double(mine.intersection(theirs).count) / Double(union))
        }
        if let top = scored.max(by: { $0.1 < $1.1 }), top.1 >= 0.5 { return top.0 }
        return nil
    }

    static func chooseMany(_ saved: [String], from options: [String]) -> [String] {
        var picked: [String] = []
        for value in saved {
            if let option = choose(value, from: options), !picked.contains(option) { picked.append(option) }
        }
        return picked
    }

    // MARK: On-device model

    /// Asks Apple's on-device model which saved question means the same thing.
    /// Only question wording goes in; answers are never shown to the model.
    /// Capped at 1.5 seconds so a slow model never holds up a booking.
    static func modelMatch(for label: String, in saved: [String: SavedAnswer]) async -> String? {
        #if os(iOS) && canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await withTaskGroup(of: String?.self) { group in
                group.addTask { await OnDeviceMatcher.pick(question: label, saved: saved) }
                group.addTask { try? await Task.sleep(for: .milliseconds(1500)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        #endif
        return nil
    }
}

#if os(iOS) && canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceMatcher {
    static func pick(question: String, saved: [String: SavedAnswer]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability, !saved.isEmpty else { return nil }
        let candidates = saved.map { (key: $0.key, label: $0.value.label) }.sorted { $0.key < $1.key }.prefix(60)
        let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You match questions from event sign up forms. Given a new question and a numbered list of \
            questions the person already answered, reply with only the number of the one that asks for \
            the same piece of information, or 0 if none do. Different wording or language asking for the \
            same fact counts as the same. Questions about different facts never match.
            """)
        guard let response = try? await session.respond(to: "New question: \(question)\n\nAnswered questions:\n\(list)") else {
            return nil
        }
        let digits = response.content.filter(\.isNumber)
        guard let n = Int(digits), n > 0, n <= candidates.count else { return nil }
        return Array(candidates)[n - 1].key
    }
}
#endif
