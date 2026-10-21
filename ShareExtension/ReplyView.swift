import SwiftUI
import UIKit

/// A screenshot shared to Doorlist: the reply is written from the person's saved answers and copied the
/// moment it's ready. A hint below ("say I'm free tomorrow at 3") rewrites it, and that's copied too.
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

    private var copied: Bool { !reply.isEmpty && reply == copiedText }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    answerCard
                    hintBox
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
        .task { await write() }
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
            Text("Change it").font(.headline)
            HStack(alignment: .top, spacing: 8) {
                TextField("e.g. say I'm free tomorrow at 3, keep it short", text: $hint, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($hintFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await write() } }
                    .padding(.vertical, 12)
                MicButton(context: "Instructions for a reply") { spoken in
                    hint = hint.isEmpty ? spoken : hint + " " + spoken
                }
                .padding(.vertical, 4)
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .background(Color.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            Button {
                Task { await write() }
            } label: {
                Label(hint.trimmingCharacters(in: .whitespaces).isEmpty ? "Write another" : "Rewrite with this",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.secondary)
            .disabled(working)
        }
    }

    private func write() async {
        hintFocused = false
        working = true
        error = nil
        defer { working = false }
        do {
            let text = try await AIDraft.reply(to: image, hint: hint, previous: reply.isEmpty ? nil : reply)
            reply = text
            copy()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy() {
        guard !reply.isEmpty else { return }
        UIPasteboard.general.string = reply
        copiedText = reply
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
