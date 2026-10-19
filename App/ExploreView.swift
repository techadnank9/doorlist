import SwiftUI

// MARK: - Data

/// One event card's worth, as `/v1/explore` sends it.
struct ExploreEvent: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let startsAt: String
    let endsAt: String?
    let allDay: Bool
    let timezone: String?
    let city: String?
    let online: Bool
    let url: String
    let sources: [String]
    let image: String?
    let isFree: Bool?
    let soldOut: Bool?
    let guests: Int?
    let topics: [String]

    var start: Date? { ExploreEvent.date(startsAt) }
    var end: Date? { endsAt.flatMap(ExploreEvent.date) }

    private static func date(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

struct ExploreChoice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    var featured: Bool? = nil
}

private struct ExploreMeta: Decodable {
    let places: [ExploreChoice]
    let topics: [ExploreChoice]
    let sources: [ExploreChoice]
}

private struct ExplorePage: Decodable {
    let events: [ExploreEvent]
    let next: String?
}

/// What Explore is showing and how it got there. Choices are remembered between launches.
@MainActor
final class ExploreModel: ObservableObject {
    static let nearMe = "near-me"

    @Published private(set) var places: [ExploreChoice] = []
    @Published private(set) var topics: [ExploreChoice] = []
    @Published private(set) var sources: [ExploreChoice] = []
    @Published private(set) var events: [ExploreEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var place: String { didSet { remember("explorePlace", place); reload() } }
    @Published var topic: String? { didSet { remember("exploreTopic", topic); reload() } }
    @Published var source: String? { didSet { remember("exploreSource", source); reload() } }

    private var next: String?
    private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        place = defaults.string(forKey: "explorePlace") ?? "sf"
        topic = defaults.string(forKey: "exploreTopic")
        source = defaults.string(forKey: "exploreSource")
    }

    var placeName: String {
        place == Self.nearMe ? "Near me" : places.first { $0.id == place }?.name ?? "San Francisco"
    }

    func start() async {
        if places.isEmpty, let meta: ExploreMeta = try? await get("v1/explore/meta") {
            places = meta.places
            topics = meta.topics
            sources = meta.sources
        }
        if events.isEmpty { reload() }
    }

    func reload() {
        task?.cancel()
        task = Task { await load(reset: true) }
    }

    func refresh() async { await load(reset: true) }

    /// The next page, when the last card on screen appears.
    func more(after event: ExploreEvent) {
        guard event.id == events.last?.id, next != nil, !loading else { return }
        task = Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        var items: [URLQueryItem] = []
        if place == Self.nearMe, let here = await LocationProvider.shared.current(), here.latitude != 0 {
            items += [URLQueryItem(name: "lat", value: String(here.latitude)), URLQueryItem(name: "lng", value: String(here.longitude))]
        } else {
            items.append(URLQueryItem(name: "place", value: place == Self.nearMe ? "sf" : place))
        }
        if let topic { items.append(URLQueryItem(name: "topic", value: topic)) }
        if let source { items.append(URLQueryItem(name: "source", value: source)) }
        if !reset, let next { items.append(URLQueryItem(name: "cursor", value: next)) }
        do {
            let page: ExplorePage = try await get("v1/explore", items)
            guard !Task.isCancelled else { return }
            events = reset ? page.events : events + page.events
            next = page.next
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? VoiceError)?.errorDescription ?? "Can't reach Doorlist right now. Check your connection."
        }
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        var req = DoorlistAPI.request(path, method: "GET", timeout: 20)
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        if !items.isEmpty { components.queryItems = items }
        req.url = components.url
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceError.message(DoorlistAPI.message(from: data, status: status)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func remember(_ key: String, _ value: String?) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - Screen

/// Events near a place, by topic and source, from every site Doorlist reads. Tapping one books it.
struct ExploreView: View {
    @Binding var booking: BookingRequest?
    @StateObject private var model = ExploreModel()
    @State private var choosingPlace = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        content
                    } header: {
                        filters
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refresh() }
            .navigationTitle("Explore")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { choosingPlace = true } label: {
                        Label(model.placeName, systemImage: model.place == ExploreModel.nearMe ? "location.fill" : "mappin.and.ellipse")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityHint("Changes where Explore looks")
                }
            }
            .sheet(isPresented: $choosingPlace) {
                PlacePicker(places: model.places, selected: model.place) { model.place = $0 }
            }
            .task { await model.start() }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChipRow(choices: model.topics, all: "All", selected: $model.topic)
            ChipRow(choices: model.sources, all: "All sources", selected: $model.source, small: true)
        }
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder private var content: some View {
        if model.events.isEmpty {
            if model.loading {
                ForEach(0..<6, id: \.self) { _ in PlaceholderCard() }
            } else {
                ContentUnavailableView {
                    Label(model.error == nil ? "Nothing here yet" : "Couldn't load events",
                          systemImage: model.error == nil ? "calendar.badge.exclamationmark" : "wifi.exclamationmark")
                } description: {
                    Text(model.error ?? "No upcoming events match. Try another topic, or a wider place like the Bay Area.")
                } actions: {
                    if model.topic != nil || model.source != nil {
                        Button("Show everything") { model.topic = nil; model.source = nil }
                    }
                }
                .padding(.top, 40)
            }
        } else {
            ForEach(model.events) { event in
                Button { booking = BookingRequest(input: event.url) } label: { ExploreCard(event: event) }
                    .buttonStyle(.pressable)
                    .onAppear { model.more(after: event) }
            }
            if model.loading { ProgressView().frame(maxWidth: .infinity).padding() }
        }
    }
}

