import SwiftUI

/// A month of your bookings, Partiful style: today is picked when it opens,
/// days with events carry a dot, and tapping a day lists what's on.
struct EventCalendar: View {
    let records: [BookingRecord]
    @Binding var selected: Date
    @State private var month: Date = Calendar.current.startOfMonth(for: Date())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let calendar = Calendar.current

    /// Events per day, keyed by the start of that day.
    private var byDay: [Date: [BookingRecord]] {
        Dictionary(grouping: records.filter { $0.startAt != nil && $0.status != .declined }) {
            calendar.startOfDay(for: $0.startAt!)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded with nils so the 1st lands on its weekday.
    private var cells: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<31
        let firstWeekday = calendar.component(.weekday, from: month)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + days
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 46) }
                }
            }
            .id(month)
            .transition(.opacity)
        }
        .card(padding: 14)
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40 { step(1) } else if value.translation.width > 40 { step(-1) }
        })
        .onAppear { month = calendar.startOfMonth(for: selected) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            if !calendar.isDateInToday(selected) || !calendar.isDate(month, equalTo: Date(), toGranularity: .month) {
                Button("Today") {
                    selected = calendar.startOfDay(for: Date())
                    withAnimation(animation) { month = calendar.startOfMonth(for: Date()) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .padding(.trailing, 4)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous month")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("Next month")
        }
        .font(.body.weight(.semibold))
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let count = byDay[calendar.startOfDay(for: day)]?.count ?? 0
        let isPast = day < calendar.startOfDay(for: Date())
        return Button {
            selected = day
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : isPast ? Color.secondary : Color.primary)
                    .frame(width: 34, height: 34)
                    .background { if isSelected { Circle().fill(Color.accentColor) } }
                HStack(spacing: 3) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle().fill(isPast ? Color.secondary : Color.accentColor).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day())
                            + (count == 0 ? "" : count == 1 ? ", 1 event" : ", \(count) events"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(animation) { month = next }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}
