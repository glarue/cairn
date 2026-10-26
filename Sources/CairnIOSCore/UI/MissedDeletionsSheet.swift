import SwiftUI
import CairnCore

/// Settings → Recovery → "Find missed deletions" sheet.
///
/// Surfaces server assets that look like prior iPhone uploads cairn
/// never observed and aren't currently alive on the device — the
/// "delete-before-hash race" recovery path. The host runs
/// `MissedDeletionFinder.find` after fetching the server list and
/// joining against the live local filename set; this screen just
/// renders the results and the bulk Trash / Keep / per-row Dismiss
/// affordances.
///
/// Three states, mirrored from `model.missedDeletionsState`:
///   - scanning: spinner + explainer
///   - loaded: list of candidates (possibly empty)
///   - error: short message + Retry
public struct MissedDeletionsSheet: View {

    public let state: CairnAppModel.MissedDeletionsState
    public let onClose: () -> Void
    /// Trigger a new scan. `minCreatedAt`/`maxCreatedAt` bound the
    /// server's `fileCreatedAt`. `strictHistorical` asks the host to
    /// further restrict candidates to filenames cairn previously
    /// observed on this device whose `localIdentifier` is no longer
    /// alive — the strongest positive signal short of PHPicker access
    /// to Recently Deleted (which iOS doesn't expose).
    public let onScan: (_ minCreatedAt: Date?, _ maxCreatedAt: Date?, _ strictHistorical: Bool) -> Void
    public let onTrash: (_ assets: [ServerAsset]) -> Void
    public let onKeep: (_ assets: [ServerAsset]) -> Void
    public let onDismissOne: (_ assetId: String) -> Void

    @Environment(\.cairnTokens) private var t
    @State private var pendingTrashAll: Bool = false
    @State private var pendingKeepAll: Bool = false
    @State private var dismissedIds: Set<String> = []
    @State private var zoomedAsset: ServerAsset?
    /// Inclusive lower bound on `fileCreatedAt`. Defaults to 30 days
    /// back so a fresh-opened sheet runs a narrow scan first; the user
    /// can widen the window by dragging the picker earlier.
    @State private var minCreatedAt: Date = Date().addingTimeInterval(-30 * 86_400)
    /// Inclusive upper bound on `fileCreatedAt`. Defaults to now so
    /// today's deletions are included.
    @State private var maxCreatedAt: Date = Date()
    @State private var minBoundEnabled: Bool = true
    @State private var maxBoundEnabled: Bool = true
    /// When on, narrows candidates to filenames cairn has observed on
    /// this device whose `localIdentifier` is no longer alive in
    /// PhotoKit. Highest-precision filter cairn can apply without a
    /// public API for Recently Deleted (none exists on iOS 16+).
    @State private var strictHistorical: Bool = true

    public init(
        state: CairnAppModel.MissedDeletionsState = .idle,
        onClose: @escaping () -> Void = {},
        onScan: @escaping (Date?, Date?, Bool) -> Void = { _, _, _ in },
        onTrash: @escaping ([ServerAsset]) -> Void = { _ in },
        onKeep: @escaping ([ServerAsset]) -> Void = { _ in },
        onDismissOne: @escaping (String) -> Void = { _ in }
    ) {
        self.state = state
        self.onClose = onClose
        self.onScan = onScan
        self.onTrash = onTrash
        self.onKeep = onKeep
        self.onDismissOne = onDismissOne
    }

    private var resolvedMin: Date? { minBoundEnabled ? minCreatedAt : nil }
    private var resolvedMax: Date? { maxBoundEnabled ? maxCreatedAt : nil }

