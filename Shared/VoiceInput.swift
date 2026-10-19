import SwiftUI
import AVFoundation
import Speech

/// Speak an answer instead of typing it. Records on the phone, then Doorlist's
/// server turns it into text with ElevenLabs Scribe; if the server can't, Apple's
/// speech recognition does it on the device.
@MainActor
final class VoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 0...1, for the live level ring.
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var seconds: Double = 0
    /// The current recording's file, a fresh name each time so an old transcription can't read a new one.
    private var fileURL: URL?
    private var transcription: Task<Void, Never>?
    /// Set while the permission prompt is up, so a second tap doesn't start twice.
    private var starting = false

    /// Press once to start, again to stop; the text arrives in `onText`.
    func toggle(context: String?, onText: @escaping (String) -> Void) {
        switch state {
        case .recording: stop(context: context, onText: onText)
        case .transcribing: break
        default:
            guard !starting else { return }
            Task { await start() }
        }
    }

    func cancel() {
        transcription?.cancel()
        transcription = nil
        meter?.invalidate()
        recorder?.stop()
        recorder = nil
        level = 0
        state = .idle
    }

    private func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Microphone access is off. Turn it on in Settings › Doorlist.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("doorlist-answer-\(UUID().uuidString).m4a")
            self.fileURL = fileURL
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record(forDuration: 120)
            self.recorder = recorder
            state = .recording
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    // -50 dB is silence, 0 dB is loud.
                    self.level = max(0, min(1, (Double(r.averagePower(forChannel: 0)) + 50) / 50))
                }
            }
        } catch {
            state = .failed("Couldn't start the microphone.")
        }
    }

    private func stop(context: String?, onText: @escaping (String) -> Void) {
        seconds = recorder?.currentTime ?? 0
        meter?.invalidate()
        recorder?.stop()
        recorder = nil
        level = 0
        state = .transcribing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let fileURL else { state = .idle; return }
        let seconds = seconds
        transcription?.cancel()
        transcription = Task {
            // Each recording has its own name, so removing it is safe even after a cancel.
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let text = try await transcribe(fileURL, seconds: seconds, context: context)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                if text.isEmpty {
                    state = .failed("Didn't catch that. Try again a little closer.")
                } else {
                    onText(text)
                    state = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func transcribe(_ fileURL: URL, seconds: Double, context: String?) async throws -> String {
        // Words from the question help names and jargon come out right.
        let terms = (context ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 3 }
        if let text = try? await DoorlistAPI.transcribe(fileURL, seconds: seconds, keyterms: Array(terms.prefix(10))),
           !text.isEmpty {
            return text
        }
        return try await AppleSpeech.transcribe(fileURL)
    }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}

/// Apple's recognizer on the recorded file, on the device when supported.
enum AppleSpeech {
    static func transcribe(_ file: URL) async throws -> String {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw VoiceError.message("Speech recognition is off. Turn it on in Settings › Doorlist.") }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw VoiceError.message("Speech recognition isn't available right now.")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }
}

/// The mic button beside every answer field. Tap to talk, tap again to stop.
struct MicButton: View {
    @StateObject private var voice = VoiceInput()
    /// The question, used as hint words for transcription.
    var context: String?
    let onText: (String) -> Void

    private var recording: Bool { voice.state == .recording }

    var body: some View {
        Button { voice.toggle(context: context, onText: onText) } label: {
            ZStack {
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 6)
                    .scaleEffect(1 + voice.level * 0.4)
                    .opacity(recording ? 1 : 0)
                Circle().fill(recording ? Color.red : Color.accentColor.opacity(0.14))
                if voice.state == .transcribing {
                    ProgressView().tint(.accentColor)
                } else {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(recording ? Color.white : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.08), value: voice.level)
            .animation(.snappy(duration: 0.2), value: voice.state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop recording" : "Answer by voice")
        .overlay(alignment: .topTrailing) {
            if case .failed(let message) = voice.state {
                Button { voice.cancel() } label: {
                    Text(message)
                        .font(.caption)
                        .padding(10)
                        .frame(width: 230, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(y: -58)
                .transition(.opacity)
                .task {
                    AccessibilityNotification.Announcement(message).post()
                    // Only clear if the bubble timed out; if it went away first, a new recording may be running.
                    guard (try? await Task.sleep(for: .seconds(4))) != nil else { return }
                    voice.cancel()
                }
            }
        }
        .onDisappear { voice.cancel() }
    }
}