// MARK: - Pieces

/// A sideways row of filter chips. Tapping the selected chip again clears it.
private struct ChipRow: View {
    let choices: [ExploreChoice]
    let all: String
    @Binding var selected: String?
    var small = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(all, on: selected == nil) { selected = nil }
                ForEach(choices) { choice in
                    chip(choice.name, on: selected == choice.id) { selected = selected == choice.id ? nil : choice.id }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(small ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .padding(.horizontal, small ? 10 : 14)
                .frame(minHeight: small ? 30 : 36)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct ExploreCard: View {
    let event: ExploreEvent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(when).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(event.title).font(.headline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                if let place = event.online ? "Online" : event.city {
                    Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if event.soldOut == true { tag("Full", .orange) } else if event.isFree == true { tag("Free", .green) }
                    if event.topics.contains("hackathons") { tag("Hackathon", .purple) }
                    Text(sourceNames).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        AsyncImage(url: event.image.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay(Image(systemName: event.topics.contains("hackathons") ? "hammer.fill" : "ticket.fill").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tint).background(tint.opacity(0.14), in: Capsule())
    }

    private var sourceNames: String {
        let names = ["luma": "Luma", "cerebralvalley": "Cerebral Valley", "yc": "Y Combinator", "devpost": "Devpost",
                     "mlh": "MLH", "lablab": "lablab.ai", "devfolio": "Devfolio", "partiful": "Partiful",
                     "eventbrite": "Eventbrite", "meetup": "Meetup", "allevents": "AllEvents", "funcheap": "Funcheap"]
        return event.sources.map { names[$0] ?? $0 }.joined(separator: " · ")
    }

    private var when: String {
        guard let start = event.start else { return "" }
        if start < Date(), let end = event.end, end > Date() { return "Happening now" }
        var style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        if let zone = event.timezone.flatMap(TimeZone.init(identifier:)) { style.timeZone = zone }
        let day = start.formatted(style)
        if event.allDay { return day }
        var time = Date.FormatStyle().hour().minute()
        if let zone = event.timezone.flatMap(TimeZone.init(identifier:)) { time.timeZone = zone }
        return "\(day) · \(start.formatted(time))"
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)).frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: 90, height: 10)
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: 190, height: 14)
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: 120, height: 11)
            }
            Spacer()
        }
        .card(padding: 12)
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 10)
        .shimmer()
        .accessibilityHidden(true)
    }
}

/// Featured places first (San Francisco, Bay Area, Las Vegas...), Near me, then every other city, searchable.
private struct PlacePicker: View {
    let places: [ExploreChoice]
    let selected: String
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var location = LocationProvider.shared
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section {
                        row(ExploreModel.nearMe, "Near me", symbol: "location.fill")
                        ForEach(places.filter { $0.featured == true }) { row($0.id, $0.name) }
                    }
                }
                Section(search.isEmpty ? "All cities" : "") {
                    ForEach(places.filter { $0.featured != true && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) {
                        row($0.id, $0.name)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search cities")
            .navigationTitle("Where")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ id: String, _ name: String, symbol: String? = nil) -> some View {
        Button {
            if id == ExploreModel.nearMe && !location.isAllowed { location.requestPermission() }
            onPick(id)
            dismiss()
        } label: {
            HStack {
                if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
                Text(name).foregroundStyle(.primary)
                Spacer()
                if id == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
}
