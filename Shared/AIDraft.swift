import SwiftUI

/// What the event is about, for Write with AI. Each booking flow sets it once for its questions.
struct DraftContext {
    var event: String?
    var about: String?
}

private struct DraftContextKey: EnvironmentKey {
    static let defaultValue: DraftContext? = nil
}

extension EnvironmentValues {
    var draftContext: DraftContext? {
        get { self[DraftContextKey.self] }
        set { self[DraftContextKey.self] = newValue }
    }
}

/// Writing help for a question that wants a sentence or a paragraph. Doorlist's server writes it from the
/// event's description and the person's saved answers, or polishes their own notes. Contact details
/// (email, phone, address) are never sent.
enum AIDraft {
    private static let neverSent = ["email", "phone", "address", "street", "zip", "postal", "birth", "passport", "ssn"]

    static func write(question: String, notes: String?, context: DraftContext?) async throws -> String {
        let saved = AnswerStore.shared.all()
            .filter { key, answer in
                !neverSent.contains { key.lowercased().contains($0) || answer.label.lowercased().contains($0) }
            }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(25)
            .map { ["label": $0.value.label, "value": $0.value.value] }
        var body: [String: Any] = ["question": question, "profile": Array(saved)]
        if let event = context?.event { body["event"] = event }
        if let about = context?.about { body["about"] = String(about.prefix(6000)) }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { body["notes"] = notes }

        var req = DoorlistAPI.request("v1/draft", timeout: 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else {
            throw DraftError(message: DoorlistAPI.message(from: data, status: status))
        }
        return text
    }

    struct DraftError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Below a long answer box: Write with AI when it's empty, Polish with AI once the person has typed or
/// spoken some notes, and Undo to get their own words back.
struct AIWriteBar: View {
    let question: String
    @Binding var text: String
    @Environment(\.draftContext) private var context
    @State private var working = false
    @State private var previous: String?
    @State private var error: String?

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: run) {
                    Label(working ? (isEmpty ? "Writing…" : "Polishing…") : (isEmpty ? "Write with AI" : "Polish with AI"),
                          systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(working)
                if let previous, !working {
                    Button("Undo") {
                        text = previous
                        self.previous = nil
                    }
                    .font(.subheadline)
                }
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }
            Text(error ?? (isEmpty ? "Writes an answer that fits this event, from your saved answers."
                                   : "Turns your notes into a clean answer. Nothing new gets made up."))
                .font(.footnote)
                .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        let notes = isEmpty ? nil : text
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let written = try await AIDraft.write(question: question, notes: notes, context: context)
                previous = text
                text = written
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
