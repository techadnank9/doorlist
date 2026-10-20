import SwiftUI
import UIKit
import EventKit
import EventKitUI

@MainActor
final class BookingFlowModel: ObservableObject {
    enum Phase {
        case loading
        case asking
        case booking
        case done(BookingStatus, alreadyBooked: Bool)
        case blocked(String)
        case signedOut
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var plan: BookingPlan?
    /// Which fields get a question screen; fixed when asking starts so a step
    /// doesn't vanish while it's being answered.
    @Published var askIDs: [String] = []
    @Published var step = 0
    /// Direction of the last step change, so screens slide the way you went.
    @Published var forward = true

    let input: String
    private(set) var reference: String?
    private var original: BookingPlan?

    init(input: String) {
        self.input = input
        self.reference = LumaClient.eventReference(from: input)
    }

    var eventURL: URL? { reference.map(LumaClient.eventURL(for:)) }
    var event: LumaEvent? { plan?.page.event }
    var isLastStep: Bool { step >= askIDs.count - 1 }
    var currentID: String? { askIDs.indices.contains(step) ? askIDs[step] : nil }

    /// How many answers came from memory, shown so the person sees the app working.
    var rememberedCount: Int {
        plan?.fields.filter { $0.fromMemory && $0.isFilled && !askIDs.contains($0.id) }.count ?? 0
    }

    /// Everything that went to Luma, for the "what we sent" list.
    var sentSummary: [(label: String, value: String)] {
        (plan?.fields ?? []).compactMap { f in
            switch f.kind {
            case .agree: return f.agreed ? (f.label, "Agreed") : nil
            case .multi: return f.choices.isEmpty ? nil : (f.label, f.choices.joined(separator: ", "))
            default:
                let v = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : (f.label, v)
            }
        }
    }

    func start() async {
        guard let reference else { phase = .failed(LumaError.notALumaLink.localizedDescription); return }
        guard let session = SessionStore.load() else { phase = .signedOut; return }
        phase = .loading
        do {
            let fetched = try await LumaClient(session: session).fetchEvent(reference)
            let made = try await BookingPlanner.makePlan(fetched, reference: reference, couponCode: PromoCode.find(in: input))
            plan = made
            original = made
            let toAsk = made.fields.filter(\.needsInput).map(\.id)
            if toAsk.isEmpty {
                await book()
            } else {
                askIDs = toAsk
                step = 0
                phase = .asking
            }
        } catch {
            handle(error)
        }
    }

