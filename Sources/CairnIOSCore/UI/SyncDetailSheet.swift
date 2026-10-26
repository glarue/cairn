import SwiftUI
import CairnCore

/// Drill-down view for what's happening during a sync. Renders the
/// current phase + an elapsed timer at the top, the linear phase
/// timeline (Preparing → Fetching server → Hashing → Reconciling →
/// Finalizing) with completed durations + an in-flight indicator,
/// and a scrollable activity feed below.
///
/// **Re-render isolation.** This sheet is the **only** consumer of
/// `model.syncActivity`. Status' `syncCard` MUST NOT read
/// `syncActivity.count` or any derivative — `@Observable` would
/// re-render Status on every emit (potentially 4×/sec during
/// hashing, given the reconciler's progress throttle), competing
/// with the sync card's animations for main-thread time.
///
/// **TimelineView for elapsed.** A 0.5s `TimelineView(.periodic)`
/// drives the live elapsed-ms counter on the in-flight phase row
/// without forcing the whole view to re-eval at 60fps.
public struct SyncDetailSheet: View {
    public let phase: CairnAppModel.SyncPhase
    public let syncStartedAt: Date?
    public let isSyncing: Bool
    public let progress: (hashed: Int, total: Int)?
    public let timeline: [CairnAppModel.PhaseEntry]
    public let activity: [CairnAppModel.SyncActivity]
    /// Longest-running in-flight hash, surfaced as a sub-row under
    /// the current-phase card during the Hashing phase. `nil` outside
    /// that phase or when nothing is currently hashing.
    public let spotlightedHash: CairnAppModel.HashingItem?
    /// The user's time-format preference. Passed explicitly (not via
    /// environment) because a sheet re-applies its own theme/environment
    /// at the call site rather than inheriting the root's. Drives the
    /// phase-timeline + activity clock times so they honor 12/24-hour.
    public let timeFormat: TimeDisplayFormat
    public let onCancel: () -> Void
    public let onClose: () -> Void

    @Environment(\.cairnTokens) private var t

