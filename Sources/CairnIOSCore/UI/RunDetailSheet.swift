import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The per-run detail sheet. Mirrors the prototype's
/// `screens/run-detail.jsx` — the heart of the undo flow.
///
/// What this screen lets the user do:
///   - Browse the assets in a single run as a thumbnail grid.
///   - Filter by filename (substring, case-insensitive, monospace input).
///   - Select N assets; the footer swaps from a passive Close into a
///     contextual action bar: Restore · Exclude · Open in Immich · Copy.
///   - Restore moves trashed assets back out of trash. Disabled on dry-runs
///     and aborted runs (nothing to undo).
///   - Exclude adds filenames to the allowlist so future runs skip them.
///     Available on every run type — primary triage action on dry-runs.
///   - Live Photo expansion: when a `live-pair` asset is selected, the
///     action bar shows "N selected · +M paired videos = total" so the
///     user understands the real server-side impact before tapping.
///   - Aborted runs surface the candidates that *would* have been affected
///     so the user can inspect them; the header callout names the rail.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md
/// "Keep these copies verbatim" — don't paraphrase without designer review.
///
/// The mock surfaces here are wired to closures the parent owns. When the
/// real iOS app target lands:
///   - `onRestore` -> `RestoreOrchestrator.restore(filenames:)` (which
///     calls `ImmichClient.restoreAssets(ids:)` per HANDOFF).
///   - `onExclude` -> `ExclusionStore.add(_:)` from `CairnCore`.
///   - `Open in Immich` -> universal link to the breadcrumb tag (or trash
///     view fallback when the run had no tag).
///   - `Copy` -> `UIPasteboard.general.string` (already wired below).
public struct RunDetailSheet: View {

    // MARK: - Public surface

    public let run: CairnFixtures.RunFixture
    public let assets: [CairnFixtures.CandidateFixture]
    /// Checksums currently in the host's `ExclusionStore`. Drives the
    /// per-tile "already protected" badge and toggles the selection
    /// action bar's button between "Exclude N" and "Unexclude N" so
    /// reversing a mistaken exclusion doesn't require a hunt through
    /// Settings → Excluded assets.
    public let excludedChecksums: Set<String>
    public let onClose: () -> Void
    /// Dispatches the user's exclude selection. Host is expected to
    /// read `.checksum` from each candidate (the `ExclusionStore` is
    /// checksum-keyed). `.name` / `.assetId` are also available for
    /// the journal event / UI feedback.
    public let onExclude: ([CairnFixtures.CandidateFixture]) -> Void
    /// Dispatches the user's un-exclude selection. Mirror of
    /// `onExclude`; host pulls `.checksum` and hands it to
    /// `ExclusionStore.remove(_:)`. Reverses a mistaken exclude
    /// without a trip to Settings.
    public let onUnexclude: ([CairnFixtures.CandidateFixture]) -> Void
    /// Dispatches the user's restore selection. Host is expected to
    /// read `.assetId` from each candidate and pass that set to
    /// `RestoreOrchestrator.restore(fromRunId:assetIds:)` — an empty
    /// or nil set there means "restore the whole run," which is NOT
    /// what the user asked for when they made a partial selection.
    public let onRestore: ([CairnFixtures.CandidateFixture]) -> Void
    public let serverURL: URL?

    public init(
        run: CairnFixtures.RunFixture = CairnFixtures.runs[0],
        assets: [CairnFixtures.CandidateFixture] = Array(CairnFixtures.candidates.prefix(14)),
        excludedChecksums: Set<String> = [],
        onClose: @escaping () -> Void = {},
        onExclude: @escaping ([CairnFixtures.CandidateFixture]) -> Void = { _ in },
        onUnexclude: @escaping ([CairnFixtures.CandidateFixture]) -> Void = { _ in },
        onRestore: @escaping ([CairnFixtures.CandidateFixture]) -> Void = { _ in },
        serverURL: URL? = nil
    ) {
        self.run = run
        self.assets = assets
        self.excludedChecksums = excludedChecksums
        self.onClose = onClose
        self.onExclude = onExclude
        self.onUnexclude = onUnexclude
        self.onRestore = onRestore
        self.serverURL = serverURL
    }

