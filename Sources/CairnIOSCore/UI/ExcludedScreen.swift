import SwiftUI
import CairnCore

/// The Excluded (allowlist) screen — filenames protected from future runs.
///
/// Mirrors the prototype `cairn/screens/excluded.jsx`. Reachable from
/// Settings → Safety rails → Excluded assets.
///
/// Two sources feed this list today:
///   · Manual exclusion from a run detail (primary flow)
///   · (Future) rule-based excludes like "never trash videos > 30s"
///
/// Each row pairs a thumbnail with its filename + "from run <id>" context so
/// the user can see *why* something is protected and unexclude with one tap.
/// Empty state explains how to get here from a run.
///
/// Microcopy is verbatim from the prototype — see HANDOFF.md "Keep these
/// copies verbatim". Don't paraphrase without designer review.
public struct ExcludedScreen: View {
    public let entries: [ExcludedScreenEntry]
    public let onBack: () -> Void
    /// Filenames the user wants to remove from the allowlist. The host wires
    /// this to a real `ExclusionStore.remove(...)` call (after translating
    /// filename → checksum). UI-side we work in filenames because that's
    /// what the row identity is and what the prototype's `excluded` Set
    /// holds; checksum lookup is a host concern.
    public let onUnexclude: ([String]) -> Void

    @Environment(\.cairnTokens) private var t
    @State private var pendingClearAll = false
    @State private var pendingRemoval: ExcludedScreenEntry?