    func binding(for id: String) -> Binding<PlanField>? {
        guard let initial = plan?.fields.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.plan?.fields.first(where: { $0.id == id }) ?? initial },
            set: { value in
                guard let index = self.plan?.fields.firstIndex(where: { $0.id == id }) else { return }
                self.plan?.fields[index] = value
            }
        )
    }

    func canAdvance(_ field: PlanField) -> Bool {
        field.isAgree || !field.required || field.isFilled
    }

    func advance(animation: Animation?) {
        if isLastStep {
            Task { await book() }
        } else {
            forward = true
            withAnimation(animation) { step += 1 }
        }
    }

    func back(animation: Animation?) {
        guard step > 0 else { return }
        forward = false
        withAnimation(animation) { step -= 1 }
    }

    func book() async {
        if case .booking = phase { return }
        guard let plan, let original else { return }
        phase = .booking
        BookingPlanner.remember(plan, original: original)
        do {
            let status = try await LumaClient().register(BookingPlanner.registration(for: plan))
            let event = plan.page.event
            HistoryStore.shared.add(BookingRecord(
                id: plan.page.eventApiId, eventName: event.name,
                url: LumaClient.eventURL(for: plan.reference).absoluteString,
                status: status, startAt: event.startDate, bookedAt: Date(),
                coverUrl: event.coverUrl, place: event.place,
                answers: sentSummary.map { SentAnswer(question: $0.label, answer: $0.value) },
                platform: .luma
            ))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Notifier.booked(event.name, status: status, platform: .luma, url: eventURL)
            phase = .done(status, alreadyBooked: false)
        } catch {
            handle(error)
        }
    }

    /// Tells the person (by notification) which question the booking is waiting on.
    func notifyWaitingQuestion() {
        guard case .asking = phase, let id = currentID, let field = plan?.field(id) else { return }
        var choices: [String]?
        if case .single(let options) = field.kind { choices = options }
        if case .multi(let options) = field.kind { choices = options }
        Notifier.needsAnswer(field.isAgree ? "Agree to the event's terms?" : field.label,
                             event: event?.name, token: id, choices: choices)
    }

    /// An answer typed into the notification. Fills the question it was for and moves on.
    func receive(token: String, text: String) {
        guard case .asking = phase, currentID == token, let binding = binding(for: token) else { return }
        var field = binding.wrappedValue
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.kind {
        case .text: field.text = value
        case .single(let options): field.text = QuestionMatcher.choose(value, from: options) ?? ""
        case .multi(let options):
            field.choices = QuestionMatcher.chooseMany(value.components(separatedBy: CharacterSet(charactersIn: ",;")), from: options)
        case .agree: field.agreed = ["yes", "y", "agree", "ok", "sure", "i agree"].contains(value.lowercased())
        }
        binding.wrappedValue = field
        Notifier.clearQuestion()
        if canAdvance(field) { advance(animation: nil) } else { notifyWaitingQuestion() }
    }

    func retry() async {
        if plan != nil, case .failed = phase { await book() } else { await start() }
    }

    private func handle(_ error: Error) {
        switch error {
        case PlanBlocker.alreadyBooked(let status):
            phase = .done(status, alreadyBooked: true)
        case let blocker as PlanBlocker:
            phase = .blocked(blocker.localizedDescription)
        case LumaError.signedOut:
            SessionStore.clear()
            phase = .signedOut
        default:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            phase = .failed(error.localizedDescription)
        }
    }
}

extension EnvironmentValues {
    /// False in the share extension, where links can't open.
    @Entry var canOpenLinks = true
}

// MARK: - Flow

/// The booking screens, used by the app's sheet and by the share extension.
struct BookingFlowView: View {
    @ObservedObject var model: BookingFlowModel
    /// The share extension can't open links, sign in or add to Calendar.
    var inExtension = false
    var onConnect: () -> Void = {}
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var stepAnimation: Animation? { reduceMotion ? .easeInOut(duration: 0.2) : Theme.spring }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    LoadingView(label: "Reading the event", detail: "Filling in what you've told us before")
                case .booking:
                    BookingNowView(event: model.event)
                case .asking:
                    QuestionFlow(model: model, animation: stepAnimation)
                case .done(let status, let already):
                    SuccessView(model: model, status: status, alreadyBooked: already,
                                inExtension: inExtension, onClose: onClose)
                case .blocked(let message):
                    MessageView(symbol: "hand.raised.fill", tint: .orange,
                                title: "This one needs Luma", message: message,
                                primary: inExtension ? nil : model.eventURL.map { url in ("Open on Luma", { openURL(url) }) },
                                onClose: onClose)
                case .signedOut:
                    MessageView(symbol: "person.crop.circle.badge.exclamationmark", tint: .orange,
                                title: "Connect Luma first",
                                message: inExtension
                                    ? "Open Doorlist and connect your Luma account, then share the link again."
                                    : "Doorlist books with your own Luma account. Sign in once and you're set.",
                                primary: inExtension ? nil : ("Connect Luma", onConnect),
                                onClose: onClose)
                case .failed(let message):
                    MessageView(symbol: "exclamationmark.triangle.fill", tint: .red,
                                title: "That didn't go through", message: message,
                                primary: ("Try again", { Task { await model.retry() } }),
                                secondary: inExtension ? nil : model.eventURL.map { url in ("Open on Luma", { openURL(url) }) },
                                onClose: onClose)
                }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .environment(\.canOpenLinks, !inExtension)
        .tint(.accentColor)
        .interactiveDismissDisabled(isBooking)
        .task { if case .loading = model.phase { await model.start() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !inExtension { model.notifyWaitingQuestion() }
            if phase == .active { Notifier.clearQuestion() }
        }
        .onChange(of: isAsking) { _, asking in
            // Reached a question while the app wasn't in front (Find booking in the background).
            if asking, !inExtension, scenePhase != .active { model.notifyWaitingQuestion() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AnswerInbox.name)) { note in
            if let (token, text) = AnswerInbox.read(note) { model.receive(token: token, text: text) }
        }
    }

    private var isBooking: Bool { if case .booking = model.phase { true } else { false } }
    private var isAsking: Bool { if case .asking = model.phase { true } else { false } }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isAsking && model.step > 0 {
                Button { model.back(animation: stepAnimation) } label: {
                    Image(systemName: "chevron.backward").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Previous question")
            } else if !isBooking {
                Button("Cancel", action: onClose)
            }
        }
        ToolbarItem(placement: .principal) {
            if isAsking && model.askIDs.count > 1 {
                StepProgress(current: model.step, total: model.askIDs.count)
            }
        }
    }
}