    public init(
        phase: CairnAppModel.SyncPhase,
        syncStartedAt: Date?,
        isSyncing: Bool,
        progress: (hashed: Int, total: Int)?,
        timeline: [CairnAppModel.PhaseEntry],
        activity: [CairnAppModel.SyncActivity],
        spotlightedHash: CairnAppModel.HashingItem? = nil,
        timeFormat: TimeDisplayFormat = .system,
        onCancel: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.phase = phase
        self.syncStartedAt = syncStartedAt
        self.isSyncing = isSyncing
        self.progress = progress
        self.timeline = timeline
        self.activity = activity
        self.spotlightedHash = spotlightedHash
        self.timeFormat = timeFormat
        self.onCancel = onCancel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    currentPhaseCard
                    KeylineSection("Phase timeline".loc)
                    timelineCard
                    KeylineSection("Activity".loc)
                    activityCard
                    if isSyncing {
                        Button(action: onCancel) {
                            Text("Cancel sync".loc)
                                .font(.cairnScaled(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(t.dangerInk)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .padding(.bottom, 22)
                    } else {
                        Spacer().frame(height: 22)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(t.bg)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer().frame(width: 60)
            Spacer()
            VStack(spacing: 1) {
                Text("Sync detail".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.text)
                Text(headerSubtitle)
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(t.textMuted)
                    .monospacedDigit()
            }
            Spacer()
            Button("Close".loc, action: onClose)
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var headerSubtitle: String {
        if isSyncing { return "in progress".loc }
        if !timeline.isEmpty { return "last sync".loc }
        return "—"
    }

    // MARK: - Current phase card

    private var currentPhaseCard: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            CairnCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isSyncing ? t.pendingInk : t.textHint)
                            .frame(width: 8, height: 8)
                        Text(phase.displayName.loc)
                            .font(.cairnScaled(size: 16, weight: .semibold))
                            .foregroundStyle(t.text)
                        Spacer(minLength: 8)
                        Text(elapsedLabel(at: context.date))
                            .font(.cairnScaled(size: 13, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                    }
                    if let progress, progress.total > 0, isSyncing && phase == .hashing {
                        progressBar(fraction: min(1.0, Double(progress.hashed) / Double(progress.total)))
                        Text("\(progress.hashed.formatted(.number)) / \(progress.total.formatted(.number)) \("hashed".loc)")
                            .font(.cairnScaled(size: 12, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                    }
                    // Spotlight row stays reserved during hashing so the
                    // card doesn't shrink-and-grow each time `spotlightedHash`
                    // flickers between assets. The row content swaps from a
                    // filename to an "idle" placeholder of the same height —
                    // no jump for UI elements below the card.
                    if isSyncing && phase == .hashing {
                        spotlightedHashRow(spotlightedHash, at: context.date)
                    }
                }
                .padding(16)
            }
        }
        .padding(.top, 12)
    }

    /// Render the longest-running in-flight hash: filename + size,
    /// elapsed (once ≥3s — quick local hashes don't need a label that
    /// flashes for 80ms), and an iCloud download bar when the
    /// resource reports progress. When `item` is nil (between hashing
    /// items, or at the start/end of the phase before iCloud bytes
    /// land), renders an "idle" placeholder of the same height so the
    /// containing card doesn't bounce.
    @ViewBuilder
    private func spotlightedHashRow(_ item: CairnAppModel.HashingItem?, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5)
                .padding(.vertical, 2)
            if let item {
                let elapsed = now.timeIntervalSince(item.startedAt)
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textHint)
                    Text(item.filename)
                        .font(.cairnScaled(size: 12, design: .monospaced))
                        .foregroundStyle(t.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if item.sizeBytes > 0 {
                        Text(byteFormatter.string(fromByteCount: item.sizeBytes))
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                    }
                }
                // Always-rendered elapsed/download line so the row's
                // height stays constant regardless of whether the
                // current hash is fast or stalled on iCloud.
                HStack(spacing: 8) {
                    if elapsed >= 3 {
                        Text("\("Elapsed".loc) \(elapsedShort(elapsed))")
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                    } else {
                        // Invisible spacer of equivalent line height so
                        // the row doesn't pop a few pixels taller at the
                        // 3-second elapsed threshold.
                        Text(" ")
                            .font(.cairnScaled(size: 11, design: .monospaced))
                    }
                    if let fraction = item.downloadFraction {
                        Spacer(minLength: 6)
                        Text("\("Downloading".loc) \(Int(fraction * 100))%")
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textMuted)
                    }
                }
                if let fraction = item.downloadFraction {
                    progressBar(fraction: fraction)
                } else {
                    // Reserve the progressBar's vertical footprint so the
                    // appearance/disappearance of iCloud-download progress
                    // doesn't bounce the card height.
                    progressBar(fraction: 0).opacity(0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textHint.opacity(0.5))
                    Text("Idle between hashes…".loc)
                        .font(.cairnScaled(size: 12, design: .monospaced))
                        .foregroundStyle(t.textMuted)
                    Spacer(minLength: 6)
                }
                Text(" ")
                    .font(.cairnScaled(size: 11, design: .monospaced))
                progressBar(fraction: 0).opacity(0)
            }
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }

