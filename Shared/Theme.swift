import SwiftUI

/// Spacing, shapes and motion used everywhere, so every screen moves and
/// sits the same way.
enum Theme {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let buttonHeight: CGFloat = 54

    /// Critically damped: settles without overshoot. Used for screen changes.
    static let spring = Animation.spring(response: 0.38, dampingFraction: 1)
    /// For the success moment only.
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.72)
}

// MARK: - Buttons

/// The one filled button per screen. Full width, thumb height, reacts on press.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(
                isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Quieter companion to the primary button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Rows and tiles that should feel touchable without looking like buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Surfaces

extension View {
    /// A raised group on the grouped background.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// The pinned bottom area holding a screen's main action.
    func bottomActionBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { content() }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.bar)
        }
    }
}

/// Small rounded label for booking states.
struct StatusPill: View {
    let status: BookingStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(status.title)")
    }
}

extension BookingStatus {
    var symbol: String {
        switch self {
        case .approved, .invited: "checkmark.circle.fill"
        case .pendingApproval: "clock.fill"
        case .waitlist: "list.number"
        case .declined: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .approved, .invited: .green
        case .pendingApproval: .orange
        case .waitlist: .blue
        case .declined: .red
        }
    }
}

/// Grey blocks shown while the event loads, in the shape of what's coming.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}
