import SwiftUI
import UIKit

/// A screenshot shared to Doorlist: the reply is written from the person's saved answers and copied the
/// moment it's ready. The box on top is optional: skip it and the first reply stands; type or say something
/// ("say I'm free tomorrow at 3"), even while the first is still being written, and it's written again with
/// that, and copied too.
struct ReplyView: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var reply = ""
    @State private var hint = ""
    @State private var working = true
    /// What's on the clipboard from here; "Copied" shows while the reply still matches it.
    @State private var copiedText: String?
    @State private var error: String?
    @FocusState private var hintFocused: Bool
    /// The reply being written; a new request with the person's words replaces it.
    @State private var job: Task<Void, Never>?

    private var copied: Bool { !reply.isEmpty && reply == copiedText }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hintBox
                    answerCard
                }
                .padding(Theme.gutter)
            }
            .background(Color.canvas)
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.primary)
                .disabled(reply.isEmpty || working)
                .padding(.horizontal, Theme.gutter).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .onAppear { start() }
        .onDisappear { job?.cancel() }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(working ? "Reading your screen…" : copied ? "Copied. Paste it where you were." : "Your reply")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            if let error {
                Text(error).font(.body).foregroundStyle(.orange)
            } else if !reply.isEmpty {
                // Editable: a quick touch-up before pasting. Copy takes whatever is here.
                TextField("", text: $reply, axis: .vertical)
                    .font(.body)
                    .lineLimit(3...14)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.fill).frame(height: 60).shimmer()
            }
        }
        .card()
    }

    private var hintBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anything to add?").font(.headline)
            + Text("  Optional").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                TextField("e.g. say I'm free tomorrow at 3, keep it short", text: $hint, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($hintFocused)
                    .submitLabel(.send)
                    .onSubmit { start() }
                    .padding(.vertical, 12)
                MicButton(context: "Instructions for a reply", into: $hint, append: true)
                .padding(.vertical, 4)
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            Button {
                start()
            } label: {
                Label(hint.trimmingCharacters(in: .whitespaces).isEmpty ? "Write another" : "Write it with this",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.secondary)
        }
    }

    /// Writes (or rewrites) the reply, replacing one still in flight, so the person's words always win.
    private func start() {
        job?.cancel()
        hintFocused = false
        working = true
        error = nil
        let hint = hint, previous = reply.isEmpty ? nil : reply
        job = Task {
            do {
                let text = try await AIDraft.reply(to: image, hint: hint, previous: previous)
                guard !Task.isCancelled else { return }
                reply = text
                copy()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func copy() {
        guard !reply.isEmpty else { return }
        UIPasteboard.general.string = reply
        copiedText = reply
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