    private func elapsedShort(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private func elapsedLabel(at now: Date) -> String {
        guard let started = syncStartedAt else { return "—" }
        let seconds = now.timeIntervalSince(started)
        // Whole seconds for the live elapsed clock — the prior
        // "%.1fs" precision read as noisy decimals on a number that
        // updates every half-second.
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.divider).frame(height: 4)
                Capsule().fill(t.pending).frame(width: geo.size.width * fraction, height: 4)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Timeline card

    private var timelineCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                let rows = timelineRows
                ForEach(Array(rows.enumerated()), id: \.element.phase) { idx, row in
                    timelineRow(row)
                    if idx < rows.count - 1 {
                        Rectangle()
                            .fill(t.divider)
                            .frame(height: 0.5)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }

    private struct TimelineRow {
        let phase: CairnAppModel.SyncPhase
        let durationMs: Int?
        /// Wall-clock time this phase started (nil for skipped/pending
        /// phases that never ran). Surfaced per-row so it's obvious when
        /// each step happened, not just how long it took.
        let startedAt: Date?
        let isLive: Bool
        /// True when this phase has no timeline entry AND the sync
        /// has already moved past it (or completed). Differs from
        /// "pending" (the sync hasn't reached this phase yet) — a
        /// skipped phase deserves a distinct glyph so the user
        /// doesn't read a single empty circle in the middle of a row
        /// of checkmarks as "broken."
        let isSkipped: Bool
    }

    private var timelineRows: [TimelineRow] {
        // Five user-facing rows in fixed order. `.fetchingServer` is
        // a parallel track but renders as a row so its duration
        // surfaces; the duration is captured into syncTimeline as a
        // synthetic entry from `performLiveReconciliation`.
        let order: [CairnAppModel.SyncPhase] = [
            .preparing, .fetchingServer, .hashing, .reconciling, .finalizing,
        ]
        // Phases that have already started (have a timeline entry).
        // Used to mark earlier phases without an entry as "skipped"
        // rather than just "pending."
        let startedPhases: Set<CairnAppModel.SyncPhase> = Set(timeline.map(\.phase))
        return order.enumerated().map { idx, p in
            let entry = timeline.first { $0.phase == p }
            // A row counts as skipped when the sync has visibly
            // advanced past it: either the current phase is later in
            // the canonical order, OR sync has completed and any
            // later phase has an entry. `.hashing` is the typical
            // skip (incremental sync with no new bytes to hash).
            let isPending = entry == nil
            let isLater = !isSyncing && order.dropFirst(idx + 1).contains(where: { startedPhases.contains($0) })
            let currentIdx = order.firstIndex(of: phase) ?? 0
            let isPastCurrent = isSyncing && idx < currentIdx
            return TimelineRow(
                phase: p,
                durationMs: entry?.durationMs,
                startedAt: entry?.startedAt,
                isLive: phase == p && isSyncing,
                isSkipped: isPending && (isLater || isPastCurrent)
            )
        }
    }

    private func timelineRow(_ row: TimelineRow) -> some View {
        HStack(spacing: 10) {
            timelineGlyph(for: row)
                .frame(width: 22)
            Text(row.phase.displayName)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(rowTextColor(for: row))
            // Wall-clock start time for the step — quiet, monospaced, so
            // it reads as ambient "when" without competing with the phase
            // name. Absent for skipped/pending phases that never ran.
            if let started = row.startedAt {
                Text(timeFormat.formatClockTimeWithSeconds(started))
                    .font(.cairnScaled(size: 11, design: .monospaced))
                    .foregroundStyle(t.textHint)
            }
            Spacer(minLength: 8)
            Text(rowDurationLabel(for: row))
                .font(.cairnScaled(size: 12, design: .monospaced))
                .foregroundStyle(rowDurationColor(for: row))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func timelineGlyph(for row: TimelineRow) -> some View {
        if row.isLive {
            Image(systemName: "circle.dotted.circle")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.pendingInk)
        } else if row.durationMs != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.verifiedInk)
        } else if row.isSkipped {
            // Dashed-line glyph reads as "phase wasn't applicable
            // to this sync" — typical case is `.hashing` skipped on
            // an incremental sync with no new bytes to compute.
            // Distinct from the plain empty circle which means
            // "phase pending, sync hasn't reached it yet."
            Image(systemName: "minus.circle")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.textHint)
        } else {
            Image(systemName: "circle")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.textHint)
        }
    }

    private func rowTextColor(for row: TimelineRow) -> Color {
        if row.isLive { return t.text }
        if row.durationMs != nil { return t.textBody }
        return t.textMuted
    }

    private func rowDurationLabel(for row: TimelineRow) -> String {
        if let ms = row.durationMs { return Self.formatDuration(ms: ms) }
        if row.isLive { return "live".loc }
        if row.isSkipped { return "skipped".loc }
        return "—"
    }

    private func rowDurationColor(for row: TimelineRow) -> Color {
        if row.isLive { return t.pendingInk }
        if row.durationMs != nil { return t.textMuted }
        return t.textHint
    }

    static func formatDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let secs = Double(ms) / 1000.0
        // Whole seconds for the activity-feed phase durations —
        // matches the live elapsed clock and the InitialScanScreen
        // ELAPSED format. Sub-second precision still available below
        // 1000ms via the "\(ms)ms" branch above.
        if secs < 60 { return String(format: "%.0fs", secs) }
        let m = Int(secs / 60)
        let r = Int(secs) % 60
        return "\(m)m \(r)s"
    }

    // MARK: - Activity card

    private var activityCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                if activity.isEmpty {
                    Text(isSyncing ? "Waiting for activity…".loc : "No recent activity.".loc)
                        .font(.cairnScaled(size: 12))
                        .foregroundStyle(t.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(activity.enumerated()), id: \.element.id) { idx, entry in
                        activityRow(entry)
                        if idx < activity.count - 1 {
                            Rectangle()
                                .fill(t.divider)
                                .frame(height: 0.5)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ entry: CairnAppModel.SyncActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeFormat.formatClockTimeWithSeconds(entry.timestamp))
                .font(.cairnScaled(size: 11, design: .monospaced))
                .foregroundStyle(t.textHint)
            Text(activityKindLabel(entry.kind))
                .font(.cairnScaled(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(activityKindColor(entry.kind))
                .frame(width: 56, alignment: .leading)
            Text(entry.detail)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textBody)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func activityKindLabel(_ kind: CairnAppModel.SyncActivity.Kind) -> String {
        switch kind {
        case .phaseStart: "phase".loc
        case .hashed:     "hashed".loc
        case .fetched:    "fetched".loc
        case .stamped:    "stamped".loc
        case .note:       "note".loc
        case .warning:    "warn".loc
        }
    }

    private func activityKindColor(_ kind: CairnAppModel.SyncActivity.Kind) -> Color {
        switch kind {
        case .phaseStart: t.infoInk
        case .hashed:     t.textMuted
        case .fetched:    t.infoInk
        case .stamped:    t.verifiedInk
        case .note:       t.textMuted
        case .warning:    t.pendingInk
        }
    }
}

#if DEBUG
private extension CairnAppModel.PhaseEntry {
    static func fixture(_ phase: CairnAppModel.SyncPhase, _ ms: Int?) -> CairnAppModel.PhaseEntry {
        .init(phase: phase, startedAt: Date(), durationMs: ms)
    }
}

#Preview("Sync detail — mid-sync") {
    SyncDetailSheet(
        phase: .hashing,
        syncStartedAt: Date().addingTimeInterval(-12.4),
        isSyncing: true,
        progress: (hashed: 1247, total: 6512),
        timeline: [
            .fixture(.preparing, 820),
            .fixture(.fetchingServer, 3204),
            .fixture(.hashing, nil),
        ],
        activity: [
            .init(kind: .hashed, detail: "1,247 / 6,512 hashed"),
            .init(kind: .hashed, detail: "1,200 / 6,512 hashed"),
            .init(kind: .fetched, detail: "1,000 server assets · 3,204ms"),
            .init(kind: .note, detail: "fetchPersistentChanges · 12ms"),
            .init(kind: .note, detail: "Sync started"),
        ]
    )
    .cairnTheme()
}

#Preview("Sync detail — idle") {
    SyncDetailSheet(
        phase: .idle,
        syncStartedAt: nil,
        isSyncing: false,
        progress: nil,
        timeline: [],
        activity: []
    )
    .cairnTheme()
}

