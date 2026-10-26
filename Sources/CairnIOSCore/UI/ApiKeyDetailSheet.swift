import SwiftUI
import CairnCore

/// Focused management surface for the Immich API key, opened from the
/// Connection page's "API key" row. Consolidates everything key-related
/// in one place:
///   - View the key (reveal / copy / auto-hide, via `ApiKeyRow`).
///   - Replace the key in place — paste a new key for the *same* Immich
///     account and swap it without re-onboarding, preserving the index,
///     journal, and run history.
///   - Disconnect the server entirely (forget URL + key → onboarding).
///
/// "Replace" and "Disconnect" are deliberately distinct: replace rotates
/// a credential for the account you're already indexed against; disconnect
/// is the heavier "I'm switching servers/accounts" action.
public struct ApiKeyDetailSheet: View {
    public let rawKey: String
    public let masked: String
    public let replaceKey: @Sendable (String) async -> CairnAppActions.ReplaceKeyResult
    /// Full sign-out (forget URL + key). The sheet gates this behind its
    /// own confirmation, so the caller can pass the bare action.
    public let onDisconnect: () -> Void
    public let onDismiss: () -> Void

    @State private var newKey: String = ""
    @State private var isReplacing: Bool = false
    @State private var replaceError: String?
    @State private var replaceSucceeded: Bool = false
    @State private var pendingDisconnect: Bool = false

    @Environment(\.cairnTokens) private var t

    public init(
        rawKey: String,
        masked: String,
        replaceKey: @escaping @Sendable (String) async -> CairnAppActions.ReplaceKeyResult,
        onDisconnect: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.rawKey = rawKey
        self.masked = masked
        self.replaceKey = replaceKey
        self.onDisconnect = onDisconnect
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                CairnCard {
                    ApiKeyRow(rawKey: rawKey, masked: masked)
                }
                replaceSection
                disconnectSection
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(t.bg)
        .scrollDismissesKeyboard(.interactively)
        .alert("Disconnect server?".loc, isPresented: $pendingDisconnect) {
            Button("Cancel".loc, role: .cancel) {}
            Button("Disconnect".loc, role: .destructive) { onDisconnect() }
        } message: {
            Text("Forgets your Immich URL and API key, and drops the cached thumbnails fetched with them. You'll land back on the onboarding flow — indexed state on this device is preserved for when you sign in again.".loc)
        }
    }

    private var header: some View {
        HStack {
            Text("API key".loc)
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

    private var replaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace key".loc)
                .font(.cairnScaled(size: 13, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(t.textBody)
            if CairnL10n.isChinese {
                (Text("为同一 Immich 账户粘贴新的 API 密钥。") + .cairnWord + Text(" 将进行验证并替换 — 你的已索引状态、日志和运行历史都将保留。适用于在无需重新配置的情况下轮换密钥。"))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                (Text("Paste a new API key for the same Immich account. ") + .cairnWord + Text(" verifies it and swaps it in — your indexed state, journal, and run history are kept. Use this to rotate a key without re-onboarding."))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ApiKeyInput(text: $newKey, placeholder: "paste new API key".loc)
                .onChange(of: newKey) { _, _ in
                    // A fresh edit invalidates the prior result.
                    replaceError = nil
                    replaceSucceeded = false
                }
            replaceButton
            if let replaceError {
                Text(replaceError.loc)
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
            if replaceSucceeded {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                    Text("Key replaced. Your index and history are unchanged.".loc)
                }
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.verifiedInk)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var replaceButton: some View {
        Button {
            Task { await doReplace() }
        } label: {
            HStack(spacing: 8) {
                if isReplacing {
                    ProgressView().controlSize(.small).tint(t.primaryInk)
                }
                Text(isReplacing ? "Verifying…".loc : "Verify & replace".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.primaryInk)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(canReplace ? t.primary : t.primary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canReplace || isReplacing)
        .accessibilityLabel("Verify and replace API key".loc)
    }

    private var disconnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { pendingDisconnect = true }) {
                Text("Disconnect server".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.dangerInk)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(t.dangerInk.opacity(0.4), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Disconnect server".loc)
            Text("Forgets your Immich URL and API key and returns to onboarding. Use this to switch to a different server or account.".loc)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var canReplace: Bool {
        !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func doReplace() async {
        guard canReplace, !isReplacing else { return }
        isReplacing = true
        replaceError = nil
        replaceSucceeded = false
        let result = await replaceKey(newKey.trimmingCharacters(in: .whitespacesAndNewlines))
        isReplacing = false
        switch result {
        case .success:
            replaceSucceeded = true
            newKey = ""
        case .invalidKey:
            replaceError = "That key was rejected by your Immich server. Check you copied it correctly and that it has the required scopes."
        case .wrongAccount(let email):
            replaceError = "That key belongs to a different Immich account (\(email)). To switch accounts, use Disconnect server below."
        case .cannotConfirmAccount:
            replaceError = "Couldn't confirm this key is for the same Immich account. To switch servers or accounts, use Disconnect server below."
        case .networkError(let message):
            replaceError = message
        }
    }
}

#if DEBUG
#Preview("API key sheet") {
    ApiKeyDetailSheet(
        rawKey: "cair_a1b2c3d4e5f6g7h8i9j0",
        masked: "cair_••••••••••j0",
        replaceKey: { _ in .success },
        onDisconnect: {},
        onDismiss: {}
    )
    .cairnTheme()
}
#endif
