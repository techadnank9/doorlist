import SwiftUI

/// The Events tab: book a link, then see what you're going to.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showConnect: Bool
    @Binding var booking: BookingRequest?
    @State private var link = ""
    @FocusState private var focused: Bool
    @AppStorage("hideShareTip") private var hideShareTip = false
    @State private var opened: BookingRecord?
    @State private var filter = ""
    @State private var day = Calendar.current.startOfDay(for: Date())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 40

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var linkIsValid: Bool { EventLink.find(in: trimmedLink, allowAnySite: true) != nil }
    private var showInvalid: Bool { !trimmedLink.isEmpty && !linkIsValid }

    /// History narrowed by the search field: event name, place, site or an answer sent.
    private func matchingHistory() -> [BookingRecord] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return state.history }
        return state.history.filter { r in
            ([r.eventName, r.place ?? "", r.site.name] + (r.answers ?? []).map(\.answer))
                .contains { $0.localizedStandardContains(q) }
        }
    }

    private static func upcoming(in records: [BookingRecord]) -> [BookingRecord] {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        return records.filter { ($0.startAt ?? .distantFuture) >= cutoff }
            .sorted { ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture) }
    }

    private static func past(in records: [BookingRecord]) -> [BookingRecord] {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        return records.filter { ($0.startAt ?? .distantFuture) < cutoff }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Worked out once per pass rather than on every read.
                    let matching = matchingHistory()
                    let upcoming = Self.upcoming(in: matching)
                    let past = Self.past(in: matching)
                    bookCard
                    if state.clipboardHasLink && trimmedLink.isEmpty { clipboardCard }
                    if state.history.isEmpty {
                        if !state.connected { connectCard }
                        if !hideShareTip { shareTip }
                        emptyState
                    } else if matching.isEmpty {
                        Text("No booked events match \u{201C}\(filter)\u{201D}.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if !filter.isEmpty {
                        if !upcoming.isEmpty { section("Coming up", upcoming) }
                        if !past.isEmpty { section("Past", past) }
                    } else {
                        EventCalendar(records: state.history, selected: $day)
                        daySection
                        if !state.connected { connectCard }
                        let later = upcoming.filter { !($0.startAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false) }
                        if !later.isEmpty { section("Coming up", later) }
                        if !past.isEmpty { section("Past", past) }
                        if !hideShareTip { shareTip }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 32)
                .animation(Theme.spring, value: state.clipboardHasLink)
                .animation(Theme.spring, value: hideShareTip)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.canvas)
            .navigationTitle("Doorlist")
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search your events")
            .sheet(item: $opened) { EventDetailView(record: $0) }
        }
    }

    // MARK: Cards

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect your Luma account", systemImage: "link.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Doorlist books with your own account. You sign in on Luma's page and the login stays on this phone.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect Luma") { showConnect = true }
                .buttonStyle(.primary)
        }
        .card(padding: 18)
    }

    /// One field: paste a link and the arrow books it. No card, so the calendar leads.
    private var bookCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Paste an event link", text: $link)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(book)
                if !link.isEmpty && !linkIsValid {
                    Button { link = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear link")
                }
                if linkIsValid {
                    Button(action: book) {
                        Image(systemName: "arrow.right")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Book it")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(minHeight: 52)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
            }

            if showInvalid {
                Label("That isn't an event link. Try one like luma.com/abc123 or partiful.com/e/abc123.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: linkIsValid)
        .animation(.easeOut(duration: 0.15), value: showInvalid)
    }

    private var clipboardCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Copied a link?").font(.subheadline.weight(.semibold))
                Text("Paste it to book in one tap").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    link = text
                    book()
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(.accentColor)
        }
        .card(padding: 14)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private var shareTip: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Faster from anywhere").font(.subheadline.weight(.semibold))
                Text("On any Luma, Partiful or Eventbrite link in Safari, Messages or WhatsApp, tap Share and pick Doorlist.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { hideShareTip = true } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Hide tip")
        }
        .card(padding: 14)
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ticket")
                .font(.system(size: emptyIconSize, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No events yet").font(.headline)
            Text("Events you book show up here, soonest first.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    /// What's on the picked day, right under the calendar.
    @ViewBuilder private var daySection: some View {
        let onDay = state.history
            .filter { $0.startAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture) }
        let title = Calendar.current.isDateInToday(day) ? "Today"
            : day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if onDay.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "calendar").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("Nothing booked \(Calendar.current.isDateInToday(day) ? "today" : "on \(title)")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        } else {
            section(title, onDay)
        }
    }

    private func section(_ title: String, _ records: [BookingRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    EventRow(record: record) { opened = record }
                    if index < records.count - 1 { Divider().padding(.leading, 76) }
                }
            }
            .background(Color.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    private func book() {
        guard linkIsValid else { return }
        focused = false
        booking = BookingRequest(input: trimmedLink)
        link = ""
    }
}

/// An event in the list: a calendar-style date tile, the name, and its status.
private struct EventRow: View {
    let record: BookingRecord
    let onTap: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                DateTile(date: record.startAt)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.eventName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let date = record.startAt {
                            Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        }
                        if let place = record.place { Text("·"); Text(place).lineLimit(1) }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        StatusPill(status: record.status)
                        if record.site != .luma {
                            Text(record.site == .web ? (URL(string: record.url)?.host ?? "Web") : record.site.name)
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .contextMenu {
            if let url = URL(string: record.url) {
                Button { openURL(url) } label: { Label(record.site.openTitle, systemImage: "arrow.up.right") }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "doc.on.doc") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the questions and what was sent")
    }
}

private struct DateTile: View {
    let date: Date?

    var body: some View {
        VStack(spacing: 0) {
            Text(date.map { $0.formatted(.dateTime.month(.abbreviated)) }?.uppercased() ?? "TBA")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(date.map { $0.formatted(.dateTime.day()) } ?? "–")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 48, height: 52)
        .background(Color.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One booked event: when and where, its status, and every question with the answer sent.
private struct EventDetailView: View {
    let record: BookingRecord
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        AsyncImage(url: record.coverUrl.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.fill
                        }
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                        Text(record.eventName).font(.title3.weight(.bold))
                        if let date = record.startAt {
                            Label(date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()),
                                  systemImage: "calendar")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let place = record.place {
                            Label(place, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary)
                        }
                        StatusPill(status: record.status)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    if let answers = record.answers, !answers.isEmpty {
                        ForEach(Array(answers.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.question).font(.footnote).foregroundStyle(.secondary)
                                Text(item.answer)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text("Not recorded for this booking.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Questions and what was sent")
                } footer: {
                    Text("To change an answer for future events, edit it in the Answers tab.")
                }

                if let url = URL(string: record.url) {
                    Section {
                        Button { openURL(url) } label: { Label(record.site.openTitle, systemImage: "arrow.up.right") }
                        ShareLink(item: url) { Label("Share event", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