#Preview("Sync detail — completed") {
    SyncDetailSheet(
        phase: .idle,
        syncStartedAt: Date().addingTimeInterval(-18.2),
        isSyncing: false,
        progress: nil,
        timeline: [
            .fixture(.preparing, 820),
            .fixture(.fetchingServer, 3204),
            .fixture(.hashing, 12410),
            .fixture(.reconciling, 1240),
            .fixture(.finalizing, 320),
        ],
        activity: [
            .init(kind: .stamped, detail: "engine: delete=3 pending=1 held=0"),
            .init(kind: .note, detail: "orphanSweep · 240ms"),
            .init(kind: .hashed, detail: "6,512 / 6,512 hashed"),
            .init(kind: .fetched, detail: "1,000 server assets · 3,204ms"),
        ]
    )
    .cairnTheme()
}

#Preview("Sync detail — dark") {
    SyncDetailSheet(
        phase: .reconciling,
        syncStartedAt: Date().addingTimeInterval(-4.2),
        isSyncing: true,
        progress: nil,
        timeline: [
            .fixture(.preparing, 820),
            .fixture(.fetchingServer, 3204),
            .fixture(.hashing, 12410),
            .fixture(.reconciling, nil),
        ],
        activity: [
            .init(kind: .hashed, detail: "6,512 / 6,512 hashed"),
            .init(kind: .fetched, detail: "1,000 server assets · 3,204ms"),
        ]
    )
    .preferredColorScheme(.dark)
    .cairnTheme()
}
#endif
