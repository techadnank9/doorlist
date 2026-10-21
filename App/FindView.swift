import SwiftUI
import CoreLocation

@MainActor
final class FindModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(SearchStage)
        case asking(question: String, options: [String])
        case results
        case failed(String)
    }

    @Published var query = ""
    @Published var phase: Phase = .idle
    @Published var results: [FoundEvent] = []
    /// The match Doorlist picked to book by itself, if any.
    @Published var autoPicked: FoundEvent?
    @Published var showAll = false
    /// The place the request names, once the server has read it; otherwise the phone's town is shown.
    @Published private(set) var area: String?
    @Published private(set) var lastQuery = ""
    private var clarifications: [Clarification] = []
    /// Sent with each search, so a reconnect joins it on the server rather than starting over.
    private var requestId = UUID().uuidString
    /// Set when the connection dropped: the search the server is still running for us.
    private var resumable: (autoBook: Bool, book: (EventLink) -> Void)?
    private var resumeOnActive: NSObjectProtocol?
    /// Rejoins made without a tap, capped so a phone that's truly offline doesn't loop.
    private var autoResumes = 0
    /// How the running search should finish: whether to book, and how.
    private var finish: (autoBook: Bool, book: (EventLink) -> Void)?
    /// The request whose outcome is already showing, from the stream or from iOS's background fetch.
    private var delivered: String?

    init() {
        // iOS suspends the app soon after it leaves the screen, which drops the search's
        // connection. Back on screen, pick that search up again.
        resumeOnActive = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeIfDropped() }
        }
        // The same search's result, fetched by iOS while the app was suspended.
        SearchFollowUp.shared.deliver = { [weak self] id, outcome in self?.apply(outcome, for: id) }
    }

    /// Shows a search's outcome once, whichever way it arrived first.
    private func apply(_ outcome: SearchOutcome, for id: String) {
        guard id == requestId, delivered != id, let finish else { return }
        delivered = id
        resumable = nil
        SearchFollowUp.shared.cancel(requestId: id)
        switch outcome {
        case .question(let q, let options):
            phase = .asking(question: q, options: options)
        case .events(let found):
            results = found
            phase = .results
            let active = UIApplication.shared.applicationState == .active
            guard finish.autoBook, let best = found.first, best.canAutoBook, let link = best.link else {
                if !active { Notifier.searchReady(found.count, query: lastQuery) }
                return
            }
            autoPicked = best
            if active { finish.book(link) } else { Notifier.found(best.title, url: link.url) }
        }
    }

    private func resumeIfDropped() {
        guard let pending = resumable, case .failed = phase, autoResumes < 2 else { return }
        autoResumes += 1
        run(autoBook: pending.autoBook, book: pending.book, resume: true)
    }

    var isWorking: Bool { if case .working = phase { true } else { false } }

    func search(autoBook: Bool, book: @escaping (EventLink) -> Void) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        if text != lastQuery { clarifications = [] }
        // Try again after a dropped connection rejoins the same search.
        let resume = text == lastQuery && resumable != nil
        lastQuery = text
        run(autoBook: autoBook, book: book, resume: resume)
    }

    /// The person answered the follow-up question.
    func answer(_ answer: String, autoBook: Bool, book: @escaping (EventLink) -> Void) {
        guard case .asking(let question, _) = phase else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        clarifications.append(Clarification(question: question, answer: trimmed))
        run(autoBook: autoBook, book: book)
    }

    /// After a booking finishes, mark the results it covered.
    func refreshBooked() {
        let booked = Set(HistoryStore.shared.all().filter { $0.status != .declined }.map { EventSearch.normalize($0.url) })
        for i in results.indices { results[i].alreadyBooked = booked.contains(EventSearch.normalize(results[i].url)) }
        if let picked = autoPicked, booked.contains(EventSearch.normalize(picked.url)) { autoPicked = nil }
    }

    func reset() {
        resumable = nil
        phase = .idle
        results = []
        autoPicked = nil
        clarifications = []
    }

    private func run(autoBook: Bool, book: @escaping (EventLink) -> Void, resume: Bool = false) {
        if !resume {
            requestId = UUID().uuidString
            autoResumes = 0
        }
        resumable = nil
        finish = (autoBook, book)
        let id = requestId
        var followingUp = false
        area = nil
        phase = .working(.locating)
        results = []
        autoPicked = nil
        showAll = false
        let request = lastQuery
        let asked = clarifications

        // No UIKit background task: ending one off the main thread crashed the app (Sentry DOORLIST-IOS-2),
        // and iOS's background fetch (SearchFollowUp) now carries the search while the app is away.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await EventSearch.run(request, clarifications: asked, requestId: id) { [weak self] stage in
                    guard let self, self.delivered != id else { return }
                    if case .searchingIn(let area) = stage { self.area = area } else { self.phase = .working(stage) }
                    // The server has the search now: have iOS fetch its result too, in case the app is suspended.
                    if case .searching = stage, !followingUp {
                        followingUp = true
                        SearchFollowUp.shared.start(requestId: id, query: request)
                    }
                }
                apply(outcome, for: id)
            } catch _ where delivered == id {
                // The background fetch already showed it; the stream's drop doesn't matter.
            } catch SearchError.connectionLost {
                resumable = (autoBook, book)
                phase = .failed(SearchError.connectionLost.localizedDescription)
                // Already back on screen (the drop wasn't a suspension): pick it up now.
                if UIApplication.shared.applicationState == .active { resumeIfDropped() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

}

/// "I want to go to…": searches the web for a fitting event and books it on
/// whatever site it's on. One field, one button; everything else is a default.
struct FindView: View {
    @Binding var booking: BookingRequest?
    @StateObject private var model = FindModel()
    @ObservedObject private var location = LocationProvider.shared
    @AppStorage("autoBookBestMatch") private var autoBook = true
    @State private var showSettings = false
    @State private var followUp = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let examples = ["Free AI meetup this week", "Rooftop party Saturday night", "Run club tomorrow morning"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !location.isReady { locationCard }
                    askCard
                    content
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.spring, value: model.phase)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.canvas)
            .navigationTitle("Find")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Search settings")
                }
            }
            .sheet(isPresented: $showSettings) { FindSettingsView() }
            .task { _ = await location.current() }
            .onReceive(NotificationCenter.default.publisher(for: .doorlistDataChanged)) { _ in model.refreshBooked() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: examplesRow
        case .working(let stage): ProgressSteps(stage: stage, place: model.area.map { "in \($0)" } ?? location.place?.city.map { "near \($0)" })
        case .asking(let question, let options): followUpCard(question, options)
        case .results: resultsList
        case .failed(let message): failure(message)
        }
    }

    // MARK: Location

    /// Asked before the system prompt, so the person knows why. Location makes
    /// "near me" mean something; a typed city works too.
    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Search near you", systemImage: "location.fill")
                .font(.headline)
            Text(location.wasDenied
                 ? "Location is off for Doorlist. Turn it on in Settings, or type your city."
                 : "Doorlist uses your town, never your exact spot, to find events you can actually get to.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if location.wasDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.primary)
                } else {
                    Button("Use my location") { location.requestPermission() }.buttonStyle(.primary)
                }
                Button("Type a city") { showSettings = true }.buttonStyle(.secondary)
            }
        }
        .card(padding: 18)
        .transition(.opacity)
    }

    // MARK: The ask

    private var trimmedQuery: String { model.query.trimmingCharacters(in: .whitespaces) }

    /// One field, like Messages: the mic while it's empty, a send arrow once there's text.
    private var askCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("What do you want to go to?", text: $model.query, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .padding(.vertical, 14)
                if trimmedQuery.isEmpty {
                    MicButton(context: nil, into: $model.query) { _ in search() }
                    .padding(.bottom, 4)
                } else {
                    Button(action: search) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(model.isWorking)
                    .accessibilityLabel(autoBook ? "Find and book" : "Find events")
                    .padding(.bottom, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 16).padding(.trailing, 6)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: trimmedQuery.isEmpty)

            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location").imageScale(.small)
                    Text((location.place?.city ?? location.place?.label.nilIfEmpty).map { "Near \($0)" } ?? "Anywhere")
                    Text("·")
                    Text(autoBook ? "Auto-books free matches" : "Shows matches only")
                }
                .lineLimit(1)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens search settings")
        }
    }

    private var examplesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try something like").font(.subheadline).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        model.query = example
                        search()
                    } label: {
                        Text(example)
                            .font(.subheadline)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color.surface, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.primary)
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: Follow-up question

    private func followUpCard(_ question: String, _ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if !options.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { answer(option) }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.pressable)
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("Or say it your way", text: $followUp)
                    .submitLabel(.send)
                    .onSubmit { answer(followUp) }
                    .padding(12)
                    .background(Color.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                MicButton(context: question, into: $followUp) { answer($0) }
            }
        }
        .card()
        .transition(.opacity)
    }

    // MARK: Results

    @ViewBuilder private var resultsList: some View {
        if model.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Nothing fit that").font(.headline)
                Text("Try a wider time, or say what kind of event.").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            let best = model.results[0]
            let rest = Array(model.results.dropFirst())
            let shown = model.showAll ? rest : Array(rest.prefix(3))
            VStack(alignment: .leading, spacing: 12) {
                TopPickCard(event: best, booking: model.autoPicked == best) { open(best) }
                if !rest.isEmpty {
                    Text("Also fits").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                            ResultRow(event: event) { open(event) }
                            if index < shown.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(Color.surface,
                                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    if rest.count > 3 && !model.showAll {
                        Button("Show \(rest.count - 3) more") { model.showAll = true }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Search didn't go through", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: search).buttonStyle(.secondary)
        }
        .card()
    }

    // MARK: Actions

    private func search() {
        focused = false
        Telemetry.capture("search_submitted", ["auto_book": autoBook])
        Task { await Notifier.requestPermission() }
        model.search(autoBook: autoBook) { link in booking = BookingRequest(input: link.url.absoluteString) }
    }

    private func answer(_ text: String) {
        followUp = ""
        model.answer(text, autoBook: autoBook) { link in booking = BookingRequest(input: link.url.absoluteString) }
    }

    private func open(_ event: FoundEvent) {
        guard let link = event.link else { return }
        booking = BookingRequest(input: link.url.absoluteString)
    }
}

// MARK: - Progress

/// What the search is doing right now, as a short checklist, so the wait
/// reads as work rather than a spinner.
private struct ProgressSteps: View {
    let stage: SearchStage
    let place: String?

    private var steps: [(title: String, done: Bool, current: Bool)] {
        let order: [SearchStage] = [.locating, .searching, .checking(0), .ranking]
        let index: Int = switch stage {
        case .locating: 0
        case .searchingIn, .searching: 1
        case .checking: 2
        case .ranking: 3
        }
        let checking: String = if case .checking(let n) = stage, n > 0 { "Opening \(n) event pages to check them" } else { "Opening each event page to check it" }
        let titles = [
            place.map { "Searching \($0)" } ?? "Finding where to look",
            "Looking across Luma, Partiful, Eventbrite and the web",
            checking,
            "Picking the best fit",
        ]
        return order.indices.map { (titles[$0], $0 < index, $0 == index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 12) {
                    ZStack {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step.current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.quaternary)
                        }
                    }
                    .frame(width: 22)
                    Text(step.title)
                        .font(.subheadline)
                        .foregroundStyle(step.current || step.done ? .primary : .tertiary)
                }
            }
            Text("Usually under a minute. You'll get a notification if you leave.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

// MARK: - Result views

/// The single best match, given the most room (and the only accent border).
private struct TopPickCard: View {
    let event: FoundEvent
    let booking: Bool
    let onBook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: event.image.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(event.alreadyBooked ? "Booked" : booking ? "Booking this for you" : "Best match")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(event.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                EventFacts(event: event)
                if let why = event.why, !why.isEmpty {
                    Text(why).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Badges(event: event, showBooked: false)
                if event.alreadyBooked {
                    Label("You're going", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    Button(action: onBook) {
                        Text(event.free ? "Book on \(event.siteName)" : "Open on \(event.siteName)")
                    }
                    .buttonStyle(.primary)
                    .disabled(event.link == nil)
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(booking ? 0.9 : 0), lineWidth: 2)
        }
    }
}

private struct ResultRow: View {
    let event: FoundEvent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    EventFacts(event: event)
                    Badges(event: event)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint(event.free ? "Books it" : "Opens the event page")
    }
}

private struct EventFacts: View {
    let event: FoundEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let date = event.start {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                }
                Text("·")
                Text(event.free ? "Free" : (event.priceText ?? "Price on page"))
                    .foregroundStyle(event.free ? Color.green : Color.secondary)
            }
            if let place = event.place, !place.isEmpty {
                Text(place).lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// Only the facts that change what you'd do: clashes, sold out, already going, unchecked.
private struct Badges: View {
    let event: FoundEvent
    /// The top card says "You're going" in its action row instead.
    var showBooked = true

    var body: some View {
        let items: [(String, String, Color)] = [
            event.alreadyBooked && showBooked ? ("You're already going", "checkmark.circle.fill", .green) : nil,
            event.clashes ? ("Clashes with your calendar", "calendar.badge.exclamationmark", .orange) : nil,
            event.soldOut ? ("Sold out", "xmark.circle", .red) : nil,
            !event.verified ? ("Couldn't check this page", "questionmark.circle", .secondary) : nil,
        ].compactMap { $0 }
        if !items.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.0) { text, symbol, tint in
                    Label(text, systemImage: symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tint.opacity(0.12), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Settings

/// Where to search, and two defaults. No accounts or keys here: the server has those.
struct FindSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var location = LocationProvider.shared
    @AppStorage("autoBookBestMatch") private var autoBook = true
    @State private var city = ""
    @State private var skipBusy = CalendarGuard.isOn
    @State private var calendarDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if location.isAllowed {
                        Button {
                            city = ""
                            Task { await location.setManual(""); _ = await location.current() }
                        } label: {
                            HStack {
                                Label("Where I am", systemImage: "location.fill")
                                Spacer()
                                if location.place?.isManual != true { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(location.place?.isManual != true ? .isSelected : [])
                    } else {
                        Button("Use my location") { location.requestPermission() }
                    }
                    TextField("Or type a city", text: $city)
                        .textContentType(.addressCity)
                        .submitLabel(.done)
                        .onSubmit { Task { await location.setManual(city) } }
                } header: {
                    Text("Search near")
                } footer: {
                    Text(location.place.map { "Now: \($0.label.nilIfEmpty ?? "your location")." } ?? "Not set yet.")
                }

                Section {
                    Toggle("Book the best free match for me", isOn: $autoBook)
                } footer: {
                    Text("Only when it's free, checked, and a strong fit. Paid events always wait for you.")
                }

                Section {
                    Toggle("Skip times I'm busy", isOn: $skipBusy)
                        .onChange(of: skipBusy) { _, on in
                            guard on else { CalendarGuard.isOn = false; return }
                            Task {
                                let ok = CalendarGuard.hasAccess ? true : await CalendarGuard.requestAccess()
                                CalendarGuard.isOn = ok
                                if !ok { skipBusy = false; calendarDenied = true }
                            }
                        }
                } footer: {
                    Text(calendarDenied
                         ? "Calendar access is off. Turn it on in Settings › Doorlist › Calendars."
                         : "Reads your calendar on this phone to flag clashes. It's never sent anywhere.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .tint(.accentColor)
            .navigationTitle("Search settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let typed = city
                        Task {
                            if !typed.trimmingCharacters(in: .whitespaces).isEmpty { await location.setManual(typed) }
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { if location.place?.isManual == true { city = location.place?.city ?? "" } }
        }
    }
}

// MARK: - Helpers

/// Wraps children onto new lines like text, for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = fittedSize(view, width: width)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = fittedSize(view, width: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }

    /// A child's natural size, or its size wrapped to the row when it's wider than that.
    private func fittedSize(_ view: LayoutSubview, width: CGFloat) -> CGSize {
        let size = view.sizeThatFits(.unspecified)
        guard size.width > width, width.isFinite else { return size }
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