    public init(
        entries: [ExcludedScreenEntry] = ExcludedScreenEntry.previewEntries,
        onBack: @escaping () -> Void = {},
        onUnexclude: @escaping ([String]) -> Void = { _ in }
    ) {
        self.entries = entries
        self.onBack = onBack
        self.onUnexclude = onUnexclude
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if entries.isEmpty {
                    emptyState
                } else {
                    explainerCard
                    sectionHeader
                    listCard
                }
                Spacer(minLength: 40)
            }
        }
        .background(t.bg)
        // "Clear all" confirm dialog. The prototype uses window.confirm with
        // copy: "Unexclude all <N> assets? They'll be eligible for future runs again."
        .confirmationDialog(
            CairnL10n.isChinese ? "取消排除全部 \(entries.count) 项资产？" : "Unexclude all \(entries.count) \(entries.count == 1 ? "asset" : "assets")?",
            isPresented: $pendingClearAll,
            titleVisibility: .visible
        ) {
            Button("Unexclude all".loc, role: .destructive) {
                onUnexclude(entries.map { $0.filename })
            }
            Button("Cancel".loc, role: .cancel) {}
        } message: {
            Text("They'll be eligible for future runs again.".loc)
        }
        // Per-row remove confirm — mirrors the prototype's toast-on-confirm
        // pattern. We don't ship a toast system here; the closure handoff
        // is the seam.
        .confirmationDialog(
            pendingRemoval.map { CairnL10n.isChinese ? "从排除列表中移除 \($0.filename)？" : "Remove \($0.filename) from excluded list?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = pendingRemoval {
                Button("Remove".loc, role: .destructive) {
                    onUnexclude([entry.filename])
                }
                Button("Cancel".loc, role: .cancel) {}
            }
        } message: {
            Text("Future runs can move this to Immich's Trash again.".loc)
        }
    }

    // MARK: - Header

    private var header: some View {
        AppHeader(
            title: "Excluded".loc,
            // Subtitle copy verbatim from screens/excluded.jsx.
            subtitle: entries.isEmpty
                ? "Nothing excluded — every indexed asset is fair game".loc
                : (CairnL10n.isChinese
                    ? "\(entries.count) 项资产受到保护，不会在后续运行中处理"
                    : "\(entries.count) \(entries.count == 1 ? "asset" : "assets") protected from future runs"),
            leading: {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.cairnScaled(size: 13, weight: .semibold))
                        Text("Settings".loc)
                            .font(.cairnScaled(size: 15))
                    }
                    .foregroundStyle(t.textBody)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(t.infoSoft)
                    .frame(width: 56, height: 56)
                Image(systemName: "shield")
                    .font(.cairnScaled(size: 24, weight: .semibold))
                    .foregroundStyle(t.infoInk)
            }
            .padding(.bottom, 14)

            // Copy verbatim from screens/excluded.jsx::EmptyState.
            Text("No assets excluded".loc)
                .font(.cairnScaled(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
                .padding(.bottom, 6)

            if CairnL10n.isChinese {
                (Text("打开任意运行记录，选择需要保留的照片，轻点 ")
                    + Text("排除").foregroundColor(t.textBody).bold()
                    + Text("。它们将显示在此处。"))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 280)
            } else {
                (Text("Open any run, select the assets you want to keep in scope, and tap ")
                    + Text("Exclude").foregroundColor(t.textBody).bold()
                    + Text(". They'll show up here."))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    // MARK: - Explainer card

    private var explainerCard: some View {
        Callout(.info, icon: "shield") {
            if CairnL10n.isChinese {
                (Text("已排除的照片仍保持索引 — ") + .cairnWord + Text(" 仍知道它们的存在 — 但未来每次对齐都会跳过它们。适用于即使从手机中删除也希望保留在服务器上的照片。"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                (Text("Excluded assets stay indexed — ") + .cairnWord + Text(" still knows they exist — but every future reconcile will skip them. Useful for photos you'd rather keep on the server even if they're gone from the phone."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Section header with "Clear all"

    private var sectionHeader: some View {
        KeylineSection("Protected assets".loc) {
            Button {
                pendingClearAll = true
            } label: {
                Text(CairnL10n.isChinese ? "全部清除" : "Clear all")
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .tracking(0.99)
                    .foregroundStyle(t.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rows

    private var listCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    ExcludedRow(entry: entry) {
                        pendingRemoval = entry
                    }
                    if idx < entries.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Row

/// A single allowlist row: thumb + filename + kind/size/run context + Remove.
/// Mirrors prototype `screens/excluded.jsx::ExcludedRow`.
private struct ExcludedRow: View {
    let entry: ExcludedScreenEntry
    let onRemove: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ImmichAssetThumb(assetId: entry.assetId, filename: entry.filename, size: 44, isLivePair: entry.isLivePair)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.cairnScaled(size: 13, design: .monospaced))
                    .tracking(-0.065) // -0.005em at 13pt
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(kindLabel)
                    // Size is unavailable when the entry was joined
                    // from a server-asset-only source (Immich's list
                    // endpoint omits file size), so suppress the
                    // "0.0 MB" placeholder rather than rendering it.
                    // CLI-driven entries with real bytes still show.
                    if entry.bytes > 0 {
                        Text("·")
                        Text(sizeLabel)
                    }
                    if let runSuffix = runSuffix {
                        Text("·")
                        (Text("From run ".loc)
                            + Text(runSuffix).font(.cairnScaled(size: 11.5, design: .monospaced)))
                    }
                }
                .font(.cairnScaled(size: 11.5))
                .foregroundStyle(t.textMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CairnChip(
                "Remove".loc,
                accessibilityLabel: CairnL10n.isChinese
                    ? "从排除列表移除 \(entry.filename)"
                    : "Remove \(entry.filename) from excluded list",
                action: onRemove
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var kindLabel: String {
        switch entry.kind {
        case .photo:    return "photo"
        case .video:    return "video"
        case .livePair: return "live-pair"
        }
    }

    private var sizeLabel: String {
        // The prototype uses `bytes / 1_048_576` with one decimal (always
        // MB). Match that exactly so the row reads identically; the shared
        // `formatBytes` helper would switch to GB on large values.
        String(format: "%.1f MB", Double(entry.bytes) / 1_048_576)
    }

    private var runSuffix: String? {
        guard let runId = entry.metadata.fromRunId, runId.count >= 8 else {
            return entry.metadata.fromRunId
        }
        return String(runId.suffix(8))
    }
}

// MARK: - Public entry model

/// One row in the excluded list. We model the row in UI terms (filename,
/// bytes, kind, paired-flag, plus the on-disk metadata) so the screen can
/// render without reaching back to the candidate fixtures or the live
/// `ExclusionStore`. Hosts assemble these by joining their PHAsset/server
/// records against `ExclusionStore.snapshot()`.
public struct ExcludedScreenEntry: Sendable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let bytes: Int
    public let kind: CairnFixtures.CandidateFixture.Kind
    public let isLivePair: Bool
    public let metadata: ExclusionMetadata
    /// Server-side asset UUID when known. Populated by the host when
    /// joining the exclusion list against server records; `nil` for
    /// preview fixtures (they fall back to the gradient placeholder).
    public let assetId: String?

    public init(
        filename: String,
        bytes: Int,
        kind: CairnFixtures.CandidateFixture.Kind,
        isLivePair: Bool,
        metadata: ExclusionMetadata,
        assetId: String? = nil
    ) {
        self.filename = filename
        self.bytes = bytes
        self.kind = kind
        self.isLivePair = isLivePair
        self.metadata = metadata
        self.assetId = assetId
    }
}

extension ExcludedScreenEntry {
    /// Preview fixtures: take the first few candidate fixtures and pretend
    /// the user excluded them from a recent run. Stable run id mirrors
    /// `CairnFixtures.runs[0].id` so the "from run …034389BC" suffix lines
    /// up across previews.
    public static let previewEntries: [ExcludedScreenEntry] = {
        let runId = "2026-04-21T17:57:15Z-034389BC"
        let addedAt = Date(timeIntervalSinceNow: -3_600 * 6)
        return CairnFixtures.candidates.prefix(5).map { c in
            ExcludedScreenEntry(
                filename: c.name,
                bytes: c.bytes,
                kind: c.kind,
                isLivePair: c.isLivePair,
                metadata: ExclusionMetadata(
                    addedAt: addedAt,
                    fromRunId: runId,
                    reason: nil
                )
            )
        }
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("Excluded — populated") {
    ExcludedScreen()
        .cairnTheme()
}

#Preview("Excluded — empty") {
    ExcludedScreen(entries: [])
        .cairnTheme()
}

#Preview("Excluded — dark") {
    ExcludedScreen()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
