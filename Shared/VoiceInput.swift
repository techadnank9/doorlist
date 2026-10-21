import SwiftUI
import AVFoundation

/// Speak an answer instead of typing it, and watch it appear as you talk. The microphone streams straight to
/// ElevenLabs Scribe v2 Realtime (about 150 ms behind your voice); Doorlist's server only hands out a single use
/// token for each session, so the API key never reaches the phone. There's no on-device fallback: if ElevenLabs
/// can't be reached, the button says so.
@MainActor
final class VoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        /// Stopped talking; the last words are settling.
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 0...1, for the live level ring.
    @Published private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var socket: URLSessionWebSocketTask?
    /// Audio captured before the socket opened, sent the moment it does, so the first words aren't lost.
    private var pending: [Data] = []
    private var sentFirst = false
    private var committed = ""
    private var partial = ""
    private var onLive: ((String) -> Void)?
    private var onText: ((String) -> Void)?
    private var session: Task<Void, Never>?
    private var settle: CheckedContinuation<Void, Never>?
    /// Set while the permission prompt is up, so a second tap doesn't start twice.
    private var starting = false

    private var transcript: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Tap once to start, again to stop. `onLive` gets the words so far as they arrive; `onText` the final text.
    func toggle(context: String?, onLive: ((String) -> Void)? = nil, onText: @escaping (String) -> Void) {
        switch state {
        case .recording: Task { await stop() }
        case .finishing: break
        default:
            guard !starting else { return }
            self.onLive = onLive
            self.onText = onText
            Task { await start(context: context) }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        stopMicrophone()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        settle?.resume()
        settle = nil
        level = 0
        state = .idle
    }

    // MARK: Start

    private func start(context: String?) async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Microphone access is off. Turn it on in Settings › Doorlist.")
            return
        }
        committed = ""
        partial = ""
        pending = []
        sentFirst = false

        // The token and the microphone start together; audio waits in `pending` until the socket is open.
        let url = Task { try await DoorlistAPI.voiceSession() }
        do {
            try startMicrophone()
        } catch {
            url.cancel()
            state = .failed("Couldn't start the microphone.")
            return
        }
        state = .recording
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        session = Task {
            do {
                let socketURL = try await url.value
                guard !Task.isCancelled, state == .recording || state == .finishing else { return }
                let socket = URLSession.shared.webSocketTask(with: socketURL)
                self.socket = socket
                socket.resume()
                let waiting = pending
                pending = []
                for chunk in waiting { send(chunk) }
                try await listen(socket)
            } catch {
                guard !Task.isCancelled, state == .recording else { return }
                fail("Can't reach ElevenLabs right now. Check your connection and try again.")
            }
        }
    }

    private func startMicrophone() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let pcm = PCM16k(from: format) else { throw VoiceError.message("Unsupported microphone format.") }
        input.removeTap(onBus: 0)
        // About a tenth of a second per buffer: small enough to feel live, big enough not to flood the socket.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
            guard let (data, level) = pcm.convert(buffer) else { return }
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.level = level
                self.send(data)
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Socket

    private func send(_ pcm: Data, commit: Bool = false) {
        guard let socket else { pending.append(pcm); return }
        sentFirst = true
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16_000,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: json, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func listen(_ socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = object["message_type"] as? String else { continue }
            let words = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch type {
            case "partial_transcript":
                partial = words
                onLive?(transcript)
            case "committed_transcript", "committed_transcript_with_timestamps":
                if !words.isEmpty { committed = committed.isEmpty ? words : committed + " " + words }
                partial = ""
                onLive?(transcript)
                if state == .finishing { settle?.resume(); settle = nil }
            case "session_started":
                break
            default:
                if type.hasSuffix("error") || type == "quota_exceeded" || type == "rate_limited" {
                    let detail = (object["error"] as? String) ?? (object["message"] as? String) ?? type
                    fail(type == "quota_exceeded" || type == "rate_limited"
                         ? "Voice is busy right now. Try again in a minute." : "Voice stopped: \(detail)")
                    return
                }
            }
        }
    }

    // MARK: Stop

    private func stop() async {
        guard state == .recording else { return }
        stopMicrophone()
        level = 0
        state = .finishing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Close the last segment and give it a moment to come back; whatever was heard by then is the answer.
        if socket != nil {
            send(Data(count: 3_200), commit: true)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                settle = c
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    self.settle?.resume()
                    self.settle = nil
                }
            }
        }
        let text = transcript
        let reached = sentFirst
        session?.cancel()
        session = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if text.isEmpty {
            state = .failed(reached ? "Didn't catch that. Try again a little closer." : "Can't reach ElevenLabs right now.")
        } else {
            onText?(text)
            state = .idle
        }
    }

    private func fail(_ message: String) {
        stopMicrophone()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        settle?.resume()
        settle = nil
        level = 0
        // Keep what was heard: the words already in the field stay.
        if !transcript.isEmpty { onText?(transcript) }
        state = .failed(message)
    }
}

/// Microphone audio as ElevenLabs wants it: 16 kHz mono 16-bit PCM, plus a 0...1 level for the ring.
/// Runs on the audio thread.
private final class PCM16k: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.output = output
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Double)? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
        let count = Int(out.frameLength)
        var sum = 0.0
        for i in 0..<count { let s = Double(samples[i]) / 32_768; sum += s * s }
        let db = 20 * log10(max(sqrt(sum / Double(count)), 1e-6))
        // -50 dB is silence, 0 dB is loud.
        let level = max(0, min(1, (db + 50) / 50))
        return (Data(bytes: samples, count: count * 2), level)
    }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}

/// The mic button beside every answer field. Tap to talk and the words appear as you speak; tap again to stop.
struct MicButton: View {
    @StateObject private var voice = VoiceInput()
    /// The question, for context.
    var context: String?
    /// Filled live as the person talks. With `append`, spoken words go after what's already typed.
    var text: Binding<String>?
    var append = false
    /// The final words, once the person stops.
    var onText: (String) -> Void = { _ in }

    /// What the field held before this recording, so live words replace only themselves.
    @State private var before: String?

    init(context: String?, onText: @escaping (String) -> Void) {
        self.context = context
        self.onText = onText
    }

    init(context: String?, into text: Binding<String>, append: Bool = false, onDone: @escaping (String) -> Void = { _ in }) {
        self.context = context
        self.text = text
        self.append = append
        self.onText = onDone
    }

    private var recording: Bool { voice.state == .recording }

    var body: some View {
        Button {
            if voice.state != .recording, voice.state != .finishing, let text {
                before = append ? text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            voice.toggle(context: context, onLive: { live in write(live) }, onText: { final in
                write(final)
                before = nil
                onText(final)
            })
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 6)
                    .scaleEffect(1 + voice.level * 0.4)
                    .opacity(recording ? 1 : 0)
                Circle().fill(recording ? Color.red : Color.accentColor.opacity(0.14))
                if voice.state == .finishing {
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

    private func write(_ spoken: String) {
        guard let text else { return }
        let base = before ?? ""
        text.wrappedValue = base.isEmpty ? spoken : base + " " + spoken
    }
}
