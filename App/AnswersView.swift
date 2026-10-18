import SwiftUI

/// Everything Doorlist remembers, grouped the way people think about it, with
/// the common details offered up front so the first booking asks less.
struct AnswersView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showConnect: Bool
    @State private var editing: EditTarget?
    @State private var confirmDisconnect = false
    @State private var confirmDelete = false
    @State private var accountError: String?
    @State private var search = ""

    private var searchResults: [(key: String, title: String, answer: SavedAnswer)] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return state.answers.compactMap { key, answer in
            let title = Self.allTitles[key] ?? answer.label
            let hit = ([title, answer.value] + answer.questions).contains { $0.localizedCaseInsensitiveContains(q) }
            return hit ? (key: key, title: title, answer: answer) : nil
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static let allTitles: [String: String] = {
        var titles = otherTitles
        for group in groups { for item in group.items { titles[item.key] = item.title } }
        return titles
    }()

    struct EditTarget: Identifiable {
        let key: String
        let title: String
        let label: String
        let value: String
        let choices: [String]?
        let questions: [String]
        var id: String { key }
    }

    struct Known {
        let key: String
        let title: String
        let symbol: String
    }

    /// Shared keys, in the order people expect to see them.
    static let groups: [(title: String, items: [Known])] = [
        ("Basics", [
            Known(key: "name", title: "Full name", symbol: "person"),
            Known(key: "email", title: "Email", symbol: "envelope"),
            Known(key: "phone", title: "Phone", symbol: "phone"),
        ]),
        ("Work", [
            Known(key: "company", title: "Company or school", symbol: "building.2"),
            Known(key: "job_title", title: "Job title", symbol: "briefcase"),
            Known(key: "work_email", title: "Work email", symbol: "envelope.badge"),
            Known(key: "building", title: "What you're building", symbol: "hammer"),
        ]),
        ("Profiles", [
            Known(key: "linkedin", title: "LinkedIn", symbol: "person.crop.square"),
            Known(key: "twitter", title: "X / Twitter", symbol: "at"),
            Known(key: "github", title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right"),
            Known(key: "instagram", title: "Instagram", symbol: "camera"),
            Known(key: "website", title: "Website", symbol: "globe"),
        ]),
    ]

    /// Shown only once saved.
    static let otherTitles: [String: String] = [
        "first_name": "First name", "last_name": "Last name", "telegram": "Telegram", "youtube": "YouTube",
        "whatsapp": "WhatsApp", "wechat": "WeChat", "school": "School", "major": "Major",
        "graduation_year": "Graduation year", "city": "City", "country": "Country",
        "heard_about": "How you heard about events", "referrer": "Who invited you", "pronouns": "Pronouns",
        "gender": "Gender", "age": "Age", "years_experience": "Years of experience",
        "dietary": "Dietary needs", "tshirt": "T-shirt size",
    ]

    private var groupedKeys: Set<String> { Set(Self.groups.flatMap { $0.items.map(\.key) }) }

    private var others: [(key: String, title: String, answer: SavedAnswer)] {
        state.answers.filter { !groupedKeys.contains($0.key) }
            .map { (key: $0.key, title: Self.otherTitles[$0.key] ?? $0.value.label, answer: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
              if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                Section(searchResults.isEmpty ? "No matches" : "Matches") {
                    ForEach(searchResults, id: \.key) { row in
                        Button {
                            editing = EditTarget(key: row.key, title: row.title, label: row.answer.label,
                                                 value: row.answer.value, choices: row.answer.choices,
                                                 questions: row.answer.questions)
                        } label: {
                            QARow(question: row.title, answer: row.answer.value, extra: row.answer.questions.count - 1)
                        }
                    }
                }
              } else {
                profileHeader

                ForEach(Self.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.key) { item in
                            knownRow(item)
                        }
                    }
                }

                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.key) { row in
                            Button {
                                editing = EditTarget(key: row.key, title: row.title, label: row.answer.label,
                                                     value: row.answer.value, choices: row.answer.choices,
                                                     questions: row.answer.questions)
                            } label: {
                                QARow(question: row.title, answer: row.answer.value,
                                      extra: row.answer.questions.count - 1)
                            }
                        }
                        .onDelete { offsets in
                            let keys = offsets.map { others[$0].key }
                            keys.forEach(AnswerStore.shared.remove)
                            state.refresh()
                        }
                    } header: {
                        Text("Hosts' own questions")
                    } footer: {
                        Text("Tap any answer to see every question it's used for and change it. Swipe left to forget one.")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { state.autoAgree }, set: { state.setAutoAgree($0) })) {
                        Label("Agree to event terms for me", systemImage: "checkmark.shield")
                    }
                    .tint(.accentColor)
                } header: {
                    Text("Booking")
                } footer: {
                    Text("Ticks required terms and consent boxes so bookings go straight through. Optional boxes, like newsletters, stay off.")
                }

                Section {
                    if state.signedIn {
                        Label("Signed in with Apple", systemImage: "checkmark.icloud.fill")
                            .foregroundStyle(.green)
                        Button("Sign out") { Account.session = nil; state.refresh() }
                        Button("Delete account", role: .destructive) { confirmDelete = true }
                    } else {
                        AppleSignInButton(label: .signIn) { outcome in
                            accountError = outcome.error
                            state.refresh()
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        if let accountError { Text(accountError).font(.footnote).foregroundStyle(.red) }
                    }
                } header: {
                    Text("Your account")
                } footer: {
                    Text(state.signedIn
                         ? "Your answers and bookings are saved to your account, so a new phone signed into the same Apple ID gets them back."
                         : "Sign in to keep your answers and bookings when you switch phones. Without it they stay only on this one.")
                }

                Section {
                    if state.connected {
                        Label("Luma connected", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Disconnect Luma", role: .destructive) { confirmDisconnect = true }
                    } else {
                        Button { showConnect = true } label: {
                            Label("Connect Luma", systemImage: "link")
                        }
                    }
                } header: {
                    Text("Event sites")
                } footer: {
                    Text("Your Luma, Partiful and Eventbrite logins stay on this phone and never sync.")
                }
              }
            }
            .searchable(text: $search, prompt: "Search questions and answers")
            .listStyle(.insetGrouped)
            .navigationTitle("Answers")
            .sheet(item: $editing) { target in
                EditAnswerSheet(target: target) { state.refresh() }
            }
            .confirmationDialog("Delete your Doorlist account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    Task {
                        do {
                            try await ProfileSync.deleteAccount()
                            accountError = nil
                        } catch {
                            accountError = error.localizedDescription
                        }
                        state.refresh()
                    }
                }
            } message: {
                Text("This erases your saved answers and bookings from Doorlist's servers. What's on this phone stays until you delete the app.")
            }
            .confirmationDialog("Disconnect Luma?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await state.signOut() } }
            } message: {
                Text("Your saved answers stay. You'll need to sign in again to book.")
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.profileName ?? "Your answers").font(.title3.weight(.semibold))
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }

    private var initials: String {
        let parts = (state.profileName ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "D" : letters.uppercased()
    }

    private var summary: String {
        let count = state.answers.count
        return count == 0 ? "Answer once, reused on every event" : "\(count) remembered, reused on every event"
    }

    @ViewBuilder private func knownRow(_ item: Known) -> some View {
        let saved = state.answers[item.key]
        Button {
            editing = EditTarget(key: item.key, title: item.title, label: saved?.label ?? item.title,
                                 value: saved?.value ?? "", choices: saved?.choices,
                                 questions: saved?.questions ?? [])
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .foregroundStyle(saved == nil ? Color.accentColor : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                if let saved {
                    QARow(question: item.title, answer: saved.value,
                          extra: saved.questions.filter { $0 != item.title }.count)
                } else {
                    Text("Add \(item.title.lowercased())").foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .swipeActions {
            if saved != nil {
                Button("Forget", role: .destructive) {
                    AnswerStore.shared.remove(item.key)
                    state.refresh()
                }
            }
        }
    }
}

private struct EditAnswerSheet: View {
    let target: AnswersView.EditTarget
    var onSave: () -> Void
    @State private var value: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(target: AnswersView.EditTarget, onSave: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        _value = State(initialValue: target.value)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        TextField(placeholder, text: $value, axis: .vertical)
                            .lineLimit(1...8)
                            .keyboardType(keyboard)
                            .textContentType(contentType)
                            .textInputAutocapitalization(isIdentifier ? .never : .sentences)
                            .autocorrectionDisabled(isIdentifier)
                            .focused($focused)
                            .padding(.vertical, 10)
                        if !isIdentifier {
                            MicButton(context: target.label) { value = $0 }
                        }
                    }
                } header: {
                    Text("Your answer")
                } footer: {
                    if target.choices != nil {
                        Text("Separate several choices with commas.")
                    } else if target.key == "phone" {
                        Text("Include the country code, like +1 for the US.")
                    }
                }

                if !target.questions.isEmpty {
                    Section {
                        ForEach(target.questions, id: \.self) { question in
                            Label(question, systemImage: "questionmark.bubble")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(target.questions.count == 1 ? "Used for this question" : "Used for these \(target.questions.count) questions")
                    } footer: {
                        Text("Doorlist fills this answer in whenever an event asks any of these, or something that means the same.")
                    }
                }

                if !target.value.isEmpty {
                    Section {
                        Button("Forget this answer", role: .destructive) {
                            AnswerStore.shared.remove(target.key)
                            onSave()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmed.isEmpty).fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let choices = target.choices == nil ? nil
            : trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let stored = target.key == "phone" ? BookingPlanner.normalizePhone(trimmed) : trimmed
        AnswerStore.shared.set(target.key, label: target.label, value: stored, choices: choices)
        onSave()
        dismiss()
    }

    private var isIdentifier: Bool {
        ["email", "work_email", "phone", "linkedin", "twitter", "github", "instagram", "website"].contains(target.key)
    }

    private var placeholder: String {
        switch target.key {
        case "email", "work_email": "you@example.com"
        case "phone": "+1 415 555 0100"
        case "linkedin": "linkedin.com/in/you"
        case "twitter", "instagram": "@handle"
        case "github": "username"
        case "website": "https://"
        default: "Your answer"
        }
    }

    private var keyboard: UIKeyboardType {
        switch target.key {
        case "email", "work_email": .emailAddress
        case "phone": .phonePad
        case "linkedin", "website": .URL
        default: .default
        }
    }

    private var contentType: UITextContentType? {
        switch target.key {
        case "email", "work_email": .emailAddress
        case "phone": .telephoneNumber
        case "name": .name
        case "company": .organizationName
        case "job_title": .jobTitle
        case "website", "linkedin": .URL
        default: nil
        }
    }
}

/// A remembered answer shown as question then answer.
private struct QARow: View {
    let question: String
    let answer: String
    var extra = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Text(answer).foregroundStyle(.primary).lineLimit(3)
            if extra > 0 {
                Text(extra == 1 ? "Also answers 1 other question" : "Also answers \(extra) other questions")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
