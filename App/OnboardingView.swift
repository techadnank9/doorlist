import SwiftUI
import AuthenticationServices

/// First launch, one decision per screen: what Doorlist does, sign in with
/// Apple, your details (Apple never shares a phone number, and may hide your
/// email), where to search, then Luma. Signing in is required; everything after it can be skipped.
/// `returning` is someone who finished onboarding before but is signed out now: they only sign in.
struct OnboardingView: View {
    var returning = false
    var onFinish: () -> Void
    @EnvironmentObject private var state: AppState
    @ObservedObject private var location = LocationProvider.shared
    @State private var page: Page = .welcome
    @State private var showConnect = false
    @State private var signInError: String?
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    /// Apple gave a relay address; tickets sent there may never arrive.
    @State private var relayEmail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56
    @FocusState private var focus: DetailField?

    enum Page: Int, CaseIterable { case welcome, details, location, luma }
    enum DetailField { case name, email, phone }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            Group {
                switch page {
                case .welcome: welcome
                case .details: details
                case .location: locationPage
                case .luma: lumaPage
                }
            }
            .transition(slide)
        }
        // Finish once the sheet has gone, not while it's still closing.
        .sheet(isPresented: $showConnect, onDismiss: { if state.connected { finish() } }) {
            ConnectLumaView { state.refresh() }
        }
        .onAppear(perform: loadSaved)
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                             removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func go(_ next: Page) {
        focus = nil
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.spring) { page = next }
    }

    private func finish() {
        Task { await Notifier.requestPermission() }
        onFinish()
    }

    /// "Step 2 of 4" in the corner, so the end is always in sight.
    private func stepLabel(_ p: Page) -> some View {
        Text("Step \(p.rawValue + 1) of \(Page.allCases.count)")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)
    }

    // MARK: 1. Welcome + sign in

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            AppMark().padding(.bottom, 28)
            Text("Say where you want\nto go. Doorlist\ngets you in.")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            Text("Share an event link, or just describe one. Doorlist finds it, fills the form with answers you've given before, and books it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)

            WelcomeExample()
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .bottomActionBar {
            AppleSignInButton { outcome in
                signInError = outcome.error
                guard outcome.error == nil else { return }
                loadSaved()
                if let n = outcome.name, name.isEmpty { name = n }
                if let e = outcome.email, email.isEmpty { email = e }
                relayEmail = outcome.relayEmail && email.isEmpty
                state.refresh()
                if returning { onFinish(); return }
                // An account that already has details on another phone can skip straight on.
                go(AnswerStore.shared.get("phone") != nil && !email.isEmpty ? .location : .details)
            }
            if let signInError {
                Text(signInError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 2. Details

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stepLabel(.details)
                Text("Your details")
                    .font(.largeTitle.weight(.bold))
                    .padding(.bottom, 10)
                Text("Every event asks for these. Give them once and Doorlist fills them in from now on.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                VStack(spacing: 12) {
                    DetailRow(title: "Full name", text: $name, content: .name, keyboard: .default, focus: $focus, field: .name)
                    DetailRow(title: "Email", text: $email, content: .emailAddress, keyboard: .emailAddress, focus: $focus, field: .email)
                    if relayEmail {
                        Label("Apple hid your email. Events send tickets by email, so use one you check.", systemImage: "envelope.badge")
                            .font(.footnote).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DetailRow(title: "Phone", text: $phone, content: .telephoneNumber, keyboard: .phonePad, focus: $focus, field: .phone)
                    Text("Apple doesn't share phone numbers, so this one's from you. Hosts use it for day-of texts.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .bottomActionBar {
            Button("Continue") {
                saveDetails()
                go(.location)
            }
            .buttonStyle(.primary)
            Button("Skip for now") { go(.location) }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
    }

    private func loadSaved() {
        let saved = AnswerStore.shared.all()
        name = saved["name"]?.value ?? [saved["first_name"]?.value, saved["last_name"]?.value].compactMap { $0 }.joined(separator: " ")
        email = saved["email"]?.value ?? ""
        phone = saved["phone"]?.value ?? ""
    }

    private func saveDetails() {
        let store = AnswerStore.shared
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty {
            store.set("name", label: "Full name", value: n)
            let split = BookingPlanner.splitName(n)
            store.set("first_name", label: "First name", value: split.first)
            if !split.last.isEmpty { store.set("last_name", label: "Last name", value: split.last) }
        }
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.contains("@") { store.set("email", label: "Email", value: e) }
        let p = BookingPlanner.normalizePhone(phone)
        if p.count > 6 { store.set("phone", label: "Phone number", value: p) }
        state.refresh()
    }

    // MARK: 3. Location

    private var locationPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            stepLabel(.location)
            Image(systemName: "location.circle.fill")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            Text("Find events near you")
                .font(.largeTitle.weight(.bold))
                .padding(.bottom, 10)
            Text("When you ask for \u{201C}something fun tonight,\u{201D} Doorlist needs to know where tonight is. Only your town is used, never your exact spot.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .bottomActionBar {
            Button(location.isAllowed ? "Continue" : "Allow location") {
                if location.isAllowed { go(.luma) } else { location.requestPermission() }
            }
            .buttonStyle(.primary)
            Button("Not now") { go(.luma) }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .onChange(of: location.status) { _, status in
            if status != .notDetermined, page == .location {
                Task { _ = await location.current() }
                go(.luma)
            }
        }
    }

    // MARK: 4. Luma

    private var lumaPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            stepLabel(.luma)
            Text("Connect Luma")
                .font(.largeTitle.weight(.bold))
                .padding(.bottom, 10)
            Text("Most tech events live on Luma. Sign in once on Luma's own page and Doorlist books there in one tap. Partiful and Eventbrite sign in the first time you book on them.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)
            VStack(alignment: .leading, spacing: 20) {
                Step(number: 1, text: "Open any event link")
                Step(number: 2, text: "Tap Share, then Doorlist")
                Step(number: 3, text: "Or describe it in Find")
            }
            .card(padding: 20)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .bottomActionBar {
            Button("Connect Luma") { showConnect = true }.buttonStyle(.primary)
            Button("Do it later") { finish() }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
    }
}

/// One labelled field with a mic, for the details step.
private struct DetailRow: View {
    let title: String
    @Binding var text: String
    let content: UITextContentType
    let keyboard: UIKeyboardType
    var focus: FocusState<OnboardingView.DetailField?>.Binding
    let field: OnboardingView.DetailField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField(title, text: $text)
                    .textContentType(content)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(field == .name ? .words : .never)
                    .autocorrectionDisabled(field != .name)
                    .focused(focus, equals: field)
                    .padding(.vertical, 14)
                if field == .name {
                    MicButton(context: "name") { text = $0 }
                }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .background(Color.surface,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
    }
}

/// The velvet rope mark (design/logo/velvet-rope-mark.svg), kept as vector art.
struct AppMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.body.weight(.medium))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

/// What Doorlist does, shown as one request and its result rather than a feature list.
private struct WelcomeExample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                Text("\u{201C}A free AI meetup Thursday\u{201D}")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(14)
            Divider().padding(.leading, 14)
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text("THU").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                    Text("23").font(.title3.weight(.semibold))
                }
                .frame(width: 44, height: 44)
                .background(Color.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Builders Night").font(.subheadline.weight(.semibold))
                    Text("4 questions answered").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("You're in")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            .padding(14)
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: you ask for a free AI meetup Thursday, and Doorlist books AI Builders Night and answers its questions for you.")
    }
}
