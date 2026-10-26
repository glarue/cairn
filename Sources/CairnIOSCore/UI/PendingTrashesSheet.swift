import SwiftUI
import CairnCore

/// Detail view for the persistent trash retry queue. Surfaces every
/// `PendingTrashIntent` with its asset count, attempt count, and the
/// most recent error so the user can decide whether to retry, give
/// up (drop the intent), or fix the underlying cause.
///
/// Reachable from two paths on Status:
/// - Pending banner → "Retry now" stays on Status (drains in
///   background); this sheet is opened by tapping the *stuck* banner
///   or via the count chip on the regular banner if the user wants
///   to inspect.
/// - Stuck banner → "Tap to see what failed" routes here directly.
///
/// The sheet itself doesn't trigger drains — the host's
/// `onRetryNow` does — so closing the sheet doesn't lose work.
public struct PendingTrashesSheet: View {
    public let intents: [PendingTrashIntent]
    public let maxRetryAttempts: Int
    public let onClose: () -> Void
    public let onRetryAll: () -> Void
    public let onDiscard: (UUID) -> Void

    @Environment(\.cairnTokens) private var t

    public init(
        intents: [PendingTrashIntent] = [],
        maxRetryAttempts: Int = 5,
        onClose: @escaping () -> Void = {},
        onRetryAll: @escaping () -> Void = {},
        onDiscard: @escaping (UUID) -> Void = { _ in }
    ) {
        self.intents = intents
        self.maxRetryAttempts = maxRetryAttempts
        self.onClose = onClose
        self.onRetryAll = onRetryAll
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(spacing: 0) {
            AppHeader(
                title: "Pending trashes".loc,
                subtitle: subtitle,
                leading: {
                    Button(action: onClose) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                            Text("Status".loc)
                                .font(.cairnScaled(size: 15))
                        }
                        .foregroundStyle(t.textBody)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                },
                trailing: { EmptyView() }
            )

            if intents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        explainer
                        retryAllButton
                        intentList
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(t.surface)
    }

    private var subtitle: String {
        let n = intents.count
        return CairnL10n.isChinese ? "\(n) 个请求" : (n == 1 ? "1 request" : "\(n) requests")
    }

    private var explainer: some View {
        Group {
            if CairnL10n.isChinese {
                Text("这些移入废纸篓操作未成功，已加入重试队列。它们将在下次同步时自动重试。达到重试限制（\(maxRetryAttempts) 次尝试）通常是因为服务器无法连接或 API 密钥已更改 — 请修复问题后轻点“立即全部重试”。")
            } else {
                Text("These trash runs failed and are queued for retry. They run automatically on the next sync. Items hit the retry limit (\(maxRetryAttempts) attempts) typically when the server is unreachable or the API key has changed — fix the root cause and tap Retry now.")
            }
        }
        .font(.cairnScaled(size: 13))
        .foregroundStyle(t.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var retryAllButton: some View {
        Button(action: onRetryAll) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                Text("Retry all now".loc)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(t.accent.opacity(0.15))
            .foregroundStyle(t.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var intentList: some View {
        CairnCard {
            VStack(spacing: 0) {
                ForEach(Array(intents.enumerated()), id: \.element.id) { idx, intent in
                    intentRow(intent)
                    if idx < intents.count - 1 { RowDivider() }
                }
            }
        }
    }

    @ViewBuilder
    private func intentRow(_ intent: PendingTrashIntent) -> some View {
        let isStuck = intent.attemptCount >= maxRetryAttempts
        let label = intent.assets.first?.originalFileName ?? "asset"
        let extra = intent.assets.count - 1

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.cairnScaled(size: 14, weight: .medium))
                        .foregroundStyle(t.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if extra > 0 {
                        Text("+\(extra)")
                            .font(.cairnScaled(size: 11, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                    }
                }
                Text(metaLine(intent: intent, isStuck: isStuck))
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(isStuck ? t.danger : t.textMuted)
                if let err = intent.lastError {
                    Text(err)
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: { onDiscard(intent.id) }) {
                Image(systemName: "trash")
                    .font(.cairnScaled(size: 14))
                    .foregroundStyle(t.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard pending trash".loc)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func metaLine(intent: PendingTrashIntent, isStuck: Bool) -> String {
        if CairnL10n.isChinese {
            if isStuck { return "已停滞 — 已达最大重试次数 \(intent.attemptCount) / \(maxRetryAttempts)" }
            return "已尝试 \(intent.attemptCount) 次"
        } else {
            let attempts = intent.attemptCount == 1 ? "1 attempt" : "\(intent.attemptCount) attempts"
            if isStuck { return "Stuck — \(attempts) of \(maxRetryAttempts) used" }
            return "\(attempts) so far"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.cairnScaled(size: 36, weight: .light))
                .foregroundStyle(t.verifiedInk)
            Text("Nothing pending".loc)
                .font(.cairnScaled(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
            Text("All trash requests completed successfully.".loc)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Pending trashes — populated") {
    PendingTrashesSheet(
        intents: [
            PendingTrashIntent(
                createdAt: Date(),
                runId: "run-1",
                assets: [
                    ServerAsset(
                        id: "a", checksum: Checksum(base64: "ck-A"),
                        livePhotoVideoId: nil, isTrashed: false,
                        originalFileName: "IMG_4821.HEIC", fileCreatedAt: nil
                    )
                ],
                assetsInPurview: 1,
                attemptCount: 2,
                lastError: "Immich server error (HTTP 502). Try again in a minute."
            ),
            PendingTrashIntent(
                createdAt: Date(),
                runId: "run-2",
                assets: [
                    ServerAsset(
                        id: "b1", checksum: Checksum(base64: "ck-B1"),
                        livePhotoVideoId: nil, isTrashed: false,
                        originalFileName: "IMG_4820.HEIC", fileCreatedAt: nil
                    ),
                    ServerAsset(
                        id: "b2", checksum: Checksum(base64: "ck-B2"),
                        livePhotoVideoId: nil, isTrashed: false,
                        originalFileName: "IMG_4819.HEIC", fileCreatedAt: nil
                    )
                ],
                assetsInPurview: 2,
                attemptCount: 5,
                lastError: "Immich rejected the API key (HTTP 401). Try re-verifying in Settings."
            ),
        ],
        maxRetryAttempts: 5
    )
    .cairnTheme()
}

#Preview("Pending trashes — empty") {
    PendingTrashesSheet(intents: [])
        .cairnTheme()
}
#endif
