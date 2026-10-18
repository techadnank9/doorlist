import AuthenticationServices
import SwiftUI

/// Sign in with Apple, shared by onboarding and the Answers tab. Turns Apple's
/// credential into a Doorlist session, saves the name Apple shares (only on the
/// first sign in), and pulls down whatever the account already has.
enum AppleAccount {
    struct Outcome {
        var name: String?
        /// A real email Apple shared; nil when it was hidden behind a relay.
        var email: String?
        var relayEmail = false
        var error: String?
    }

    static func complete(_ result: Result<ASAuthorization, Error>) async -> Outcome {
        var outcome = Outcome()
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                outcome.error = "Apple sign in didn't finish. You can carry on without it."
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                outcome.error = "Apple didn't send a sign in token. Try again."
                return outcome
            }
            do {
                let serverEmail = try await DoorlistAPI.signIn(identityToken: token)
                // Bring this account's answers and bookings onto this phone first,
                // so nothing typed below overwrites them with blanks.
                await ProfileSync.now()
                if let given = credential.fullName {
                    let full = PersonNameComponentsFormatter().string(from: given)
                    if !full.isEmpty {
                        outcome.name = full
                        AnswerStore.shared.seed("name", label: "Full name", value: full)
                    }
                    AnswerStore.shared.seed("first_name", label: "First name", value: given.givenName)
                    AnswerStore.shared.seed("last_name", label: "Last name", value: given.familyName)
                }
                if let email = credential.email ?? serverEmail {
                    if email.hasSuffix("privaterelay.appleid.com") {
                        outcome.relayEmail = true
                    } else {
                        outcome.email = email
                        AnswerStore.shared.seed("email", label: "Email", value: email)
                    }
                }
            } catch {
                outcome.error = error.localizedDescription
            }
        }
        return outcome
    }
}

/// Apple's own button, sized and themed the same everywhere.
struct AppleSignInButton: View {
    var label: SignInWithAppleButton.Label = .continue
    let onDone: (AppleAccount.Outcome) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var working = false

    var body: some View {
        SignInWithAppleButton(label) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            working = true
            Task {
                let outcome = await AppleAccount.complete(result)
                working = false
                onDone(outcome)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay { if working { ProgressView().tint(colorScheme == .dark ? .black : .white) } }
        .disabled(working)
    }
}
