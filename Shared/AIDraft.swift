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

    /// The person's saved answers, newest first, without contact details.
    static func profile() -> [[String: String]] {
        Array(AnswerStore.shared.all()
            .filter { key, answer in
                !neverSent.contains { key.lowercased().contains($0) || answer.label.lowercased().contains($0) }
            }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(25)
            .map { ["label": $0.value.label, "value": $0.value.value] })
    }

    /// What the person would send next on the screen in this screenshot, in their voice.
    static func reply(to image: UIImage, hint: String?, previous: String?) async throws -> String {
        // About 1280 px on the long side is plenty to read text and keeps the upload small.
        let scale = min(1, 1280 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else { throw DraftError(message: "Couldn't read that screenshot.") }
        var body: [String: Any] = ["image": jpeg.base64EncodedString(), "profile": profile()]
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty { body["hint"] = hint }
        if let previous, !previous.isEmpty { body["previous"] = previous }
        return try await post("v1/reply", body)
    }

    static func write(question: String, notes: String?, context: DraftContext?) async throws -> String {
        var body: [String: Any] = ["question": question, "profile": profile()]
        if let event = context?.event { body["event"] = event }
        if let about = context?.about { body["about"] = String(about.prefix(6000)) }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { body["notes"] = notes }
        return try await post("v1/draft", body)
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> String {
        var req = DoorlistAPI.request(path, timeout: 60)
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