// MARK: - Questions

private struct StepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.accentColor : Color.fill)
                    .frame(width: total > 6 ? 14 : 24, height: 5)
            }
        }
        .animation(Theme.spring, value: current)
        .accessibilityElement()
        .accessibilityLabel("Question \(current + 1) of \(total)")
    }
}

private struct QuestionFlow: View {
    @ObservedObject var model: BookingFlowModel
    let animation: Animation?
    @FocusState private var focused: Bool
    @State private var focusTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let id = model.currentID, let field = model.binding(for: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.step == 0, let event = model.event {
                        EventHeader(event: event)
                        if model.rememberedCount > 0 {
                            Label {
                                Text(LocalizedStringKey("^[\(model.rememberedCount) answer](inflect: true) filled in from memory"))
                            } icon: {
                                Image(systemName: "sparkles")
                            }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }
                    }
                    QuestionScreen(field: field, focused: $focused, onSubmit: submit)
                        .id(id)
                        .transition(transition)
                }
                .padding(Theme.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .bottomActionBar {
                Button(buttonTitle(field.wrappedValue), action: submit)
                    .buttonStyle(.primary)
                    .disabled(!model.canAdvance(field.wrappedValue))
            }
            .onAppear { focusIfText(field.wrappedValue) }
            .onChange(of: model.step) { _, _ in
                if let f = model.currentID.flatMap(model.binding(for:))?.wrappedValue { focusIfText(f) }
            }
        }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func buttonTitle(_ field: PlanField) -> String {
        let finish = model.plan?.requiresApproval == true ? "Request to join" : "Book my spot"
        if field.isAgree && !field.agreed { return model.isLastStep ? "Agree and book" : "Agree and continue" }
        return model.isLastStep ? finish : "Continue"
    }

    private func submit() {
        guard let id = model.currentID, let field = model.binding(for: id) else { return }
        if field.wrappedValue.isAgree { field.wrappedValue.agreed = true }
        guard model.canAdvance(field.wrappedValue) else { return }
        model.advance(animation: animation)
    }

    private func focusIfText(_ field: PlanField) {
        focusTask?.cancel()
        if case .text = field.kind {
            focusTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                focused = true
            }
        } else {
            focused = false
        }
    }
}