    // MARK: - Local state
    //
    // Lives entirely inside the sheet (nothing is hoisted to the parent
    // beyond the onXxx closures). The prototype's "just-restored" /
    // "just-excluded" flashes are driven by short-lived state and a fade.
    // We mark `restored` locally too so the user immediately sees the
    // greyed-out treatment without waiting for a re-fetch from the parent.

    @State private var selected: Set<String> = []
    @State private var restored: Set<String> = []      // names restored in-session
    @State private var excludedLocal: Set<String> = [] // names excluded in-session
    @State private var filter: String = ""
    @State private var justRestored: Int? = nil        // count flash · 2.4s
    @State private var justExcluded: Int? = nil        // count flash · 2.4s

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Derived

    private var filtered: [CairnFixtures.CandidateFixture] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return assets }
        return assets.filter { $0.name.lowercased().contains(q) }
    }

    private var selectableAssets: [CairnFixtures.CandidateFixture] {
        filtered.filter { !restored.contains($0.name) }
    }

    private var allVisibleSelected: Bool {
        !selectableAssets.isEmpty && selectableAssets.allSatisfy { selected.contains($0.name) }
    }

    /// Restore is only meaningful on completed trash runs that
    /// haven't already been fully restored. Dry-runs and aborted
    /// runs never moved anything to trash; `.restored` runs were
    /// already undone (double-restoring is a no-op on the server
    /// but confuses the UI with phantom progress).
    /// (from screens/run-detail.jsx::canRestore, extended for the
    /// `.restored` state.)
    private var canRestore: Bool {
        run.trashed > 0 && !run.dryRun && run.status != .aborted && run.status != .restored
    }

    private var hasSelection: Bool { !selected.isEmpty }

    /// A candidate is "effectively excluded" if its checksum is in
    /// either the persisted store (`excludedChecksums`) or the
    /// in-session set (`excludedLocal`, keyed by name), so the
    /// button label flips immediately after a tap rather than
    /// waiting for the next host refresh.
    private func isEffectivelyExcluded(_ asset: CairnFixtures.CandidateFixture) -> Bool {
        if excludedLocal.contains(asset.name) { return true }
        if let c = asset.checksum, excludedChecksums.contains(c) { return true }
        return false
    }

    /// Selected candidates that aren't yet excluded. When non-empty,
    /// the selection-bar button is "Exclude".
    private var selectedNotYetExcluded: [CairnFixtures.CandidateFixture] {
        assets.filter { selected.contains($0.name) && !isEffectivelyExcluded($0) }
    }

    /// Selected candidates that ARE currently excluded. When the
    /// entire selection is already excluded, the button flips to
    /// "Unexclude" so the user can reverse a prior tap without a
    /// trip through Settings.
    private var selectedAlreadyExcluded: [CairnFixtures.CandidateFixture] {
        assets.filter { selected.contains($0.name) && isEffectivelyExcluded($0) }
    }

    /// Live-photo expansion: each selected `live-pair` asset implicitly
    /// pulls its paired motion video on the server. We surface the real
    /// expanded count in the action bar so the user isn't surprised by a
    /// "5 selected" tap that actually touches 7 server assets.
    private var pairedInSelection: Int {
        var c = 0
        for name in selected {
            if let a = assets.first(where: { $0.name == name }), a.isLivePair { c += 1 }
        }
        return c
    }
    private var expandedCount: Int { selected.count + pairedInSelection }

    private var runKind: String {
        if run.status == .aborted { return "Aborted run" }
        if run.status == .restored { return "Restored run" }
        if run.dryRun { return "Dry-run" }
        return "Trash run"
    }

    private var headerTitle: String {
        if run.status == .aborted {
            // Differentiate safety-rail aborts (the user-intent-refused
            // case) from network/unexpected failures. Prior versions
            // hardcoded "Stopped by safety rail" for every aborted run,
            // which was misleading for connectivity-class failures.
            return abortedClassification.headerTitle
        }
        if run.status == .restored {
            if CairnL10n.isChinese { return "已恢复 \(run.restored) 项照片" }
            let suffix = run.restored == 1 ? "" : "s"
            return "\(run.restored) asset\(suffix) restored"
        }
        if run.dryRun { return "Preview only — nothing touched".loc }
        if CairnL10n.isChinese { return "已将 \(run.trashed) 项照片移入废纸篓" }
        let suffix = run.trashed == 1 ? "" : "s"
        return "\(run.trashed) asset\(suffix) moved to Trash"
    }

    /// Classify an aborted run from its `notes` payload (which JournalReader
    /// formats as `"aborted · <reason>"`). The classification picks the
    /// header title and callout copy.
    private var abortedClassification: AbortedClassification {
        let prefix = "aborted · "
        let reason: String = {
            if run.notes.lowercased().hasPrefix(prefix) {
                return String(run.notes.dropFirst(prefix.count))
            }
            return run.notes
        }()
        if reason.hasPrefix("thresholdexceeded") {
            return .safetyRail(reason: reason)
        }
        if reason.hasPrefix("emptyserverresponse") {
            return .emptyServer
        }
        if reason.hasPrefix("emptylocallibrary") {
            return .emptyLocal
        }
        if reason.hasPrefix("firstrunnotdryrun") {
            return .firstRunNotDryRun
        }
        return .unexpected(reason: reason)
    }

    private enum AbortedClassification {
        case safetyRail(reason: String)
        case emptyServer
        case emptyLocal
        case firstRunNotDryRun
        case unexpected(reason: String)

        var headerTitle: String {
            switch self {
            case .safetyRail:       return "Stopped by safety rail"
            case .emptyServer:      return "Server returned no assets"
            case .emptyLocal:       return "Local library is empty"
            case .firstRunNotDryRun:return "First run must be a dry-run"
            case .unexpected:       return "Trash didn't finish"
            }
        }
    }

    // MARK: - Body

    public var body: some View {
        // Native iOS sheet — standard grabber, drag-to-dismiss, and
        // detent resizing come for free from `.presentationDetents`
        // + `.presentationDragIndicator(.visible)`. No custom
        // overlay shape or gesture plumbing needed.
        VStack(spacing: 0) {
            header
            metaChips
            if run.status == .aborted { abortedCallout }
            if let n = justRestored { justRestoredFlash(count: n) }
            if let n = justExcluded { justExcludedFlash(count: n) }
            if !assets.isEmpty {
                filterRow
                selectionCountRow
            }
            scrollBody
            footer
        }
        .background(t.surface)
        .cairnBannerAnimation(value: flashKey)
        .cairnBannerAnimation(value: hasSelection)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(t.surface)
    }

    /// Stable equatable key that toggles whenever a flash callout
    /// enters or leaves, so the parent spring animation fires in
    /// sync with the `.cairnBanner` transitions on the flashes.
    private var flashKey: [Int] {
        [justRestored ?? -1, justExcluded ?? -1]
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(runKind.loc.uppercased())
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textMuted)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.cairnScaled(size: 14, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 4)

            Text(headerTitle)
                .font(.cairnScaled(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var headerSubtitle: String {
        let date = formattedHeaderDate(run.startedAt)
        if run.durationMs > 0 {
            return "\(date) · \(String(format: "%.2fs", Double(run.durationMs) / 1000))"
        }
        return date
    }

    private func formattedHeaderDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm")
        return f.string(from: d)
    }

    private var metaChips: some View {
        HStack(spacing: 6) {
            MetaChip(label: String(run.id.suffix(8)), tone: .neutral, mono: true)
            if run.tag != nil {
                MetaChip(label: "breadcrumb set".loc, tone: .verified, icon: "tag")
            }
            if !restored.isEmpty {
                MetaChip(label: CairnL10n.isChinese ? "\(restored.count) 项已恢复" : "\(restored.count) restored", tone: .info)
            }
            if !excludedLocal.isEmpty {
                MetaChip(label: CairnL10n.isChinese ? "\(excludedLocal.count) 项已排除" : "\(excludedLocal.count) excluded", tone: .info)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Callouts

    @ViewBuilder
    private var abortedCallout: some View {
        switch abortedClassification {
        case .safetyRail(let reason):
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Percent threshold exceeded".loc).fontWeight(.semibold)
                    Text(safetyRailMessage(from: reason))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        case .emptyServer:
            Callout(.pending, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server returned no assets".loc).fontWeight(.semibold)
                    Text("cairn refused to act on what looked like a transient API problem. Nothing was touched.".loc)
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        case .emptyLocal:
            Callout(.pending, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local library is empty".loc).fontWeight(.semibold)
                    Text("Photos permission may have been revoked, or the library scan hadn't completed. Nothing was touched.".loc)
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        case .firstRunNotDryRun:
            Callout(.pending, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("First run must be a dry-run".loc).fontWeight(.semibold)
                    Text("cairn requires a preview before the first real trash on a fresh observed store.".loc)
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        case .unexpected(let reason):
            Callout(.pending, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash didn't finish".loc).fontWeight(.semibold)
                    Text(reason).opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// Parse a thresholdExceeded reason like
    /// `"thresholdexceeded — would delete 12 of 1024 in-purview assets (1.17%); limit is 1.00%"`
    /// into a user-facing sentence with the actual percentages.
    private func safetyRailMessage(from reason: String) -> String {
        if let percentRange = reason.range(of: "%);"),
           let limitRange = reason.range(of: "limit is ") {
            let beforePercent = reason[..<percentRange.lowerBound]
            if let openParen = beforePercent.lastIndex(of: "("),
               let percentValue = Double(beforePercent[beforePercent.index(after: openParen)...]) {
                let afterLimit = reason[limitRange.upperBound...]
                let limitDigits = afterLimit.prefix(while: { $0.isNumber || $0 == "." })
                if let limitValue = Double(limitDigits) {
                    return String(
                        format: "%.1f%% of matched assets would have moved to Immich's Trash. Your cap is %.1f%%. Nothing was touched.",
                        percentValue, limitValue
                    )
                }
            }
        }
        return "The percent safety rail tripped. Nothing was touched."
    }

    private func justRestoredFlash(count: Int) -> some View {
        // from screens/run-detail.jsx::doRestore toast (rendered inline as
        // a callout in the sheet body, not the global toast).
        Callout(.verified, icon: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 2) {
                Text(CairnL10n.isChinese ? "\(count) 项已恢复" : "\(count) restored").fontWeight(.semibold)
                Text("Moved out of Immich's Trash, back to your active library.".loc)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.cairnBanner)
    }

    private func justExcludedFlash(count: Int) -> some View {
        // Mirrors the prototype's "N excluded" toast (info tone). Inline
        // in the sheet so it lives alongside the run's other state.
        Callout(.info, icon: "shield") {
            VStack(alignment: .leading, spacing: 2) {
                Text(CairnL10n.isChinese ? "\(count) 项已排除" : "\(count) excluded").fontWeight(.semibold)
                Text(count == 1
                     ? "Future runs will skip it."
                     : "Future runs will skip these assets.")
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.cairnBanner)
    }

    // MARK: - Filter + select-all

    private var filterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .foregroundStyle(t.textHint)
                    .accessibilityHidden(true)
                TextField("", text: $filter, prompt:
                    Text("Filter by filename…".loc)
                        .font(.cairnScaled(size: 12, design: .monospaced))
                        .foregroundColor(t.textHint)
                )
                .textFieldStyle(.plain)
                .font(.cairnScaled(size: 12, design: .monospaced))
                .foregroundStyle(t.text)
                .autocorrectionDisabled()
                #if canImport(UIKit)
                .textInputAutocapitalization(.never)
                #endif
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark")
                            .font(.cairnScaled(size: 10, weight: .semibold))
                            .foregroundStyle(t.textHint)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter".loc)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(t.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            if !selectableAssets.isEmpty {
                Button(action: toggleSelectAllVisible) {
                    Text(allVisibleSelected ? "Deselect".loc : "Select all".loc)
                        .font(.cairnScaled(size: 11, weight: .semibold))
                        .foregroundStyle(t.textBody)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(t.divider, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var selectionCountRow: some View {
        HStack {
            Text(selectionCountLabel.loc.uppercased())
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
            Spacer()
            if canRestore {
                HStack(spacing: 5) {
                    Circle()
                        .fill(t.textMuted)
                        .frame(width: 5, height: 5)
                    Text("IN TRASH".loc)
                        .font(.cairnScaled(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(t.textMuted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var selectionCountLabel: String {
        let base: String
        if filtered.count == assets.count {
            base = CairnL10n.isChinese ? "\(assets.count) 项照片" : "\(assets.count) assets"
        } else {
            base = CairnL10n.isChinese
                ? "\(filtered.count) / \(assets.count) 项匹配"
                : "\(filtered.count) of \(assets.count) match"
        }
        if !selected.isEmpty {
            return CairnL10n.isChinese
                ? "\(base) · 已选 \(selected.count) 项"
                : "\(base) · \(selected.count) selected"
        }
        return base
    }

    // MARK: - Scrolling body (grid + metadata + breadcrumb)

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !assets.isEmpty {
                    assetGrid
                }
                sectionLabel("Run metadata".loc)
                metadataCard
                sectionLabel("Server-side breadcrumb".loc)
                breadcrumbCard
                Spacer(minLength: 8)
            }
        }
        .frame(maxHeight: 380)
    }

    private var assetGrid: some View {
        CairnCard {
            Group {
                if filtered.isEmpty {
                    Text(CairnL10n.isChinese
                        ? "没有文件名匹配“\(filter)”。"
                        : "No filename matches \"\(filter)\".")
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                        ForEach(filtered) { a in
                            AssetTile(
                                asset: a,
                                isSelected: selected.contains(a.name),
                                isRestored: restored.contains(a.name),
                                isExcluded: isEffectivelyExcluded(a),
                                onTap: { toggle(a.name) }
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
        .padding(.bottom, 12)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(CairnL10n.isChinese ? s.loc : s.loc.uppercased())
            .font(.cairnScaled(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(t.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var metadataCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                KeyValRow("Run ID", value: String(run.id.suffix(8)), mono: true)
                RowDivider()
                KeyValRow("Started", value: formattedFullDate(run.startedAt))
                if run.durationMs > 0 {
                    RowDivider()
                    KeyValRow("Duration", value: String(format: "%.2fs", Double(run.durationMs) / 1000))
                }
                if let tag = run.tag {
                    RowDivider()
                    KeyValRow("Breadcrumb",
                              value: tag.split(separator: "/").last.map(String.init) ?? tag,
                              mono: true)
                }
                RowDivider()
                KeyValRow("Notes", value: run.notes)
            }
        }
        .padding(.bottom, 12)
    }

    private var breadcrumbCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(run.tag ?? "none — this run did not tag the server")
                    .font(.cairnScaled(size: 12, design: .monospaced))
                    .foregroundStyle(t.textBody)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                // from screens/run-detail.jsx — keep verbatim
                Text("Find these in Immich's Tags view. Assets stay in Trash for 30 days.".loc)
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 16)
    }

    private func formattedFullDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: - Footer (idle vs. selection)

    @ViewBuilder
    private var footer: some View {
        if hasSelection {
            SelectionActionBar(
                selectedCount: selected.count,
                pairedCount: pairedInSelection,
                expandedCount: expandedCount,
                canRestore: canRestore,
                allSelectedExcluded: hasSelection && selectedNotYetExcluded.isEmpty,
                onClear: { selected.removeAll() },
                onExclude: doExclude,
                onUnexclude: doUnexclude,
                onOpen: doOpenInImmich,
                onCopy: doCopy,
                onRestore: doRestore
            )
            .transition(.cairnBannerBottom)
        } else if canRestore {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Text("Close".loc)
                        .font(.cairnScaled(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(t.textBody)
                        .background(t.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Text("Select assets to act on them".loc)
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(footerSurface)
        } else {
            Button(action: onClose) {
                Text("Close".loc)
                    .font(.cairnScaled(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(t.textBody)
                    .background(t.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(footerSurface)
        }
    }

    private var footerSurface: some View {
        t.surface.overlay(
            Rectangle().fill(t.divider).frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Actions

    private func toggle(_ name: String) {
        if restored.contains(name) { return }
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
    }

    private func toggleSelectAllVisible() {
        if allVisibleSelected {
            for a in selectableAssets { selected.remove(a.name) }
        } else {
            for a in selectableAssets { selected.insert(a.name) }
        }
    }

    private func doRestore() {
        let picks = assets.filter { selected.contains($0.name) }
        guard !picks.isEmpty else { return }
        // Optimistic local state — surface the greyed-out treatment now
        // rather than waiting for the parent to round-trip a refresh.
        for p in picks { restored.insert(p.name) }
        selected.removeAll()
        let count = picks.count
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { justRestored = count }
        scheduleClearFlash(restoredCount: count)
        onRestore(picks)
    }

    private func doExclude() {
        let picks = selectedNotYetExcluded
        guard !picks.isEmpty else { return }
        for p in picks { excludedLocal.insert(p.name) }
        selected.removeAll()
        let count = picks.count
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { justExcluded = count }
        scheduleClearFlash(excludedCount: count)
        onExclude(picks)
    }

    private func doUnexclude() {
        let picks = selectedAlreadyExcluded
        guard !picks.isEmpty else { return }
        // Strip from the in-session set so the button flips back to
        // "Exclude" immediately if the user re-selects the same row.
        // Persisted state clears when the host-provided
        // `excludedChecksums` refreshes on next render.
        for p in picks { excludedLocal.remove(p.name) }
        selected.removeAll()
        onUnexclude(picks)
    }

    private func doCopy() {
        let names = Array(selected).sorted().joined(separator: "\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = names
        #endif
        // No-op on non-UIKit platforms (e.g. macOS preview); the action
        // shape stays the same so the parent doesn't need to gate it.
    }

    private func doOpenInImmich() {
        #if canImport(UIKit)
        guard let serverURL,
              let firstName = selected.first,
              let match = assets.first(where: { $0.name == firstName }),
              let assetId = match.assetId else { return }

        // Web fallback — the server-specific viewer URL (prior behavior).
        var components = URLComponents()
        components.scheme = serverURL.scheme
        components.host = serverURL.host(percentEncoded: false)
        components.port = serverURL.port
        components.path = "/photos/\(assetId)"
        let webURL = components.url

        // Prefer the Immich app's own deep link. Immich's iOS app
        // registers the `immich` URL scheme and routes
        // `immich://asset?id=<uuid>` to its asset viewer (same scheme its
        // widget uses). `open(completionHandler:)` reports success=false
        // when no installed app claims the scheme, so we fall back to the
        // browser without needing `immich` in LSApplicationQueriesSchemes
        // (which `canOpenURL` would otherwise require). Note: the deep link
        // carries no server context, so it opens the asset in whichever
        // server the Immich app is signed into — correct for the
        // single-server case; the web fallback stays server-specific.
        var appComponents = URLComponents()
        appComponents.scheme = "immich"
        appComponents.host = "asset"
        appComponents.queryItems = [URLQueryItem(name: "id", value: assetId)]

        if let appURL = appComponents.url {
            UIApplication.shared.open(appURL, options: [:]) { success in
                if !success, let webURL {
                    UIApplication.shared.open(webURL)
                }
            }
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
        #endif
    }

    private func scheduleClearFlash(restoredCount: Int? = nil, excludedCount: Int? = nil) {
        let token = restoredCount ?? excludedCount ?? 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) {
                if restoredCount != nil, justRestored == token { justRestored = nil }
                if excludedCount != nil, justExcluded == token { justExcluded = nil }
            }
        }
    }
}

// MARK: - Asset tile

/// Single grid cell: gradient thumbnail + selection ring + filename caption.
/// Greys out and disables tap when the asset has been restored in-session.
private struct AssetTile: View {
    let asset: CairnFixtures.CandidateFixture
    let isSelected: Bool
    let isRestored: Bool
    let isExcluded: Bool
    let onTap: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    ImmichAssetThumb(assetId: asset.assetId, filename: asset.name, size: 76, isLivePair: asset.isLivePair)
                        .opacity(isRestored ? 0.45 : 1.0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(ringColor, lineWidth: isSelected ? 2 : 0)
                        )
                    if isSelected {
                        ZStack {
                            Circle().fill(t.primary).frame(width: 18, height: 18)
                            Image(systemName: "checkmark")
                                .font(.cairnScaled(size: 10, weight: .bold))
                                .foregroundStyle(t.primaryInk)
                        }
                        .padding(4)
                    } else if isRestored {
                        ZStack {
                            Circle().fill(t.verifiedSoft).frame(width: 18, height: 18)
                            Image(systemName: "arrow.uturn.backward")
                                .font(.cairnScaled(size: 9, weight: .bold))
                                .foregroundStyle(t.verifiedInk)
                        }
                        .padding(4)
                    } else if isExcluded {
                        // Discoverable "already excluded" badge —
                        // top-right shield so the user can see which
                        // tiles are in the exclusion store at a glance,
                        // without having to tap first to find out.
                        ZStack {
                            Circle().fill(t.infoSoft).frame(width: 18, height: 18)
                            Image(systemName: "shield.fill")
                                .font(.cairnScaled(size: 9, weight: .bold))
                                .foregroundStyle(t.infoInk)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
                Text(stripExtension(asset.name))
                    .font(.cairnScaled(size: 9.5, design: .monospaced))
                    .foregroundStyle(captionColor)
                    .tracking(0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestored)
        // VoiceOver: collapse the visual stack into one announceable
        // element that carries asset name + selection / restored /
        // excluded state. Without this, the badge overlay and the
        // filename caption read as separate elements with no
        // connection to the selection.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.name)
        .accessibilityValue(stateLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var stateLabel: String {
        if isRestored { return "Restored, not selectable" }
        if isExcluded { return isSelected ? "Excluded. Selected." : "Excluded" }
        return isSelected ? "Selected" : "Not selected"
    }

    private var ringColor: Color {
        isSelected ? t.primary : .clear
    }

    private var captionColor: Color {
        if isRestored { return t.verifiedInk }
        if isExcluded { return t.infoInk }
        return t.textMuted
    }

    private func stripExtension(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return s }
        return String(s[s.startIndex..<dot])
    }
}

// MARK: - Selection action bar

/// Contextual action bar shown when the user has selected ≥1 asset.
/// Mirrors `screens/run-detail.jsx::SelectionActionBar`.
///
/// Visual order (left→right): Restore is *primary* when available so the
/// hand-back-the-keys action gets the brand color; otherwise Exclude takes
/// primacy because it's the only effectful action on dry-runs / aborted runs.
private struct SelectionActionBar: View {
    let selectedCount: Int
    let pairedCount: Int
    let expandedCount: Int
    let canRestore: Bool
    /// True when every selected asset is already in the exclusion
    /// store. The action button flips to "Unexclude" so the user
    /// can reverse a mistaken exclude without leaving the sheet.
    let allSelectedExcluded: Bool
    let onClear: () -> Void
    let onExclude: () -> Void
    let onUnexclude: () -> Void
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onRestore: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(spacing: 10) {
            countRow
            actionGrid
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            t.surface.overlay(
                Rectangle().fill(t.divider).frame(height: 0.5),
                alignment: .top
            )
        )
    }

    private var countRow: some View {
        HStack(spacing: 8) {
            // Selection count pill
            Text(CairnL10n.isChinese ? "已选择 \(selectedCount) 项" : "\(selectedCount) selected")
                .font(.cairnScaled(size: 12, weight: .semibold))
                .foregroundStyle(t.primaryInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(t.primary)
                .clipShape(Capsule())

            if pairedCount > 0 {
                // Live Photo pair callout. Verbatim from the prototype:
                // "+M paired video(s) = total"
                HStack(spacing: 5) {
                    Circle().fill(t.infoInk).frame(width: 5, height: 5)
                    Text("+\(pairedCount) paired video\(pairedCount == 1 ? "" : "s") = \(expandedCount)")
                        .font(.cairnScaled(size: 11, weight: .medium))
                }
                .foregroundStyle(t.infoInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(t.infoSoft)
                .clipShape(Capsule())
            }

            Button("Clear".loc, action: onClear)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    private var actionGrid: some View {
        HStack(spacing: 6) {
            // Exclude ↔ Unexclude. When every selected asset is already
            // in the exclusion store, the label flips and the action
            // reverses. Mixed selections (some excluded, some not) fall
            // back to "Exclude" and operate on the not-yet-excluded
            // subset — the host-side `doExclude` handles the filter.
            ActionButton(
                icon: allSelectedExcluded ? "shield.slash" : "shield",
                label: allSelectedExcluded ? "Unexclude" : "Exclude",
                isPrimary: !canRestore,
                action: allSelectedExcluded ? onUnexclude : onExclude
            )
            ActionButton(icon: "link", label: "Open", isPrimary: false, action: onOpen)
            ActionButton(icon: "doc.on.doc", label: "Copy", isPrimary: false, action: onCopy)
            if canRestore {
                ActionButton(
                    icon: "arrow.uturn.backward",
                    label: "Restore",
                    isPrimary: true,
                    action: onRestore
                )
            }
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let isPrimary: Bool
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.cairnScaled(size: 18, weight: .semibold))
                Text(label.loc)
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .tracking(0.2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.bottom, 2)
            .foregroundStyle(isPrimary ? t.primaryInk : t.text)
            .background(isPrimary ? t.primary : t.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isPrimary ? Color.clear : t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meta chip

/// Small inline chip used in the run-header meta strip (run id, breadcrumb,
/// in-session restored / excluded counts). Visually quieter than the
/// status-screen `Chip` because it sits in a denser context.
private struct MetaChip: View {
    enum Tone { case neutral, verified, info }
    let label: String
    let tone: Tone
    var icon: String? = nil
    var mono: Bool = false

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.cairnScaled(size: 10, weight: .semibold))
            }
            Text(label)
                .font(.cairnScaled(size: 11, weight: .semibold, design: mono ? .monospaced : .default))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(soft)
        .clipShape(Capsule())
    }

    private var soft: Color {
        switch tone {
        case .neutral:  t.surfaceAlt
        case .verified: t.verifiedSoft
        case .info:     t.infoSoft
        }
    }
    private var ink: Color {
        switch tone {
        case .neutral:  t.textBody
        case .verified: t.verifiedInk
        case .info:     t.infoInk
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Run detail — completed trash run") {
    RunDetailSheet()
        .cairnTheme()
}

#Preview("Run detail — aborted run") {
    RunDetailSheet(
        run: CairnFixtures.runs.first(where: { $0.status == .aborted }) ?? CairnFixtures.runs[0],
        assets: Array(CairnFixtures.candidates.prefix(14))
    )
    .cairnTheme()
}

#Preview("Run detail — empty selection (dry-run)") {
    RunDetailSheet(
        run: CairnFixtures.runs.first(where: { $0.dryRun }) ?? CairnFixtures.runs[0],
        assets: Array(CairnFixtures.candidates.prefix(8))
    )
    .cairnTheme()
}

/// Drives a multi-asset selection on first appear so reviewers can see the
/// contextual action bar (with the +paired-video callout) without tapping.
private struct PreselectedRunDetail: View {
    @State private var ready = false
    var body: some View {
        ZStack {
            RunDetailSheet(
                run: CairnFixtures.runs[0],
                assets: Array(CairnFixtures.candidates.prefix(14))
            )
        }
        // The state is internal to RunDetailSheet, so this preview is
        // visually identical to the default but documents intent. The
        // multi-selection visual is driven by tapping in #Preview canvas.
        .onAppear { ready = true }
        .opacity(ready ? 1 : 1)
    }
}

#Preview("Run detail — multi selection (tap a few thumbs)") {
    PreselectedRunDetail()
        .cairnTheme()
}

#Preview("Run detail — dark") {
    RunDetailSheet()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