    public var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(t.divider)
                content
            }
        }
        .confirmationDialog(
            CairnL10n.isChinese ? "将 Immich 上的 \(visibleAssets.count) 项移入废纸篓？" : "Trash \(visibleAssets.count) on Immich?",
            isPresented: $pendingTrashAll,
            titleVisibility: .visible
        ) {
            Button(CairnL10n.isChinese ? "将全部 \(visibleAssets.count) 项移入废纸篓" : "Move all \(visibleAssets.count) to trash", role: .destructive) {
                onTrash(visibleAssets)
            }
            Button("Cancel".loc, role: .cancel) {}
        } message: {
            Text(CairnL10n.isChinese ? "它们将移入 Immich 的废纸篓。保留 30 天；如需恢复可从 Immich 网页端操作。" : "They'll move to Immich's Trash. 30-day retention; restore from the Immich web UI if needed.")
        }
        .confirmationDialog(
            CairnL10n.isChinese ? "在 Immich 上保留全部 \(visibleAssets.count) 项？" : "Keep all \(visibleAssets.count) on Immich?",
            isPresented: $pendingKeepAll,
            titleVisibility: .visible
        ) {
            Button(CairnL10n.isChinese ? "排除全部 \(visibleAssets.count) 项" : "Exclude all \(visibleAssets.count)", role: .destructive) {
                onKeep(visibleAssets)
            }
            Button("Cancel".loc, role: .cancel) {}
        } message: {
            Text(CairnL10n.isChinese ? "这些项将被添加到 cairn 的排除列表中。未来扫描将跳过它们。" : "These will be added to cairn's exclusion list. Future scans skip them.")
        }
        .overlay(zoomOverlay)
        .onChange(of: stateAssetIds) { _, _ in
            dismissedIds.removeAll()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find missed deletions".loc)
                    .font(.cairnScaled(size: 17, weight: .semibold))
                    .foregroundStyle(t.text)
                if case .loaded(let assets) = state {
                    let visible = assets.filter { !dismissedIds.contains($0.id) }.count
                    if CairnL10n.isChinese {
                        Text(visible == 0 ? "未发现异常" : "\(visible) 项候选")
                            .font(.cairnScaled(size: 12))
                            .foregroundStyle(t.textMuted)
                    } else {
                        Text(visible == 0 ? "Nothing flagged" : "\(visible) candidate\(visible == 1 ? "" : "s")")
                            .font(.cairnScaled(size: 12))
                            .foregroundStyle(t.textMuted)
                    }
                }
            }
            Spacer()
            Button("Done".loc, action: onClose)
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .loaded(let assets):
            let visible = assets.filter { !dismissedIds.contains($0.id) }
            if visible.isEmpty {
                emptyState
            } else {
                loadedState(visible)
            }
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - States

    private var idleState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "magnifyingglass")
                    .font(.cairnScaled(size: 32))
                    .foregroundStyle(t.textMuted)
                    .padding(.top, 16)

                if CairnL10n.isChinese {
                    (Text("在 Immich 上扫描看似来自过往 iPhone 上传但 ") + .cairnWord + Text(" 从未观察过的照片。使用更严格的过滤条件要求提供 ") + .cairnWord + Text(" 曾在此设备上见过该照片的明确证据 — 更加精准，但不会捕捉到 ") + .cairnWord + Text(" 完全未曾观察过的照片。"))
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("Scans Immich for assets that look like prior iPhone uploads ") + .cairnWord + Text(" never observed. Use the Stricter filter to require positive evidence that ") + .cairnWord + Text(" previously saw the photo on this device — much more precise, but won't catch photos ") + .cairnWord + Text(" never observed at all."))
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }

                autoScanCard
            }
            .padding(.bottom, 24)
        }
    }

    /// Single scan card: date range + stricter-filter toggle.
    private var autoScanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.infoInk)
                Text("Scan options".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.text)
            }
            dateRangeControls
            Divider().background(t.divider)
            Toggle(isOn: $strictHistorical) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stricter filter".loc)
                        .font(.cairnScaled(size: 13, weight: .semibold))
                        .foregroundStyle(t.text)
                    if CairnL10n.isChinese {
                        (Text("仅标记 ") + .cairnWord + Text(" 之前在此设备上见过的照片。排除具有 iPhone 风格文件名的仅 Immich 端上传。"))
                            .font(.cairnScaled(size: 11))
                            .foregroundStyle(t.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        (Text("Only flag photos ") + .cairnWord + Text(" previously saw on this device. Excludes Immich-only uploads with iPhone-style filenames."))
                            .font(.cairnScaled(size: 11))
                            .foregroundStyle(t.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(t.verified)
            CairnChip(
                "Start scan".loc,
                accessibilityLabel: "Start scan".loc,
                action: { onScan(resolvedMin, resolvedMax, strictHistorical) }
            )
        }
        .padding(14)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    /// Date pickers for narrowing the server scan window. Surfaced in
    /// both idle and loaded states so the user can refine and re-scan
    /// without leaving the sheet. The toggles let either bound be
    /// disabled (open-ended on that side).
    private var dateRangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DATE RANGE".loc)
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.99)
                .foregroundStyle(t.textMuted)
            HStack {
                Toggle(isOn: $minBoundEnabled) {
                    Text("From".loc)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textBody)
                }
                .labelsHidden()
                .tint(t.verified)
                if minBoundEnabled {
                    DatePicker(
                        "From".loc,
                        selection: $minCreatedAt,
                        in: ...maxCreatedAt,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                } else {
                    Text("From: any".loc)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                }
                Spacer()
            }
            HStack {
                Toggle(isOn: $maxBoundEnabled) {
                    Text("To".loc)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textBody)
                }
                .labelsHidden()
                .tint(t.verified)
                if maxBoundEnabled {
                    DatePicker(
                        "To".loc,
                        selection: $maxCreatedAt,
                        in: minCreatedAt...,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                } else {
                    Text("To: now".loc)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                }
                Spacer()
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning Immich…".loc)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(t.infoSoft)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.cairnScaled(size: 22, weight: .semibold))
                    .foregroundStyle(t.infoInk)
            }
            Text("Nothing flagged".loc)
                .font(.cairnScaled(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
            if CairnL10n.isChinese {
                (Text("服务器上的每项资产均与手机上仍存在的照片匹配，或属于 ") + .cairnWord + Text(" 已经了解的照片。"))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            } else {
                (Text("Every server asset matches a photo still on your phone or one ") + .cairnWord + Text(" already knows about."))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.cairnScaled(size: 28))
                .foregroundStyle(t.dangerInk)
            Text("Couldn't scan".loc)
                .font(.cairnScaled(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
            Text(message)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            CairnChip(
                "Retry".loc,
                accessibilityLabel: "Retry".loc,
                action: { onScan(resolvedMin, resolvedMax, strictHistorical) }
            )
            Spacer()
        }
    }

    @ViewBuilder
    private func loadedState(_ visible: [ServerAsset]) -> some View {
        VStack(spacing: 0) {
            Callout(.info, icon: "info.circle") {
                if CairnL10n.isChinese {
                    (Text("这些照片存在于 Immich 上，看似过往 iPhone 上传但当前不在手机中。") + .cairnWord + Text(" 从未观察过它们，因此未同步本地删除操作。移入废纸篓以清理它们；保留以添加到排除列表。"))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("These assets are on Immich, look like prior iPhone uploads, and aren't on your phone now. ") + .cairnWord + Text(" never observed them, so it didn't propagate the local deletion. Trash to clean them up; Keep to add to the exclusion list."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, asset in
                        MissedDeletionRow(
                            asset: asset,
                            onZoom: { zoomedAsset = asset },
                            onDismiss: {
                                dismissedIds.insert(asset.id)
                                onDismissOne(asset.id)
                            }
                        )
                        if idx < visible.count - 1 {
                            RowDivider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 88)
            }

            bulkActionBar(count: visible.count)
        }
    }

    private func bulkActionBar(count: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                pendingKeepAll = true
            } label: {
                Text("Keep all".loc)
                    .font(.cairnScaled(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(t.surfaceAlt)
                    .foregroundStyle(t.textBody)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                pendingTrashAll = true
            } label: {
                Text(CairnL10n.isChinese ? "全部移入废纸篓 \(count)" : "Trash all \(count)")
                    .font(.cairnScaled(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(t.danger)
                    .foregroundStyle(t.dangerInk)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(t.bg)
        .overlay(Rectangle().fill(t.divider).frame(height: 0.5), alignment: .top)
    }

    // MARK: - Zoom overlay

    @ViewBuilder
    private var zoomOverlay: some View {
        if let asset = zoomedAsset {
            ZStack {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
                    .onTapGesture { zoomedAsset = nil }
                    .accessibilityLabel("Close zoomed thumbnail")
                    .accessibilityAddTraits(.isButton)
                ImmichAssetThumb(
                    assetId: asset.id,
                    filename: asset.originalFileName ?? "",
                    size: 320,
                    isLivePair: asset.livePhotoVideoId != nil
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .transition(.opacity)
            // Trap VoiceOver focus inside the overlay; otherwise tab
            // order leaks back into the row list while the zoom is
            // visible. Matches PendingReviewScreen's identical overlay.
            .accessibilityAddTraits(.isModal)
        }
    }

    // MARK: - Helpers

    private var visibleAssets: [ServerAsset] {
        guard case .loaded(let assets) = state else { return [] }
        return assets.filter { !dismissedIds.contains($0.id) }
    }

    private var stateAssetIds: [String] {
        guard case .loaded(let assets) = state else { return [] }
        return assets.map(\.id)
    }
}

// MARK: - Row

private struct MissedDeletionRow: View {
    let asset: ServerAsset
    let onZoom: () -> Void
    let onDismiss: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onZoom) {
                ImmichAssetThumb(
                    assetId: asset.id,
                    filename: asset.originalFileName ?? "",
                    size: 44,
                    isLivePair: asset.livePhotoVideoId != nil
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.originalFileName ?? "—")
                    .font(.cairnScaled(size: 13, design: .monospaced))
                    .tracking(-0.065)
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let date = asset.fileCreatedAt {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.cairnScaled(size: 11.5))
                        .foregroundStyle(t.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CairnChip("Skip", accessibilityLabel: "Skip \(asset.originalFileName ?? "")", action: onDismiss)
        }
        .padding(.vertical, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

#if DEBUG
#Preview("missed - loaded") {
    MissedDeletionsSheet(
        state: .loaded([
            ServerAsset(id: "1", checksum: Checksum(base64: "AAA"), originalFileName: "IMG_4391.HEIC", fileCreatedAt: Date().addingTimeInterval(-86400)),
            ServerAsset(id: "2", checksum: Checksum(base64: "BBB"), originalFileName: "IMG_4392.HEIC", fileCreatedAt: Date().addingTimeInterval(-86400 * 2))
        ])
    )
    .cairnTheme()
}

#Preview("missed - empty") {
    MissedDeletionsSheet(state: .loaded([]))
        .cairnTheme()
}

#Preview("missed - scanning") {
    MissedDeletionsSheet(state: .scanning)
        .cairnTheme()
}

#Preview("missed - error") {
    MissedDeletionsSheet(state: .error("Couldn't reach Immich. Check your connection."))
        .cairnTheme()
}
#endif