/// One question: the label as the headline, then the input that fits it.
private struct QuestionScreen: View {
    @Binding var field: PlanField
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @State private var pendingAdvance: Task<Void, Never>?
    @Environment(\.canOpenLinks) private var canOpenLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.isAgree ? "One quick yes" : field.label)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !field.required {
                    Text("Optional").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            input

            if let hint = field.hint {
                Label(hint, systemImage: "lightbulb").font(.footnote).foregroundStyle(.secondary)
            }

            if field.isAgree {
                RememberToggle(title: "Agree to event terms for me from now on", isOn: $field.remember)
            } else if field.saveKey != nil {
                RememberToggle(title: "Remember for next time", isOn: $field.remember)
            }
        }
    }

    @ViewBuilder private var input: some View {
        switch field.kind {
        case .text(let multiline):
            HStack(alignment: multiline ? .top : .center, spacing: 8) {
                TextField(field.placeholder ?? "Type or tap the mic", text: $field.text,
                          axis: multiline ? .vertical : .horizontal)
                    .lineLimit(multiline ? 4...10 : 1...1)
                    .font(.body)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(isIdentifier)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .submitLabel(multiline ? .return : .next)
                    .focused(focused)
                    .onSubmit { if !multiline { onSubmit() } }
                    .padding(.vertical, 14)
                if !isIdentifier {
                    // Spoken answers suit open questions; emails and handles are faster typed.
                    MicButton(context: field.label) { spoken in
                        field.text = multiline && !field.text.isEmpty ? field.text + " " + spoken : spoken
                    }
                    .padding(.vertical, multiline ? 6 : 0)
                }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .background(Color.surface,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        case .single(let options):
            OptionList(options: options, isSelected: { field.text == $0 }, multiple: false) { option in
                field.text = option
                // Picking the answer is the whole step, so move on by itself.
                pendingAdvance?.cancel()
                pendingAdvance = Task {
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                    onSubmit()
                }
            }
        case .multi(let options):
            OptionList(options: options, isSelected: { field.choices.contains($0) }, multiple: true) { option in
                if let i = field.choices.firstIndex(of: option) {
                    field.choices.remove(at: i)
                } else {
                    field.choices.append(option)
                }
            }
        case .agree(let termsURL):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(field.label).font(.body)
                } icon: {
                    Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                }
                if let termsURL {
                    if canOpenLinks {
                        Link(destination: termsURL) {
                            Label("Read the terms", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        Text(termsURL.absoluteString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .card()
        }
    }

    private var isIdentifier: Bool {
        ["email", "phone"].contains(field.id) || field.placeholder != nil
    }

    private var autocapitalization: TextInputAutocapitalization {
        isIdentifier ? .never : .sentences
    }

    private var keyboard: UIKeyboardType {
        switch field.id {
        case "email": .emailAddress
        case "phone": .phonePad
        default: field.placeholder == "https://" || field.placeholder?.contains(".com") == true ? .URL : .default
        }
    }

    private var contentType: UITextContentType? {
        switch field.id {
        case "email": .emailAddress
        case "phone": .telephoneNumber
        case "name": .name
        case "first_name": .givenName
        case "last_name": .familyName
        default: nil
        }
    }
}

private struct OptionList: View {
    let options: [String]
    let isSelected: (String) -> Bool
    let multiple: Bool
    let onTap: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { onTap(option) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol(isSelected(option)))
                            .font(.title3)
                            .foregroundStyle(isSelected(option) ? Color.accentColor : Color(.tertiaryLabel))
                            .contentTransition(.symbolEffect(.replace))
                        Text(option)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
                if index < options.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Color.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .sensoryFeedback(.selection, trigger: options.filter(isSelected))
    }

    private func symbol(_ on: Bool) -> String {
        multiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
    }
}

private struct RememberToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: "brain")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .tint(.accentColor)
        .padding(.horizontal, 4)
    }
}

// MARK: - Waiting

/// Placeholder in the shape of the event card, so the screen never sits empty.
struct LoadingView: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.fill)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(Color.fill).frame(width: 190, height: 14)
                    Capsule().fill(Color.fill).frame(width: 120, height: 11)
                }
            }
            .shimmer()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(label).font(.headline)
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct BookingNowView: View {
    let event: LumaEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let event { EventHeader(event: event) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Booking your spot").font(.headline)
                }
                Text("Sending your answers to Luma").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Results

private struct SuccessView: View {
    @ObservedObject var model: BookingFlowModel
    let status: BookingStatus
    let alreadyBooked: Bool
    let inExtension: Bool
    let onClose: () -> Void

    @State private var appeared = false
    @State private var addingToCalendar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: status.symbol)
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundStyle(status.tint)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
                        .opacity(appeared ? 1 : 0)
                        .accessibilityHidden(true)
                    Text(alreadyBooked ? "Already on the list" : headline)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)

                if let event = model.event {
                    TicketCard(event: event, status: status)
                        .offset(y: appeared || reduceMotion ? 0 : 24)
                        .opacity(appeared ? 1 : 0)
                }

                if !model.sentSummary.isEmpty && !alreadyBooked {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(model.sentSummary.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                                    Text(row.value).font(.subheadline)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Label("What Doorlist sent", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .card()
                }
            }
            .padding(Theme.gutter)
        }
        .bottomActionBar {
            Button("Done", action: onClose).buttonStyle(.primary)
            if !inExtension {
                HStack(spacing: 10) {
                    if canAddToCalendar {
                        Button { addingToCalendar = true } label: {
                            Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        }
                        .buttonStyle(.secondary)
                    }
                    if let url = model.eventURL {
                        Button { openURL(url) } label: {
                            Label("Open on Luma", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $addingToCalendar) {
            if let event = model.event, let url = model.eventURL {
                CalendarEditor(event: event, url: url).ignoresSafeArea()
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.pop) { appeared = true }
        }
    }

    private var canAddToCalendar: Bool {
        model.event?.startDate != nil && status != .declined
    }

    private var headline: String {
        switch status {
        case .approved: "You're in"
        case .pendingApproval: "Request sent"
        case .waitlist: "You're on the waitlist"
        case .invited: "You're invited"
        case .declined: "Not this time"
        }
    }

    private var message: String {
        if alreadyBooked { return "You already have a spot or a request in for this event." }
        switch status {
        case .approved: return "Luma will email your ticket."
        case .pendingApproval: return "The host reviews every request. Luma will email you when they decide."
        case .waitlist: return "It's full right now. Luma will email you if a spot opens."
        case .invited: return "Luma has your details."
        case .declined: return "The host declined this request."
        }
    }
}

/// The event as a ticket stub: cover on top, details below a perforated edge.
private struct TicketCard: View {
    let event: LumaEvent
    let status: BookingStatus

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: event.coverUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()

            Perforation()

            VStack(alignment: .leading, spacing: 8) {
                Text(event.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let date = event.startDate {
                    Label(date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                          systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let place = event.place {
                    Label(place, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary)
                }
                StatusPill(status: status).padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct Perforation: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.canvas).frame(width: 18, height: 18).offset(x: -9)
            Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Color(.separator))
                .frame(height: 1)
            Circle().fill(Color.canvas).frame(width: 18, height: 18).offset(x: 9)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// A result that isn't a booking: tells what happened and what to do next.
private struct MessageView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity)
        .bottomActionBar {
            if let primary {
                Button(primary.0, action: primary.1).buttonStyle(.primary)
                if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(.secondary) }
            } else {
                Button("Close", action: onClose).buttonStyle(.primary)
            }
        }
    }
}

// MARK: - Shared pieces

struct EventHeader: View {
    let event: LumaEvent

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: event.coverUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.fill
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.name).font(.headline).lineLimit(2)
                if let date = event.startDate {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let place = event.place {
                    Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Apple's own "add event" sheet, which needs no Calendar permission.
private struct CalendarEditor: UIViewControllerRepresentable {
    let event: LumaEvent
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let item = EKEvent(eventStore: store)
        item.title = event.name
        item.startDate = event.startDate
        item.endDate = event.endDate ?? event.startDate?.addingTimeInterval(2 * 3600)
        item.location = event.place
        item.url = url
        item.notes = url.absoluteString
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = item
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
