import SwiftUI
import CairnCore

/// Email + password form for acquiring an Immich session token. Lives
/// under Settings → Advanced → "Session sign-in for incremental sync."
/// Immich's `/sync/*` endpoints reject API-key auth, so until cairn
/// presents a session-derived Bearer token, the streaming coordinator
/// stays unreachable. This sheet is the user's path to enable it.
///
/// The form is intentionally minimal: email, password, "Sign in".
/// Failure renders inline; success dismisses the sheet and flips
/// `model.hasSessionToken` so the Settings row re-renders as
/// "Signed in."
public struct SessionSignInSheet: View {
    public let signIn: @Sendable (_ email: String, _ password: String) async -> CairnAppActions.SessionSignInResult
    /// Recently-used sign-in addresses, most-recent-first. Powers the
    /// email-field autocomplete. Loaded once on appear.
    public let loadRecentEmails: @Sendable () async -> [String]
    public let onDismiss: () -> Void

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting: Bool = false
    @State private var inlineError: String?
    @State private var recentEmails: [String] = []

    @Environment(\.cairnTokens) private var t
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    public init(
        signIn: @escaping @Sendable (String, String) async -> CairnAppActions.SessionSignInResult,
        loadRecentEmails: @escaping @Sendable () async -> [String] = { [] },
        onDismiss: @escaping () -> Void
    ) {
        self.signIn = signIn
        self.loadRecentEmails = loadRecentEmails
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                explainer
                VStack(alignment: .leading, spacing: 6) {
                    emailField
                    emailSuggestions
                }
                passwordField
                signInButton
                if let inlineError {
                    Text(inlineError)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.dangerInk)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isStaticText)
                }
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(t.bg)
        .scrollDismissesKeyboard(.interactively)
        .task { recentEmails = await loadRecentEmails() }
    }

    private var header: some View {
        HStack {
            Text("Sign in for incremental sync".loc)
                .font(.cairnScaled(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.cairnScaled(size: 14, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close".loc)
        }
    }

    private var explainer: some View {
        Text("Incremental sync talks to an Immich endpoint that doesn't accept API keys. Signing in with your Immich email and password gives cairn a session token, stored locally in your iPhone's Keychain. Cairn uses it only for that one streaming path — every other request still uses your API key. Sign out anytime to drop the token; everything else keeps working.".loc)
            .font(.cairnScaled(size: 13))
            .foregroundStyle(t.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email".loc)
                .font(.cairnScaled(size: 13, weight: .medium))
                .foregroundStyle(t.textBody)
            TextField("you@example.com", text: $email)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                #endif
                .focused($focusedField, equals: .email)
                .onSubmit { focusedField = .password }
                .padding(10)
                .background(t.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .accessibilityLabel("Email".loc)
        }
    }

    /// Up to four recently-used addresses, filtered by the current input.
    /// Empty input shows the full recent list; typing narrows to
    /// substring matches and drops an exact match (nothing to suggest).
    private var filteredEmailSuggestions: [String] {
        let q = email.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty
            ? recentEmails
            : recentEmails.filter { $0.lowercased().contains(q) && $0.lowercased() != q }
        return Array(matches.prefix(4))
    }

    /// Recent-email dropdown, shown only while the email field is focused
    /// (so it doesn't linger over the password field). Mirrors the
    /// recent-servers autocomplete on the onboarding URL field.
    @ViewBuilder
    private var emailSuggestions: some View {
        if focusedField == .email, !filteredEmailSuggestions.isEmpty {
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(filteredEmailSuggestions.enumerated()), id: \.element) { idx, addr in
                        Button(action: { applyEmailSuggestion(addr) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.cairnScaled(size: 12))
                                    .foregroundStyle(t.textHint)
                                Text(addr)
                                    .font(.cairnScaled(size: 13))
                                    .foregroundStyle(t.textBody)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.cairnScaled(size: 11))
                                    .foregroundStyle(t.textHint)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < filteredEmailSuggestions.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
        }
    }

    private func applyEmailSuggestion(_ addr: String) {
        email = addr
        focusedField = .password
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password".loc)
                .font(.cairnScaled(size: 13, weight: .medium))
                .foregroundStyle(t.textBody)
            SecureField("", text: $password)
                #if os(iOS)
                .textContentType(.password)
                .submitLabel(.go)
                #endif
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await submit() } }
                .padding(10)
                .background(t.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .accessibilityLabel("Password".loc)
        }
    }

    private var signInButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.primaryInk)
                }
                Text(isSubmitting ? "Signing in…".loc : "Sign in".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.primaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(canSubmit ? t.primary : t.primary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel(isSubmitting ? "Signing in".loc : "Sign in".loc)
        .accessibilityHint("Calls /api/auth/login on your Immich server")
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    @MainActor
    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        inlineError = nil
        let result = await signIn(
            email.trimmingCharacters(in: .whitespaces),
            password
        )
        isSubmitting = false
        switch result {
        case .success:
            // Sheet host listens for hasSessionToken changes and
            // dismisses; we close locally too for snappier UX in case
            // the host's reconciliation runs a hair later.
            onDismiss()
        case .invalidCredentials:
            inlineError = "Invalid email or password. Check your Immich credentials and try again.".loc
        case .serverError(let code, let body):
            inlineError = "Immich returned HTTP \(code): \(body)"
        case .networkError(let message):
            inlineError = message
        }
    }
}

#if DEBUG
#Preview("Session sign-in — light") {
    SessionSignInSheet(
        signIn: { _, _ in .success },
        onDismiss: {}
    )
    .cairnTheme()
}

#Preview("Session sign-in — invalid credentials") {
    SessionSignInSheet(
        signIn: { _, _ in .invalidCredentials },
        onDismiss: {}
    )
    .cairnTheme()
}
#endif
