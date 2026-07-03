import SwiftUI
import os
#if canImport(UIKit)
import UIKit  // NSString text measurement for pre-sizing the journal-tail rows.
#endif

/// The default landing screen. Mirrors the prototype's `screens/status.jsx`.
///
/// Surfaces (top-to-bottom):
///   1. Wordmark + status chip ("synced" / "offline" / "limited" / etc.)
///   2. Subhead: "reconciling iPhone 15 Pro against <server>"
///   3. Optional degraded banner (server down / auth stale / Photos limited / tiny library)
///   4. Optional state banner (threshold tripped / first-sync dry-run nudge)
///   5. Pending-candidates card with the primary "Review & sync" CTA
///   6. Library snapshot — three stats (on iPhone, indexed, on server)
///   7. Recent runs — compact timeline (4 most recent + "see all")
///   8. Latest journal — monospace tail
///
/// State model:
///   - `appState`: steady (default) | dryRun (first-sync nudge) | thresholdTripped
///   - `degraded`: none | serverDown | authStale | photosLimited | tinyLibrary
///   These are orthogonal — degraded preempts the CTA, appState colors banners.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md "Keep these
/// copies verbatim" — don't paraphrase without designer review.
public struct StatusScreen: View {

    public enum AppState: Sendable {
        case steady
        case dryRun
        case thresholdTripped
    }

    public enum Degraded: Sendable {
        case none
        case serverDown
        case authStale
        case photosLimited
        case tinyLibrary
        /// Set when an `/sync/*` request returns 401 while a session
        /// token was in use — the token has been revoked (admin
        /// action) or the server's session store was wiped. Cairn
        /// auto-clears the local token and falls back to the
        /// paginated discovery path; the banner prompts the user to
        /// sign back in to restore incremental sync.
        case sessionExpired
    }

    public let appState: AppState
    public let degraded: Degraded
    public let library: CairnFixtures.LibrarySize
    public let runs: [CairnFixtures.RunFixture]
    public let journalTail: [CairnFixtures.JournalTailEntry]
    public let serverHost: String
    public let maxDeletePercent: Double
    /// Minimum candidate count before the percent-threshold rail
    /// engages. Surfaced on the sync card as the "(≥N items)" qualifier
    /// next to the percent cap so the user sees both gates together.
    public let minDeleteFloor: Int
    /// Total count of candidates awaiting the user's call (held +
    /// unconfirmed). When > 0 the screen surfaces a compact pending-review
    /// card directly below the sync card.
    public let pendingReviewCount: Int
    /// Items confirmed-deleted but still within the quarantine window.
    /// Shown as a secondary line under the big number.
    public let quarantineCount: Int
    /// Earliest date a quarantined item becomes eligible, if any.
    /// Drives the "earliest eligible in N days" annotation.
    public let earliestQuarantineEligible: Date?
    /// Sum of every bucket awaiting user action (held-by-quarantine +
    /// pending-review + eligible-to-trash candidates). Drives the
    /// backlog-alert banner when it crosses
    /// `backlogAlertThreshold`.
    public let deletionBacklog: Int
    /// Count threshold above which the backlog banner appears. 0
    /// disables the banner entirely.
    public let backlogAlertThreshold: Int
    /// Optional transient toast (e.g. "Library up to date") surfaced as
    /// a Callout above the sync card after a no-op sync. Host is
    /// responsible for clearing after the auto-dismiss window.
    public let syncToast: CairnAppModel.SyncToast?
    /// Number of locally-restored photos that were previously trashed
    /// via cairn within Immich's 30-day hard-delete window. Drives a
    /// warn-tone banner so the user knows to restore on Immich too —
    /// the Immich mobile app silently no-ops the upload while the
    /// asset is in Immich trash with the same SHA1.
    public let restoredAfterCairnTrashCount: Int
    /// User dismissed the "restored after trash" banner. Host clears
    /// `model.restoredAfterCairnTrash` to make this fire — next sync
    /// re-evaluates, so if the conditions still hold, the banner returns.
    public let onDismissRestoredAfterCairnTrash: () -> Void
    /// Number of inferred orphans from the most recent scan — server
    /// assets matched by filename + creationDate against locally-
    /// observed metadata where cairn never finished hashing the asset
    /// (typically the cull-burst case: take a photo, Immich uploads,
    /// user deletes within seconds). Drives a warn-tone banner that
    /// routes the user to Pending Review.
    public let inferredOrphanCount: Int
    /// Tap handler for the orphan banner. Routes to Pending Review.
    public let onOpenInferredOrphans: () -> Void
    /// When true, the user dismissed the initial-scan screen and the
    /// library hasn't been indexed yet. Surfaces a persistent callout
    /// prompting the user to begin or resume the scan.
    public let initialScanPending: Bool
    /// Handler for the "Begin initial scan" affordance on that banner.
    public let onResumeInitialScan: () -> Void
    /// Current deferred-hash queue summary. When `count > 0` Status
    /// surfaces a banner with a "Hash now" affordance so the user
    /// doesn't have to dig into Settings to clear the queue.
    public let deferredQueue: CairnAppModel.DeferredQueueSummary
    public let onForceDrainDeferred: () -> Void
    /// Number of trash intents in the persistent retry queue —
    /// confirmTrash calls that failed (server unreachable, 5xx,
    /// transient) and are awaiting a successful retry. Drives the
    /// pending-trash banner. The drain runs automatically on every
    /// successful sync; the user can also manually retry from the
    /// banner.
    public let pendingTrashCount: Int
    /// Subset of `pendingTrashCount` that has hit `maxRetryAttempts`
    /// and is no longer being auto-drained. Surfaces a separate
    /// danger-tone banner with a route to the failed-attempts sheet.
    public let pendingTrashStuckCount: Int
    /// Manual "Retry now" — drains the pending-trash queue
    /// regardless of attempt cap.
    public let onRetryPendingTrashes: () -> Void
    /// True while the "Retry now" drain is in flight — swaps the button
    /// for a spinner and disables re-taps.
    public let isRetryingPendingTrashes: Bool
    /// Tap handler on the stuck banner — opens the
    /// PendingTrashesSheet detail view.
    public let onOpenPendingTrashes: () -> Void
    /// Action wired to the "Retry" button in the
    /// `Immich server unreachable` banner. Re-pings the configured
    /// server and refreshes `connectionStatus` + `degraded` based on
    /// the result.
    public let onRetryConnection: () -> Void
    /// True while `actions.requestSync` is mid-flight. Drives spinner +
    /// disabled state on the CTA so taps don't feel dead.
    public let isSyncing: Bool
    /// Optional hashing progress, surfaced in the CTA label when the
    /// full-enumeration path is running ("Hashing 1,245 / 4,218").
    public let syncProgress: (hashed: Int, total: Int)?
    /// When the last reconciliation ran. Surfaces as "Last checked N ago"
    /// so stale data has context.
    public let lastCheckedAt: Date?
    /// Required API permissions the key is missing. Empty = all good.
    public let missingPermissions: [String]
    /// Live indexed count (checksums in the hash store).
    public let indexed: Int
    public let syncPhase: CairnAppModel.SyncPhase
    /// Live server-fetch progress, shown during `.fetchingServer` so the
    /// (often multi-minute) paginated fetch isn't a frozen "Processing
    /// N/N" card. `serverAssetsExpected` is nil until the statistics probe
    /// lands; the label/bar degrade to a plain count when it's unknown.
    public let serverAssetsFetched: Int
    public let serverAssetsExpected: Int?
    public let onStartSync: () -> Void
    /// Pull-to-refresh handler. Returns when the sync triggered by the
    /// gesture has finished (success, error, or cancel) so SwiftUI's
    /// refresh control dismisses at the right moment. Distinct from
    /// `onStartSync` — that one is fire-and-forget for the Sync button;
    /// `.refreshable` requires an awaitable completion.
    public let onRefreshSync: () async -> Void
    public let onCancelSync: () -> Void
    public let onOpenRun: (CairnFixtures.RunFixture) -> Void
    /// Tapping a journal-tail row whose `runId` matches a real run
    /// opens the run-detail sheet. The host (CairnAppRoot) maps
    /// `runId → RunFixture` and routes through `presentRunDetail`.
    /// Rows with no matching run are rendered the same but
    /// non-tappable.
    public let onJournalRowTap: (String) -> Void
    public let onSeeAllRuns: () -> Void
    public let onOpenPendingReview: () -> Void
    /// Tapping the big "ready to trash" number opens a read-only view of
    /// the current delete queue (DryRunSheet with cached reconciliation).
    public let onOpenDeleteQueue: () -> Void
    /// Tapping the deferred queue line opens the queue detail sheet.
    public let onOpenDeferredQueue: () -> Void
    /// Tap target on the syncCard's "Show details" affordance — only
    /// shown while `isSyncing == true`. Opens `SyncDetailSheet` with
    /// the live phase timeline + activity feed. Constraint: this is
    /// the **only** way the activity feed surfaces in UI; Status'
    /// syncCard MUST NOT read `model.syncActivity` or derivatives,
    /// or `@Observable` would re-render Status on every emit.
    public let onOpenSyncDetail: () -> Void
    /// `true` when `model.syncTimeline` has entries from a completed
    /// sync this session — i.e., the SyncDetailSheet has something
    /// to render even when no sync is currently in flight. Drives the
    /// post-sync "Last sync details" entry on the sync card.
    public let hasLastSyncDetails: Bool
    /// Tapped by the `Degraded.sessionExpired` banner's "Sign in
    /// again" button. Host opens the session sign-in sheet; sheet
    /// dismissal on success flips `degraded` back to `.none`.
    public let onResumeSession: () -> Void
    /// Token incremented by the host when the user re-taps the active
    /// tab — see `CairnTabBar.onReselect`. Each increment scrolls the
    /// screen back to the top.
    public let scrollResetToken: Int

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var journalExpanded: Bool = false
    /// IDs of collapsed sync-run bundles the user has expanded inline.
    /// A bundle ID is the concatenated runIds of its contained groups
    /// (see `collapseSyncBundles`). Persists for the lifetime of the
    /// view — re-collapses on tab switch / scroll-reset.
    @State private var expandedSyncBundles: Set<String> = []
    /// Long-press on a journal row stashes its entry here; the sheet
    /// is presented while the value is non-nil. Pretty-printed JSON
    /// of the underlying `JournalEntry` is in `entry.rawJSON`.
    @State private var journalRunDetailContext: JournalRunDetailContext? = nil
    /// Set true the moment the user taps Cancel during sync. The
    /// underlying cancellation can take a moment (orchestrators
    /// finish the current step before honoring it), so the UI
    /// immediately switches to a "Cancelling…" affordance with a
    /// spinner — the user sees their tap registered without
    /// waiting for `isSyncing` to flip false. Reset back to false
    /// on the next isSyncing transition (in either direction).
    @State private var cancelRequested: Bool = false
    /// Lagging mirror of `isSyncing` used to fade the
    /// SyncPhaseChecklist content in *after* the syncCard's layout
    /// has finished growing to accommodate it. Mounting the
    /// checklist with opacity = 0 from the moment isSyncing flips
    /// reserves its layout space immediately (so the card grows in
    /// one cairnSpring beat), and the content then crossfades in
    /// without competing for frames against the layout pass —
    /// previously they ran simultaneously and the user saw stutter.
    @State private var checklistVisible: Bool = false
    // SyncChecklistAnimator owns its own animation state — see the
    // dedicated subview struct in this file. StatusScreen just passes
    // `isSyncing`, `checklistVisible`, and `syncPhase` as props.
    /// Filter chip on the journal-tail card. ON by default — routine
    /// no-op syncs are noise. `@AppStorage` so the user's choice
    /// survives tab navigation and relaunch.
    @AppStorage("cairn.status.hideRoutineSyncs")
    private var hideRoutineSyncs: Bool = true
    /// Latches the count at which the user dismissed the banner so
    /// it doesn't re-show until the underlying state *changes* (more
    /// items accrue, or some get cleared). `@AppStorage` persists
    /// the value to UserDefaults, which survives view re-creation
    /// (tab navigation, background/foreground) and app relaunch —
    /// so a deliberate dismissal isn't un-dismissed by just coming
    /// back to the screen. Sentinel value `-1` means "never
    /// dismissed"; real counts are always >= 0, so `stored == count`
    /// cleanly tests "dismissed at this exact value".
    @AppStorage("cairn.status.dismissedBacklogAtCount")
    private var dismissedBacklogAtCount: Int = -1

    public init(
        appState: AppState = .steady,
        degraded: Degraded = .none,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        journalTail: [CairnFixtures.JournalTailEntry] = CairnFixtures.journalTail,
        serverHost: String = "immich.home.arpa",
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        pendingReviewCount: Int = 0,
        quarantineCount: Int = 0,
        earliestQuarantineEligible: Date? = nil,
        deletionBacklog: Int = 0,
        backlogAlertThreshold: Int = 25,
        syncToast: CairnAppModel.SyncToast? = nil,
        restoredAfterCairnTrashCount: Int = 0,
        onDismissRestoredAfterCairnTrash: @escaping () -> Void = {},
        inferredOrphanCount: Int = 0,
        onOpenInferredOrphans: @escaping () -> Void = {},
        initialScanPending: Bool = false,
        isSyncing: Bool = false,
        syncProgress: (hashed: Int, total: Int)? = nil,
        lastCheckedAt: Date? = nil,
        missingPermissions: [String] = [],
        indexed: Int = 0,
        syncPhase: CairnAppModel.SyncPhase = .idle,
        serverAssetsFetched: Int = 0,
        serverAssetsExpected: Int? = nil,
        onStartSync: @escaping () -> Void = {},
        onRefreshSync: @escaping () async -> Void = {},
        onCancelSync: @escaping () -> Void = {},
        onOpenRun: @escaping (CairnFixtures.RunFixture) -> Void = { _ in },
        onJournalRowTap: @escaping (String) -> Void = { _ in },
        onSeeAllRuns: @escaping () -> Void = {},
        onOpenPendingReview: @escaping () -> Void = {},
        onOpenDeleteQueue: @escaping () -> Void = {},
        onOpenDeferredQueue: @escaping () -> Void = {},
        onResumeInitialScan: @escaping () -> Void = {},
        deferredQueue: CairnAppModel.DeferredQueueSummary = .empty,
        onForceDrainDeferred: @escaping () -> Void = {},
        pendingTrashCount: Int = 0,
        pendingTrashStuckCount: Int = 0,
        onRetryPendingTrashes: @escaping () -> Void = {},
        isRetryingPendingTrashes: Bool = false,
        onOpenPendingTrashes: @escaping () -> Void = {},
        onRetryConnection: @escaping () -> Void = {},
        onOpenSyncDetail: @escaping () -> Void = {},
        hasLastSyncDetails: Bool = false,
        onResumeSession: @escaping () -> Void = {},
        scrollResetToken: Int = 0
    ) {
        self.appState = appState
        self.degraded = degraded
        self.library = library
        self.runs = runs
        self.journalTail = journalTail
        self.serverHost = serverHost
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.pendingReviewCount = pendingReviewCount
        self.quarantineCount = quarantineCount
        self.earliestQuarantineEligible = earliestQuarantineEligible
        self.deletionBacklog = deletionBacklog
        self.backlogAlertThreshold = backlogAlertThreshold
        self.syncToast = syncToast
        self.restoredAfterCairnTrashCount = restoredAfterCairnTrashCount
        self.onDismissRestoredAfterCairnTrash = onDismissRestoredAfterCairnTrash
        self.inferredOrphanCount = inferredOrphanCount
        self.onOpenInferredOrphans = onOpenInferredOrphans
        self.initialScanPending = initialScanPending
        self.isSyncing = isSyncing
        self.syncProgress = syncProgress
        self.lastCheckedAt = lastCheckedAt
        self.missingPermissions = missingPermissions
        self.indexed = indexed
        self.syncPhase = syncPhase
        self.serverAssetsFetched = serverAssetsFetched
        self.serverAssetsExpected = serverAssetsExpected
        self.onStartSync = onStartSync
        self.onRefreshSync = onRefreshSync
        self.onCancelSync = onCancelSync
        self.onOpenRun = onOpenRun
        self.onJournalRowTap = onJournalRowTap
        self.onSeeAllRuns = onSeeAllRuns
        self.onOpenPendingReview = onOpenPendingReview
        self.onOpenDeleteQueue = onOpenDeleteQueue
        self.onOpenDeferredQueue = onOpenDeferredQueue
        self.onResumeInitialScan = onResumeInitialScan
        self.deferredQueue = deferredQueue
        self.onForceDrainDeferred = onForceDrainDeferred
        self.pendingTrashCount = pendingTrashCount
        self.pendingTrashStuckCount = pendingTrashStuckCount
        self.onRetryPendingTrashes = onRetryPendingTrashes
        self.isRetryingPendingTrashes = isRetryingPendingTrashes
        self.onOpenPendingTrashes = onOpenPendingTrashes
        self.onRetryConnection = onRetryConnection
        self.onOpenSyncDetail = onOpenSyncDetail
        self.hasLastSyncDetails = hasLastSyncDetails
        self.onResumeSession = onResumeSession
        self.scrollResetToken = scrollResetToken
    }

    private var pct: Double {
        guard library.matched > 0 else { return 0 }
        return (Double(library.candidates) / Double(library.matched)) * 100
    }
    private var withinBudget: Bool { pct <= maxDeletePercent }
    private var syncBlocked: Bool {
        switch degraded {
        case .serverDown, .authStale, .photosLimited: return true
        case .none, .tinyLibrary, .sessionExpired: return false
        }
    }

    /// Compound value whose changes trigger the banner-area spring
    /// animation. Every boolean below maps to one banner's
    /// visibility gate. When any flips, SwiftUI re-layouts the
    /// enclosing VStack and the paired `.transition` on each
    /// banner plays in-spring.
    private var bannerVisibilityKey: [Bool] {
        [
            degraded != .none,
            appState != .steady,
            initialScanPending,
            backlogAlertThreshold > 0 && deletionBacklog >= backlogAlertThreshold && !initialScanPending && dismissedBacklogAtCount != deletionBacklog,
            syncToast != nil,
            restoredAfterCairnTrashCount > 0,
            inferredOrphanCount > 0,
            pendingTrashCount > 0,
            pendingTrashStuckCount > 0,
        ]
        // isSyncing intentionally NOT in this key — the syncCard's
        // appear/collapse uses a separate `.animation(.smooth, value:
        // isSyncing)` modifier on the outer body so we can use a
        // critically-damped (no-overshoot) curve. cairnSpring's slight
        // overshoot was reading as "stutter" on the thin horizontal
        // separator below the syncCard — the line visibly moved down
        // past target, then settled back ~10%. The .smooth curve
        // eliminates the bounce-back so the line moves monotonically
        // down and stops. Banner appearances/disappearances still use
        // cairnSpring (kept springy), since `withAnimation(.cairnSpring)`
        // wraps the syncToast clear explicitly.
    }

    /// One-line "what just happened" sentence above the journal card.
    /// Picks the most recent `.ok` or `.error` row in `journalTail`
    /// (so routine `sync`/`tag.apply` info events don't dominate) and
    /// renders its event + message inline. Hidden when no qualifying
    /// row exists in the buffer. Tappable to open run detail when the
    /// row's runId resolves to a known run, mirroring journal-row taps.
    private var journalHeroLine: some View {
        // `journalTail` is newest-first (see AppDependencies builder).
        // Finding `first(where:)` yields the most recent row of the
        // requested severity.
        let hero = journalTail.first { $0.severity == .ok || $0.severity == .error }
        let runIds = Set(runs.map(\.id))
        return Group {
            if let hero {
                Button {
                    if runIds.contains(hero.runId) { onJournalRowTap(hero.runId) }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hero.severity == .error ? t.dangerInk : t.verifiedInk)
                            .frame(width: 6, height: 6)
                        Text(hero.event)
                            .font(.cairnScaled(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(eventColor(hero.event))
                        Text("·")
                            .font(.cairnScaled(size: 12.5))
                            .foregroundStyle(t.textHint)
                        Text(hero.message)
                            .font(.cairnScaled(size: 12.5))
                            .foregroundStyle(t.textBody)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(hero.time)
                            .font(.cairnScaled(size: 11.5, design: .monospaced))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(runIds.contains(hero.runId))
            }
        }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.scrollTopAnchor)
                    wordmarkHeader
                    degradedBanner
                    missingPermissionsBanner
                    stateBanner
                    initialScanPendingBanner
                    restoredAfterCairnTrashBanner
                    inferredOrphanBanner
                    pendingTrashBanner
                    backlogAlertBanner
                    syncToastBanner
                    syncCard
                    KeylineSection("Library")
                    libraryStats
                    KeylineSection("Recent runs")
                    recentRuns
                    KeylineSection("Latest journal")
                    journalHeroLine
                    journalTailCard
                    Spacer(minLength: 24)
                }
                // Canonical spring timing shared across the app —
                // see `cairnBannerAnimation(value:)` in
                // CairnPrimitives.swift. Without this, the
                // `.transition(.cairnBanner)` modifiers on individual
                // banners are no-ops (SwiftUI only plays transitions
                // inside an animated context).
                .cairnBannerAnimation(value: bannerVisibilityKey)
                // No body-level layout animation — the syncCard's
                // checklist height is driven by a TimelineView at
                // 60fps via spring physics, so SwiftUI's animation
                // engine never touches it.
            }
            .onChange(of: scrollResetToken) { _, _ in
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                }
            }
            .refreshable {
                // Pull-to-refresh on the Status screen triggers a sync
                // and awaits its completion so SwiftUI dismisses the
                // refresh control at the right moment. The sync card
                // still drives the visible progress UI (checklist,
                // ProgressBar, etc.); the refresh spinner is just the
                // gesture acknowledgment.
                await onRefreshSync()
            }
        }
        .background(t.bg)
        .sheet(item: $journalRunDetailContext) { context in
            JournalRunDetailSheet(context: context)
        }
        .onChange(of: isSyncing) { _, syncing in
            // Reset the "Cancelling…" affordance whenever sync state
            // flips — true → false means cancellation completed, and
            // false → true means a new sync started. Either way the
            // local UI state should reset to idle.
            cancelRequested = false

            // Stage the checklist content visibility relative to the
            // layout shift. On appear: card grows first (cairnSpring,
            // ~500ms); checklist content fades in after a short delay
            // so the two phases don't compete for the same frames.
            // On collapse: content fades immediately, layout shrinks
            // afterward (the if-isSyncing guard removes the checklist
            // from the layout once it's gone).
            if syncing {
                // The SyncChecklistAnimator's onChange watches
                // `isAnimating` and kicks off the height animation
                // internally. StatusScreen is only responsible for
                // staging the checklist's content opacity flip with
                // a small delay so the layout grow visibly begins
                // before content starts fading in.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    if isSyncing {
                        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.14)) {
                            checklistVisible = true
                        }
                    }
                }
            } else {
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.14)) {
                    checklistVisible = false
                }
            }
        }
    }

    // MARK: - Header

    private var wordmarkHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CairnWordmark(size: 28, variant: .adaptive)
                Spacer()
                statusChip
            }
            Text(reconcilingSubhead)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, CairnLayout.brandHeaderTopPadding)
        .padding(.bottom, 18)
    }

    private var reconcilingSubhead: AttributedString {
        var s = AttributedString("reconciling ")
        s.foregroundColor = t.textMuted
        var device = AttributedString("iPhone 15 Pro")
        device.foregroundColor = t.textBody
        var middle = AttributedString(" against ")
        middle.foregroundColor = t.textMuted
        var host = AttributedString(serverHost)
        // `quiet` (Air Force Blue) instead of `textHint` — the
        // server hostname is the one element in the subhead that's
        // semantically "remote/networked", and the cool blue-gray
        // makes it visually distinct from the local-device prose.
        host.foregroundColor = t.quiet
        host.font = .system(size: 12, design: .monospaced)
        return s + device + middle + host
    }

    private var statusChip: some View {
        let (label, tone): (String, ChipTone) = {
            switch degraded {
            case .none:           return ("synced", .verified)
            case .serverDown:     return ("offline", .danger)
            case .authStale:      return ("auth expired", .danger)
            case .photosLimited:  return ("limited", .danger)
            case .tinyLibrary:    return ("small library", .info)
            case .sessionExpired: return ("signed out of immich", .pending)
            }
        }()
        return Chip(label: label, tone: tone)
    }

    // MARK: - Banners

    /// Alias to the module-wide `.cairnBanner` transition. Kept as a
    /// per-instance computed property so the call sites below don't
    /// have to change — `bannerTransition` is used in ~6 places in
    /// this file and swapping to `.cairnBanner` at each was noisier
    /// than keeping the shim.
    private var bannerTransition: AnyTransition { .cairnBanner }

    @ViewBuilder
    private var missingPermissionsBanner: some View {
        Group { if !missingPermissions.isEmpty {
            Callout(.pending, icon: "exclamationmark.shield") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key missing permissions").fontWeight(.semibold)
                    Text("Required: \(missingPermissions.joined(separator: ", ")). Update your key in Immich to include these scopes.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        } }
    }

    private var degradedBanner: some View {
        Group { switch degraded {
        case .none: EmptyView()
        case .serverDown:
            Callout(.danger, icon: "server.rack") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Immich server unreachable").fontWeight(.semibold)
                    (Text("Tried ") + Text(serverHost).font(.cairnScaled(size: 12, design: .monospaced)) + Text(" three times over 2m. Check VPN or server health, then retry."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    Button(action: onRetryConnection) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.cairnScaled(size: 12, weight: .semibold))
                            Text("Retry connection")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(t.dangerInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(t.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(CairnPressStyle())
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .authStale:
            Callout(.pending, icon: "key") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key rejected").fontWeight(.semibold)
                    Text("Server returned 401. Your key may have been revoked or expired. Paste a new one in Settings.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .photosLimited:
            Callout(.pending, icon: "photo.on.rectangle.angled") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photos access is Limited").fontWeight(.semibold)
                    (Text("With Limited access, ") + .cairnWord + Text(" only sees the assets you picked. Everything else looks “missing” and would be flagged for deletion — dangerous. Grant Full access to continue."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .tinyLibrary:
            Callout(.pending, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library is small").fontWeight(.semibold)
                    Text("Your iPhone has a small photo library. With fewer than ~200 assets, any single deletion is a large fraction of the library and the percent-based safety rail can't protect you as well. You can still sync — just treat the first run carefully.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .sessionExpired:
            Callout(.pending, icon: "person.crop.circle.badge.xmark") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signed out of Immich").fontWeight(.semibold)
                    Text("Your Immich session was ended — likely from another device or the Immich web settings. Incremental sync has fallen back to the slower path; sign in again to restore it. Everything else keeps working.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    Button(action: onResumeSession) {
                        Text("Sign in again")
                            .font(.cairnScaled(size: 13, weight: .semibold))
                            .foregroundStyle(t.primaryInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 36)
                            .background(t.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sign in again to restore incremental sync")
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        } }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch appState {
        case .thresholdTripped:
            let tripCount = max(6, Int(Double(library.matched) * 0.023))
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safety rail tripped").fontWeight(.semibold)
                    (Text("Last run would have trashed ") + Text("\(tripCount) assets").bold() + Text(" (") + Text("2.3%").bold() + Text(" of matched), above your ") + Text(String(format: "%.1f%%", maxDeletePercent)).bold() + Text(" cap. Review before re-running."))
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .dryRun:
            Callout(.info, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First sync is a dry-run").fontWeight(.semibold)
                    Text("We'll show exactly what would be trashed. Nothing gets touched on your server until you confirm.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        case .steady:
            EmptyView()
        }
    }

    @ViewBuilder
    private var initialScanPendingBanner: some View {
        if initialScanPending {
            Button(action: onResumeInitialScan) {
                Callout(.pending, icon: "sparkle.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Initial scan pending").fontWeight(.semibold)
                        (Text("Tap to index your library. ")
                            + .cairnWord
                            + Text(" needs a one-time SHA1 pass before it can tell real deletions apart from sync hiccups."))
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    /// Escalation banner for a large accumulated backlog of confirmed
    /// deletions + pending-review items. Gated by the user's
    /// configurable threshold (0 disables). The pending-candidates
    /// card already surfaces the raw count; this banner adds a
    /// louder "you've let a lot pile up" signal for users who open
    /// cairn infrequently. Tapping routes to the most relevant
    /// destination: Pending Review if there's anything to review,
    /// otherwise it opens the dry-run sheet for eligible-to-trash
    /// candidates.
    @ViewBuilder
    private var backlogAlertBanner: some View {
        if backlogAlertThreshold > 0
            && deletionBacklog >= backlogAlertThreshold
            && !initialScanPending
            && dismissedBacklogAtCount != deletionBacklog {
            Button(action: backlogTapTarget) {
                Callout(.pending, icon: "bell.badge") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(deletionBacklog) deletions waiting").fontWeight(.semibold)
                        Text("Since your last trash run. Tap to review, or swipe to dismiss.")
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .cairnSwipeToDismiss {
                dismissedBacklogAtCount = deletionBacklog
            }
            .transition(bannerTransition)
        }
    }

    /// Warning banner for "user restored locally what cairn already
    /// trashed on Immich." The Immich mobile app silently no-ops the
    /// re-upload while the asset is still in Immich trash with the
    /// same SHA1; after the 30-day hard-delete clock fires, the photo
    /// is gone server-side. Surfacing the count gives the user a
    /// chance to restore on Immich too. Dismissible — next sync
    /// re-evaluates.
    @ViewBuilder
    private var restoredAfterCairnTrashBanner: some View {
        if restoredAfterCairnTrashCount > 0 {
            Callout(.pending, icon: "arrow.uturn.backward.circle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(restoredAfterCairnTrashTitle).fontWeight(.semibold)
                    Text("Open Immich → Trash to restore them there too. They'll hard-delete after 30 days.")
                        .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .cairnSwipeToDismiss { onDismissRestoredAfterCairnTrash() }
            .transition(bannerTransition)
        }
    }

    /// Title text for the restored-after-trash banner, with proper
    /// singular/plural handling. "1 photo" reads better than "1 photos."
    private var restoredAfterCairnTrashTitle: String {
        let n = restoredAfterCairnTrashCount
        let noun = n == 1 ? "photo" : "photos"
        return "\(n) restored \(noun) also trashed in Immich"
    }

    /// Pending-trash retry banner. Two states share one view:
    ///
    /// - **Stuck** (`pendingTrashStuckCount > 0`): danger tone. The
    ///   queue contains intents that have hit `maxRetryAttempts` and
    ///   the auto-drain has parked them. Tap routes to the failed-
    ///   attempts sheet so the user can see the per-intent error
    ///   and decide what to do (retry, exclude, or fix the
    ///   underlying issue like a wrong API key).
    /// - **Pending** (`pendingTrashCount > 0`, none stuck): warn tone.
    ///   The queue is non-empty but every intent is still under the
    ///   cap; the next sync will retry automatically. The "Retry
    ///   now" button forces an immediate drain — useful when the
    ///   user knows the network just came back and doesn't want to
    ///   wait for the next idle sync.
    ///
    /// Not dismissible — the underlying state is real pending work,
    /// and the count moves down naturally as drains succeed.
    @ViewBuilder
    private var pendingTrashBanner: some View {
        if pendingTrashStuckCount > 0 {
            Button(action: onOpenPendingTrashes) {
                Callout(.danger, icon: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pendingTrashStuckCount) trash \(pendingTrashStuckCount == 1 ? "request" : "requests") stuck")
                            .fontWeight(.semibold)
                        Text("Hit the retry limit. Tap to see what failed.")
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        } else if pendingTrashCount > 0 {
            Callout(.pending, icon: "arrow.clockwise") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pendingTrashCount) trash \(pendingTrashCount == 1 ? "request" : "requests") queued")
                            .fontWeight(.semibold)
                        Text("Will retry on next sync.")
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(action: onRetryPendingTrashes) {
                        if isRetryingPendingTrashes {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Retry now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRetryingPendingTrashes)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    /// Warn-tone banner for inferred orphans — server assets matched by
    /// filename + creationDate where cairn observed but never finished
    /// hashing the asset (typical cull-burst: photo taken, Immich
    /// uploads, user deletes within seconds). Tapping routes to Pending
    /// Review where the user can approve or exclude each. Not
    /// dismissible: dismissing wouldn't clear the underlying state, and
    /// the count moves down naturally as the user reviews.
    @ViewBuilder
    private var inferredOrphanBanner: some View {
        if inferredOrphanCount > 0 {
            Button(action: onOpenInferredOrphans) {
                Callout(.pending, icon: "questionmark.diamond") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inferredOrphanTitle).fontWeight(.semibold)
                        (Text("Uploaded from this iPhone, then deleted before ") + .cairnWord + Text(" could index. Review before trashing."))
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    private var inferredOrphanTitle: String {
        let n = inferredOrphanCount
        let noun = n == 1 ? "likely orphan" : "likely orphans"
        return "\(n) \(noun) on Immich"
    }

    /// Smart routing for the backlog banner: pending review first,
    /// else the dry-run sheet for eligible-to-trash candidates.
    private func backlogTapTarget() {
        if pendingReviewCount > 0 {
            onOpenPendingReview()
        } else {
            onStartSync()
        }
    }

    /// Surfaces the deferred-hash queue on Status when it's non-empty,
    /// with a "Hash now" button that runs the unlimited-drain path.
    /// Without this, the queue is only visible in Settings — users
    /// land on Status after an initial scan, see the same "Indexed"
    /// number across repeated syncs, and wonder why it's stuck.
    ///
    /// Suppressed while `initialScanPending`: an aborted earlier scan
    /// can leave orphan deferred rows on disk, and showing both the
    /// "Initial scan pending" banner AND a "queued for background
    /// hashing" banner reads as contradictory. Once the user runs
    /// Body text for the `upToDate` toast. Differentiates the
    /// `indexed < total` reasons so the user isn't told "the rest will
    /// catch up" when some of "the rest" are permanently above the
    /// size ceiling and won't catch up. Categories surfaced:
    ///   - queued: in the deferred queue, under-ceiling → real
    ///     background-hash backlog
    ///   - above-cap: in the deferred queue, exceeds the user's iCloud
    ///     download ceiling → permanent unless the cap is raised
    ///   - untracked: visible in the library but neither indexed nor
    ///     in the queue → coverage gap, can't say what'll happen
    private func upToDateSubline(indexed: Int, total: Int) -> Text {
        let count = Text("\(indexed) of \(total)").bold()
        if indexed >= total {
            return Text("Nothing new to trash. ") + count + Text(" assets indexed.")
        }
        let gap = max(0, total - indexed)
        let queued = deferredQueue.count
        let aboveCap = deferredQueue.aboveCeiling
        let untracked = max(0, gap - queued - aboveCap)

        var clauses: [String] = []
        if queued > 0 { clauses.append("\(queued) queued for background hashing") }
        if aboveCap > 0 { clauses.append("\(aboveCap) above your size cap") }
        if untracked > 0 { clauses.append("\(untracked) not yet processed") }

        let suffix = clauses.isEmpty ? "." : " — " + clauses.joined(separator: ", ") + "."
        return Text("Nothing new to trash. ") + count + Text(" assets indexed") + Text(suffix)
    }

    @ViewBuilder
    private var syncToastBanner: some View {
        if let toast = syncToast {
            Group {
                switch toast {
                case .upToDate(let indexed, let total):
                    Callout(.verified, icon: "checkmark.seal") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Library in sync").fontWeight(.semibold)
                            upToDateSubline(indexed: indexed, total: total)
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .journalCleared:
                    Callout(.verified, icon: "trash") {
                        Text("Journal cleared.").fontWeight(.semibold)
                    }
                case .indexReset:
                    Callout(.verified, icon: "arrow.counterclockwise") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Index reset").fontWeight(.semibold)
                            Text("Next sync will re-enumerate your library from scratch.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .rescanQueued:
                    Callout(.verified, icon: "arrow.triangle.2.circlepath") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rescan queued").fontWeight(.semibold)
                            Text("The initial-scan screen will run a fresh full enumeration.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .nothingToVerify:
                    Callout(.verified, icon: "checkmark.circle") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing to verify").fontWeight(.semibold)
                            Text("No imputed entries in the cache — everything is already locally hashed.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .limitedPhotosNotice:
                    // .pending matches the Settings → Permissions
                    // explanatory callout and signals "real
                    // degradation, not an error" — same tone as the
                    // inferred-orphan and mass-offload heads-ups.
                    Callout(.pending, icon: "exclamationmark.triangle") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Limited Photos access").fontWeight(.semibold)
                            (Text("Missed deletes will route to ") + Text("Pending review").fontWeight(.semibold) + Text(" for confirmation. See Settings → Permissions for detail."))
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .offlineDetections(let count):
                    // Server unreachable, but the local scan ran and
                    // recorded the deletions. They'll appear as trash
                    // candidates after the next successful sync.
                    Callout(.info, icon: "tray.and.arrow.down") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(count) deletion\(count == 1 ? "" : "s") detected offline").fontWeight(.semibold)
                            Text("Saved locally. Will sync to Immich on the next successful Sync.")
                                .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(bannerTransition)
        }
    }

    // MARK: - Sync card

    /// Three-band color for the "ready to trash" hero number. Tied to
    /// the user's existing `backlogAlertThreshold` setting so the
    /// red/yellow boundary lines up with the alert they've already
    /// opted into:
    ///   - 0 candidates → verified (green) — nothing to act on
    ///   - 1 to threshold-1 → pending (yellow) — accumulating
    ///   - ≥ threshold → danger (red) — past the user's alert line
    /// When the threshold is 0 (alerts disabled), fall back to a
    /// two-band "0 vs non-zero" mapping using yellow for any positive
    /// count — there's no calibrated red boundary to fall back to.
    private var readyToTrashColor: Color {
        let n = library.candidates
        if n == 0 { return t.verifiedInk }
        if backlogAlertThreshold > 0 && n >= backlogAlertThreshold { return t.dangerInk }
        return t.pendingInk
    }

    private var syncCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    // Hero column is ALWAYS visible — never replaced.
                    // The sync-phase checklist slides in alongside it
                    // during sync (below) so the user retains the
                    // ready-to-trash count + last-checked context
                    // continuously, with no transient UI disappearing.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("READY TO TRASH")
                            .font(.cairnScaled(size: 11, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(t.textMuted)
                        Button(action: { if library.candidates > 0 { onOpenDeleteQueue() } }) {
                            Text("\(library.candidates)")
                                .font(.cairnScaled(size: 44, weight: .semibold).monospacedDigit())
                                .tracking(-1.5)
                                .foregroundStyle(readyToTrashColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(library.candidates == 0)
                        .accessibilityLabel("\(library.candidates) ready to trash. Tap to view.")
                        if let checked = lastCheckedAt {
                            Text("Last checked \(Self.relativeTime(checked))")
                                .font(.cairnScaled(size: 11))
                                // Ambient timestamp — quiet blue-gray
                                // reads as "background / when this last
                                // happened" without competing with the
                                // hero count above it.
                                .foregroundStyle(t.quiet)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        // Circular icon-only sync action — replaces the
                        // former full-width "Sync now" CTA. Continuous
                        // 60fps rotation (TimelineView-driven) when
                        // syncing; clean stop at 0° when idle. Avoids
                        // the `withAnimation(.repeatForever)` problem
                        // where the rotation continues after the state
                        // flips back. `paused: !isSyncing` halts the
                        // timeline when not syncing so we don't burn
                        // CPU on offscreen frames.
                        Button(action: { if !syncBlocked && !isSyncing { onStartSync() } }) {
                            ZStack {
                                Circle()
                                    .fill(syncBlocked ? t.surfaceAlt : t.infoSoft)
                                    .frame(width: 52, height: 52)
                                PlayfulSyncIcon(
                                    // Gated on checklistVisible (NOT
                                    // isSyncing) so the icon stays static
                                    // during the ~280ms layout-grow
                                    // window after sync starts. The
                                    // diagnostic showed 3-4 StatusScreen
                                    // body re-evaluations during that
                                    // window (upstream model changes:
                                    // syncPhase, syncProgress, etc.); each
                                    // re-render triggers a layout pass,
                                    // and the rotating icon's 30fps
                                    // TimelineView was firing
                                    // concurrently — competing for render
                                    // slots and producing visible stutter
                                    // on the separator line below the
                                    // card. Once layout has settled (at
                                    // checklistVisible flip time), the
                                    // icon starts spinning normally.
                                    isAnimating: checklistVisible,
                                    color: syncBlocked ? t.textMuted : t.infoInk
                                )
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(CairnPressStyle())
                        .disabled(syncBlocked || isSyncing)
                        .accessibilityLabel(isSyncing ? "Syncing" : (syncBlocked ? "Sync unavailable" : "Sync now"))
                        Chip(label: String(format: "%.2f%% of synced", pct),
                             tone: withinBudget ? .verified : .pending)
                        HStack(spacing: 0) {
                            Text(String(format: "stops above %.1f%% past %d items", maxDeletePercent, minDeleteFloor))
                                .font(.cairnScaled(size: 11))
                                .foregroundStyle(t.textMuted)
                            HelpPopover {
                                Text("**Two safety rails on every run.** Both must be true for cairn to actually move assets to Immich's Trash.")

                                Text("**Percent threshold** — a run aborts if it would trash more than \(String(format: "%.1f%%", maxDeletePercent)) of your synced photos. Catches runaway deletions like accidental select-all, iCloud library glitches, etc.")
                                    .padding(.top, 4)

                                Text("**Count floor** — the percent check only engages when a run would move more than \(minDeleteFloor) assets. At or below the floor the run proceeds without the percent check, so small real deletions on small libraries aren't blocked by 1% rounding to 1–2 photos.")
                                    .padding(.top, 4)

                                Text("Adjust both in Settings → Safety rails. Raise the floor if your library is small, or tighten the percent if you want stricter brakes.")
                                    .padding(.top, 4)
                            }
                        }
                    }
                }

                // Sync-phase checklist + its expand/collapse animation
                // are encapsulated in a private subview that owns the
                // animation state. The subview's @State persists
                // across StatusScreen body re-evaluations as long as
                // the subview's prop values don't change — which means
                // the TimelineView inside fires uninterrupted at its
                // target framerate even when the parent re-evals 16+
                // times during sync start (upstream model property
                // updates: syncPhase, syncProgress, etc.). Earlier
                // inline implementation had the TimelineView competing
                // with parent re-evals for main-thread time, capping
                // effective framerate at ~50fps.
                SyncChecklistAnimator(
                    isAnimating: isSyncing,
                    isContentVisible: checklistVisible,
                    phase: syncPhase,
                    expandedHeight: Self.checklistHeight,
                    reduceMotion: reduceMotion
                )
                // Drill-down entry to `SyncDetailSheet`. Shown during
                // a sync (label "Show details") and after a sync
                // completes when there's narration to review (label
                // "Last sync details"). Hidden only when there's no
                // sync ever run in this session — the sheet's empty
                // state isn't worth the entry point. Deliberately
                // doesn't expose any activity-feed counts in the label
                // — Status MUST NOT read `model.syncActivity` or
                // `@Observable` would re-render the screen on every
                // emit. Decision 4 of the sync-narration plan.
                let activeEntry = isSyncing && checklistVisible
                let postSyncEntry = !isSyncing && hasLastSyncDetails
                if activeEntry || postSyncEntry {
                    Button(action: onOpenSyncDetail) {
                        HStack(spacing: 4) {
                            Text(activeEntry ? "Show details" : "Last sync details")
                                .font(.cairnScaled(size: 12, weight: .medium))
                            // No "· N ago" timestamp here: it bound to the
                            // same `lastCheckedAt` as the "Last checked N ago"
                            // line under the hero number, so the two rendered
                            // identical strings an inch apart. The hero line
                            // is the canonical, always-shown ambient stamp;
                            // this link stays a plain drill-down.
                            Image(systemName: "chevron.right")
                                .font(.cairnScaled(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(t.accentInk)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(activeEntry ? "Show sync details" : "Show last sync details")
                }
                // Renders whenever there's anything to review — items
                // held by the quarantine clock OR unconfirmed
                // candidates with no positive-signal stamp (the
                // .strict / .limited-Photos case where the orphan
                // sweep is gagged). Earlier this was gated on
                // `quarantineCount > 0` only, which meant an
                // unconfirmed-only backlog was invisible from Status
                // and the user had no entry point to PendingReview.
                if pendingReviewCount > 0 {
                    quarantineLine
                }

                // Dual-purpose progress bar:
                //   - During an active sync with a known total (full
                //     enumeration, or a drain), show hashed-of-total
                //     so the user watches work tick by — was
                //     previously only visible on the Initial Scan
                //     screen; now surfaces on Status too.
                //   - Otherwise, show the original "candidates as a
                //     fraction of the `maxDeletePercent` cap", which
                //     is the safety-rail budget indicator.
                if isSyncing, syncPhase == .fetchingServer, let expected = serverAssetsExpected, expected > 0 {
                    // During the post-hash server fetch, show the server
                    // fraction — not the hash bar frozen at 100% (the
                    // "frozen Processing N/N" symptom). Falls through to the
                    // hash bar when the expected count isn't known yet.
                    ProgressBar(
                        fraction: min(1.0, Double(serverAssetsFetched) / Double(expected)),
                        tone: .pending,
                        accessibilityLabel: "Server fetch progress"
                    )
                } else if isSyncing, let progress = syncProgress, progress.total > 0 {
                    ProgressBar(
                        fraction: min(1.0, Double(progress.hashed) / Double(progress.total)),
                        tone: .pending,
                        accessibilityLabel: "Sync progress"
                    )
                    ProcessingBreakdown(indexed: indexed, deferredQueueCount: deferredQueue.count, processed: progress.hashed)
                } else {
                    ProgressBar(
                        fraction: min(1.0, pct / max(0.001, maxDeletePercent)),
                        tone: withinBudget ? .pending : .danger,
                        accessibilityLabel: withinBudget ? "Candidate volume within safety budget" : "Candidate volume over safety budget"
                    )
                }

                if !isSyncing {
                    deferredQueueLine
                }

                // Cancel affordance during sync. Standalone since the
                // primary sync action lives in the top-right circular
                // button — when syncing, that button is disabled and
                // visibly animated; this row interrupts. Once tapped,
                // the button switches to a disabled "Cancelling…"
                // state with a small spinner so the user gets
                // immediate visual confirmation that the tap
                // registered, even though the actual cancellation
                // takes a moment to propagate through the orchestrator
                // pipeline. State resets when isSyncing flips.
                if isSyncing {
                    Button(action: {
                        cancelRequested = true
                        onCancelSync()
                    }) {
                        HStack(spacing: 8) {
                            if cancelRequested {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(t.textMuted)
                            }
                            Text(cancelRequested ? "Cancelling…" : "Cancel")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(cancelRequested ? t.textMuted : t.dangerInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CairnPressStyle())
                    .disabled(cancelRequested)
                    .accessibilityLabel(cancelRequested ? "Cancelling sync" : "Cancel sync")
                }

                // Surface the sync-blocked reason inline when applicable —
                // previously communicated by the disabled CTA's label
                // ("Server unreachable", "Limited Photo access", etc.).
                // With the CTA gone, the same reason appears as a small
                // muted line under the progress bar.
                if syncBlocked && !isSyncing {
                    Text(syncCtaLabel)
                        .font(.cairnScaled(size: 12, weight: .medium))
                        .foregroundStyle(t.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(14)
        }
        .padding(.bottom, 14)
    }

    private var quarantineLine: some View {
        // Three display modes depending on what's actually in the
        // pendingReview bucket:
        //   - Held only (quarantineCount == pendingReview): "N in quarantine"
        //   - Mixed held + unconfirmed: "N awaiting review · K in quarantine"
        //   - Unconfirmed only (quarantineCount == 0): "N awaiting review"
        // Earlier code only distinguished "unconfirmed-only" from the
        // rest, which meant the mixed case said "N in quarantine" big
        // (wrong — the big number includes unconfirmed items) with
        // "K in quarantine" small (the actual quarantine count). The
        // resulting "5 in quarantine · 3 in quarantine" reads as
        // contradictory. Now: any time pendingReview > quarantine,
        // the big label is "awaiting review" — only the all-held
        // case keeps "in quarantine."
        let allHeld = quarantineCount == pendingReviewCount && quarantineCount > 0
        let allUnconfirmed = quarantineCount == 0 && pendingReviewCount > 0
        let bigLabel = allHeld ? "in quarantine" : "awaiting review"
        let iconName = allUnconfirmed ? "questionmark.circle" : "clock"
        return Button(action: onOpenPendingReview) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: iconName)
                        .font(.cairnScaled(size: 14, weight: .semibold))
                        .foregroundStyle(t.pendingInk)
                    Text("\(pendingReviewCount)")
                        .font(.cairnScaled(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.pendingInk)
                    Text(bigLabel)
                        .font(.cairnScaled(size: 14, weight: .medium))
                        .foregroundStyle(t.pendingInk)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if allHeld, let earliest = earliestQuarantineEligible {
                        Text("next in \(Self.relativeDay(earliest))")
                            .font(.cairnScaled(size: 11, weight: .medium))
                            .foregroundStyle(t.textMuted)
                    } else if quarantineCount > 0 && quarantineCount < pendingReviewCount {
                        Text("\(quarantineCount) in quarantine")
                            .font(.cairnScaled(size: 11, weight: .medium))
                            .foregroundStyle(t.textMuted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.cairnScaled(size: 10, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(t.pendingSoft.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel("\(quarantineCount) items in quarantine. Tap to review.")
        // Stable hook for the screenshots UI test — display copy
        // on this button has changed across releases ("Pending
        // review: N" → "N in quarantine") and may again, so the
        // test should target an identifier rather than label text.
        .accessibilityIdentifier("status.openPendingReview")
    }

    @ViewBuilder
    private var deferredQueueLine: some View {
        let total = deferredQueue.count + deferredQueue.aboveCeiling
        if total > 0 {
            Button(action: onOpenDeferredQueue) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.cairnScaled(size: 12, weight: .semibold))
                        .foregroundStyle(t.infoInk)
                    if deferredQueue.count > 0 {
                        Text("\(deferredQueue.count.formatted(.number)) not yet indexed")
                            .font(.cairnScaled(size: 13, weight: .medium))
                            .foregroundStyle(t.textMuted)
                    }
                    if deferredQueue.aboveCeiling > 0 {
                        if deferredQueue.count > 0 {
                            Text("·").font(.cairnScaled(size: 13)).foregroundStyle(t.textHint)
                        }
                        Text("\(deferredQueue.aboveCeiling.formatted(.number)) above cap")
                            .font(.cairnScaled(size: 13, weight: .medium))
                            .foregroundStyle(t.textHint)
                    }
                    Spacer()
                    if deferredQueue.count > 0 {
                        Button(action: onForceDrainDeferred) {
                            Text("Hash now")
                                .font(.cairnScaled(size: 12, weight: .semibold))
                                .foregroundStyle(t.primaryInk)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(t.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(CairnPressStyle())
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.cairnScaled(size: 10, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(t.infoSoft.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(CairnPressStyle())
        }
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    static func relativeDay(_ date: Date) -> String {
        // Ceiling of the remaining seconds — the SAME rounding as
        // PendingReviewScreen's per-item "Trashes in N days" countdown, so
        // the banner's "next in N days" matches the soonest card in the
        // drill-down. Previously this used calendar-day truncation
        // (`dateComponents([.day])`), which disagreed with the cards by up
        // to a day. Keep the two in sync if either changes.
        let remaining = date.timeIntervalSinceNow
        let days = max(1, Int((remaining / 86_400).rounded(.up)))
        return days == 1 ? "1 day" : "\(days) days"
    }

    private var syncCtaLabel: String {
        if syncBlocked { return "Can’t sync — see banner" }
        if isSyncing {
            switch syncPhase {
            case .hashing:
                if let progress = syncProgress, progress.total > 0 {
                    return "Processing \(progress.hashed.formatted(.number)) / \(progress.total.formatted(.number))"
                }
                return "Indexing…"
            case .preparing:
                return "Preparing…"
            case .fetchingServer:
                if let expected = serverAssetsExpected, expected > 0 {
                    return "Fetching server · \(serverAssetsFetched.formatted(.number)) / \(expected.formatted(.number))"
                }
                if serverAssetsFetched > 0 {
                    return "Fetching server · \(serverAssetsFetched.formatted(.number))"
                }
                return "Fetching server data…"
            case .imputingFromServer:
                return "Matching from server…"
            case .reconciling:
                return "Reconciling…"
            case .finalizing:
                return "Finalizing…"
            case .idle:
                return "Syncing…"
            }
        }
        if appState == .thresholdTripped { return "Review before syncing" }
        return "Review & sync"
    }

    // MARK: - Library stats

    private var libraryStats: some View {
        CairnCard {
            HStack(spacing: 16) {
                // Three semantically distinct stats get three semantically
                // distinct hues — reads as a color-keyed pipeline:
                // orange (the device, the source) → green (indexed,
                // ready) → blue (the server, the destination).
                Stat(label: "On iPhone", value: library.local.formatted(.number), sub: "current", color: t.accentInk)
                Rectangle().fill(t.divider).frame(width: 0.5)
                Stat(
                    label: "Indexed",
                    value: library.indexedKnown ? library.indexed.formatted(.number) : "—",
                    sub: library.indexedKnown ? "SHA1 set" : "not yet calculated",
                    color: t.verifiedInk
                )
                Rectangle().fill(t.divider).frame(width: 0.5)
                Stat(label: "On server", value: library.server.formatted(.number),
                     sub: "\(library.matched.formatted(.number)) matched", color: t.infoInk)
            }
            .padding(18)
        }
    }

    // MARK: - Recent runs

    private var recentRuns: some View {
        CairnCard {
            VStack(spacing: 0) {
                ForEach(Array(runs.prefix(4).enumerated()), id: \.element.id) { idx, run in
                    RunRow(run: run, onOpen: { onOpenRun(run) })
                    if idx < min(3, runs.count - 1) {
                        RowDivider()
                    }
                }
                Button(action: onSeeAllRuns) {
                    HStack(spacing: 6) {
                        Text("See all runs")
                            .font(.cairnScaled(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.cairnScaled(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(t.accentInk)
                    .background(
                        Rectangle()
                            .fill(t.divider)
                            .frame(height: 0.5),
                        alignment: .top
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Journal tail

    /// Monospace tail of recent journal events. All rows live inside
    /// one horizontal `ScrollView` so scrolling right reveals the tail
    /// of every row simultaneously — "cand=12 elapsed=37.58s" lines up
    /// column-wise with every other event's right edge, which makes
    /// it easy to eyeball what changed between runs.
    ///
    /// The collapsed view caps at `collapsedJournalTailLimit` rows;
    /// tapping "Show more" grows to the full buffered tail so the
    /// user can audit further back without leaving Status.
    private var journalTailCard: some View {
        // Routine-sync filter: drop no-op `sync` rows when the chip is
        // ON. Filtered first, then capped to `collapsedJournalTailLimit`
        // so the count badge ("Show N more") accounts for the visible
        // post-filter set, not the raw buffer.
        let filtered = hideRoutineSyncs
            ? journalTail.filter { !$0.isRoutineSync }
            : journalTail
        let hiddenCount = journalTail.count - filtered.count
        let visible = journalExpanded
            ? filtered
            : Array(filtered.prefix(Self.collapsedJournalTailLimit))
        // Prebuilt runId set so the row's tappability check is O(1)
        // — avoids a linear scan per row when the runs list is long.
        let runIds = Set(runs.map(\.id))
        return CairnCard {
            VStack(alignment: .leading, spacing: 10) {
                journalFilterChip
                if filtered.isEmpty {
                    Text(journalEmptyMessage(hidden: hiddenCount))
                        .font(.cairnScaled(size: 12))
                        .foregroundStyle(t.textMuted)
                        .padding(.vertical, 6)
                        // Without this, the empty-state Text collapses to
                        // its intrinsic width and the surrounding card
                        // shrinks with it — visibly narrower than the
                        // populated card next to it. Pinning to .infinity
                        // standardizes card width across filter states.
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Single 2D ScrollView so rows shift together on
                    // both axes — column alignment stays correct when
                    // panning horizontally to read tail content, and
                    // vertical scroll keeps Status from bloating when
                    // expanded.
                    //
                    // Why LazyVStack + an explicit `.frame(width:)`:
                    // a horizontal ScrollView sizes contentSize to its
                    // currently realized children. With Lazy* only the
                    // visible-viewport rows are realized, so contentSize
                    // capped at viewport width and horizontal panning
                    // bounced elastically with nothing further to
                    // reveal. An eager VStack would fix that but pays
                    // 500-row construction cost on every body re-run.
                    //
                    // Instead we pre-measure the widest row off-tree
                    // via UIKit `NSString.size(withAttributes:)` —
                    // matches the monospaced SwiftUI font, costs
                    // microseconds per string — and pin the LazyVStack
                    // frame to that width. Lazy realization is
                    // preserved AND contentSize reflects the true
                    // widest line, so horizontal scroll extends fully.
                    let measuredWidth = JournalRowMetrics.maxWidth(for: visible)
                    // Spreadsheet-style banding: contiguous rows sharing a
                    // runId form one visual group; the band toggles whenever
                    // the runId changes. Empty-runId rows (e.g. routine
                    // `sync` events) inherit the current band so a stray
                    // singleton doesn't fragment the surrounding group.
                    let bandTints = Self.journalBandTints(for: visible)
                    // Per-runId outcome status, used to tint the trailing
                    // suffix column. Only finished runs (`runs[]`) appear
                    // here — in-flight or sync-only events fall back to
                    // a neutral hint tone.
                    let runOutcomeMap: [String: CairnFixtures.RunFixture.Status] =
                        Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0.status) })
                    let runById: [String: CairnFixtures.RunFixture] =
                        Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
                    // Group rows by contiguous-runId boundary so each
                    // run's events render as a unit with a tinted
                    // separator at the top. The bandTints array is
                    // still used as the group-boundary signal — each
                    // toggle means a new group starts — but the band
                    // value itself no longer drives any tinting.
                    // Visual segmentation comes solely from each
                    // separator's own background tint.
                    let groups = Self.groupJournalEntries(visible: visible, bandTints: bandTints)
                    let displayItems = Self.collapseSyncBundles(groups)
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(displayItems) { item in
                                switch item {
                                case .single(let group):
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let runId = group.runId {
                                            JournalRunSeparator(
                                                runId: runId,
                                                timeLabel: group.entries.first?.time ?? "",
                                                run: runById[runId],
                                                width: measuredWidth,
                                                isTappable: runIds.contains(runId),
                                                onTap: { onJournalRowTap(runId) }
                                            )
                                        }
                                        ForEach(group.entries) { entry in
                                            // Tap routes to trash-run detail when there's an
                                            // associated run; falls through to the row-detail
                                            // sheet for sync rows that have no trash run.
                                            // Long-press always opens row detail — gives the
                                            // user a single discoverable path to the decoded
                                            // event regardless of row type.
                                            let isTrashRun = runIds.contains(entry.runId)
                                            JournalTailRow(
                                                entry: entry,
                                                eventInk: eventColor(entry.event),
                                                isTappable: true,
                                                rowWidth: measuredWidth,
                                                runIdSuffixColor: runIdSuffixColor(for: entry.runId, in: runOutcomeMap),
                                                onTap: {
                                                    if isTrashRun {
                                                        onJournalRowTap(entry.runId)
                                                    } else {
                                                        journalRunDetailContext = journalRunContext(anchor: entry)
                                                    }
                                                },
                                                onLongPress: { journalRunDetailContext = journalRunContext(anchor: entry) }
                                            )
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .frame(width: measuredWidth, alignment: .leading)

                                case .syncBundle(let bundleId, let bundleGroups):
                                    let expanded = expandedSyncBundles.contains(bundleId)
                                    VStack(alignment: .leading, spacing: 6) {
                                        SyncBundleHeader(
                                            groups: bundleGroups,
                                            expanded: expanded,
                                            width: measuredWidth,
                                            onToggle: {
                                                withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                                                    if expanded {
                                                        expandedSyncBundles.remove(bundleId)
                                                    } else {
                                                        expandedSyncBundles.insert(bundleId)
                                                    }
                                                }
                                            }
                                        )
                                        if expanded {
                                            ForEach(bundleGroups) { group in
                                                VStack(alignment: .leading, spacing: 6) {
                                                    if let runId = group.runId {
                                                        JournalRunSeparator(
                                                            runId: runId,
                                                            timeLabel: group.entries.first?.time ?? "",
                                                            run: runById[runId],
                                                            width: measuredWidth,
                                                            isTappable: runIds.contains(runId),
                                                            onTap: { onJournalRowTap(runId) }
                                                        )
                                                    }
                                                    ForEach(group.entries) { entry in
                                                        let isTrashRun = runIds.contains(entry.runId)
                                                        JournalTailRow(
                                                            entry: entry,
                                                            eventInk: eventColor(entry.event),
                                                            isTappable: true,
                                                            rowWidth: measuredWidth,
                                                            runIdSuffixColor: runIdSuffixColor(for: entry.runId, in: runOutcomeMap),
                                                            onTap: {
                                                                if isTrashRun {
                                                                    onJournalRowTap(entry.runId)
                                                                } else {
                                                                    journalRunDetailContext = journalRunContext(anchor: entry)
                                                                }
                                                            },
                                                            onLongPress: { journalRunDetailContext = journalRunContext(anchor: entry) }
                                                        )
                                                    }
                                                }
                                                .padding(.leading, 12)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .frame(width: measuredWidth, alignment: .leading)
                                }
                            }
                        }
                        .frame(width: measuredWidth, alignment: .leading)
                        .padding(.trailing, 4)   // breathing room on the right edge
                    }
                    .frame(maxHeight: journalExpanded ? Self.expandedJournalCardMaxHeight : .infinity)
                    .scrollBounceBehavior(.basedOnSize)

                    if filtered.count > Self.collapsedJournalTailLimit {
                        Button {
                            withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                                journalExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: journalExpanded ? "chevron.up" : "chevron.down")
                                    .font(.cairnScaled(size: 11, weight: .semibold))
                                Text(journalExpanded
                                     ? "Show fewer"
                                     : "Show \(filtered.count - Self.collapsedJournalTailLimit) more")
                                    .font(.cairnScaled(size: 12, weight: .medium))
                            }
                            .foregroundStyle(t.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }

                    if hideRoutineSyncs && hiddenCount > 0 {
                        Text("\(hiddenCount) routine sync\(hiddenCount == 1 ? "" : "s") hidden")
                            .font(.cairnScaled(size: 11))
                            .foregroundStyle(t.textHint)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// Tap-to-toggle filter chip pinned above the journal rows. Uses
    /// the existing `Chip` view for visual consistency with the
    /// status header. Animates on toggle so the row list reflows with
    /// the rest of the banner-area motion.
    private var journalFilterChip: some View {
        Button {
            withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                hideRoutineSyncs.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hideRoutineSyncs
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                    .font(.cairnScaled(size: 11, weight: .semibold))
                Text(hideRoutineSyncs ? "Hiding routine syncs" : "Showing all events")
                    .font(.cairnScaled(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(hideRoutineSyncs ? t.infoInk : t.textBody)
            .background(hideRoutineSyncs ? t.infoSoft : t.surfaceAlt)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hideRoutineSyncs
            ? "Routine no-op syncs hidden. Tap to show."
            : "All events shown. Tap to hide routine no-op syncs.")
    }

    /// Empty-state copy for the journal card. Distinguishes "no
    /// events at all" from "everything got filtered out" so a user
    /// who's confused why the card is empty has a path forward.
    private func journalEmptyMessage(hidden: Int) -> String {
        if journalTail.isEmpty {
            return "No events yet. Events appear here after the first sync."
        }
        if hidden > 0 {
            return "All \(hidden) recent event\(hidden == 1 ? "" : "s") \(hidden == 1 ? "is" : "are") routine syncs. Tap the chip to show them."
        }
        return "No events to show."
    }

    /// How many journal rows show in the collapsed state. Everything
    /// beyond this hides behind the "Show more" toggle.
    /// Hardcoded height for the `SyncPhaseChecklist` — now one row of
    /// 12pt text + 4pt top padding ≈ 22pt (down from 64pt when it was
    /// a three-row checklist; see "Sync phase indicator" in
    /// CairnPrimitives.swift). Used as the explicit `.frame(height:)`
    /// target when `isSyncing` is true so the layout shift is a
    /// deterministic frame animation rather than a "view appears for
    /// the first time" event that has to instantiate + measure +
    /// animate in one frame. Tuning: bump if the indicator visibly
    /// clips at the bottom; reduce if there's a visible gap.
    private static let checklistHeight: CGFloat = 22

    private static let scrollTopAnchor = "cairn.scroll.top"

    private static let collapsedJournalTailLimit: Int = 8

    /// Cap for the expanded journal card's vertical extent. Beyond
    /// this, content scrolls within the card rather than pushing the
    /// rest of Status down. ≈12 rows visible at the current row
    /// height — roughly a screen-page of activity at a glance.
    private static let expandedJournalCardMaxHeight: CGFloat = 360

    /// One contiguous run of journal entries grouped for layout. The
    /// first non-empty `runId` inside the group is the "owner" — the
    /// run separator at the top of the group uses it. Groups composed
    /// entirely of empty-runId rows (a stretch of routine syncs
    /// between runs) have `runId == nil` and render without a separator.
    fileprivate struct JournalGroup: Identifiable {
        let id: Int
        let runId: String?
        let entries: [CairnFixtures.JournalTailEntry]
    }

    /// Walk `visible` alongside the parallel `bandTints` array,
    /// flushing a new group every time the band value flips. The band
    /// array is no longer used for tinting — only as a boundary
    /// signal — but the toggle pattern (driven by runId changes,
    /// with empty-runId rows inheriting) is exactly the grouping
    /// behavior we want. Lifted out of the view body to dodge
    /// SwiftUI's type-checker timeouts on heavy view-builder
    /// expressions.
    private static func groupJournalEntries(
        visible: [CairnFixtures.JournalTailEntry],
        bandTints: [Bool]
    ) -> [JournalGroup] {
        guard !visible.isEmpty else { return [] }
        var groups: [JournalGroup] = []
        var bucket: [CairnFixtures.JournalTailEntry] = []
        var bucketRunId: String? = nil
        var bucketBand: Bool = bandTints[0]
        for i in 0..<visible.count {
            let band = bandTints[i]
            if band != bucketBand && !bucket.isEmpty {
                groups.append(JournalGroup(
                    id: groups.count,
                    runId: bucketRunId,
                    entries: bucket
                ))
                bucket = []
                bucketRunId = nil
                bucketBand = band
            }
            let entry = visible[i]
            if bucketRunId == nil && !entry.runId.isEmpty {
                bucketRunId = entry.runId
            }
            bucket.append(entry)
        }
        if !bucket.isEmpty {
            groups.append(JournalGroup(
                id: groups.count,
                runId: bucketRunId,
                entries: bucket
            ))
        }
        return groups
    }

    /// One display item in the journal tail. Either a single
    /// `JournalGroup` rendered normally, or a folded "bundle" of N
    /// consecutive sync-only groups that the user can expand by tap.
    /// Used to keep a long evening of routine BG syncs from drowning
    /// out the interesting (trash / restore / exclude) rows.
    fileprivate enum JournalDisplayItem: Identifiable {
        case single(JournalGroup)
        case syncBundle(id: String, groups: [JournalGroup])

        var id: String {
            switch self {
            case .single(let g): return "g-\(g.id)"
            case .syncBundle(let id, _): return "bundle-\(id)"
            }
        }
    }

    /// Event names that are "routine sync infrastructure" — high
    /// frequency, low per-row information. Multiple consecutive groups
    /// composed entirely of these collapse into a single tappable
    /// bundle. Anything outside this set (run.start, trash.ok,
    /// restore.ok, etc.) is a discrete user-meaningful action and
    /// stays as its own row.
    private static let collapsibleSyncEventNames: Set<String> = [
        "sync.start", "sync", "sync.trans"
    ]

    /// Threshold for collapsing — N or more consecutive sync-only
    /// groups fold into a bundle. Below the threshold the rows stay
    /// inline because the savings aren't worth the tap-to-expand
    /// indirection. 3 is the smallest set where you visibly clutter
    /// without the collapse.
    private static let syncBundleCollapseThreshold = 3

    /// Walk the run-band groups and bundle consecutive groups whose
    /// entries are entirely composed of `collapsibleSyncEventNames`
    /// AND whose sync.start trigger is a background variant (or
    /// missing/unknown). Manual / shortcut / debug-triggered syncs
    /// never bundle — those are user-initiated and the user wants
    /// to see each one. Groups with any non-sync event (trash,
    /// restore, exclude, run.*) also break the bundle boundary.
    fileprivate static func collapseSyncBundles(_ groups: [JournalGroup]) -> [JournalDisplayItem] {
        guard !groups.isEmpty else { return [] }
        var result: [JournalDisplayItem] = []
        var pendingBundle: [JournalGroup] = []

        func flushBundle() {
            guard !pendingBundle.isEmpty else { return }
            if pendingBundle.count >= syncBundleCollapseThreshold {
                let bundleId = pendingBundle
                    .compactMap { $0.runId ?? "g\($0.id)" }
                    .joined(separator: "-")
                result.append(.syncBundle(id: bundleId, groups: pendingBundle))
            } else {
                // Below threshold — render each pending group as a
                // single. Avoids hiding tiny streaks behind a chevron.
                for g in pendingBundle {
                    result.append(.single(g))
                }
            }
            pendingBundle = []
        }

        for group in groups {
            let isAllSyncEvents = group.entries.allSatisfy {
                collapsibleSyncEventNames.contains($0.event)
            }
            // Look for the trigger string on the syncStarted row, if
            // present. Message format is `trigger=<token>` per
            // SyncTrigger.shortToken. Manual / shortcut / debug must
            // stay visible — bail out of bundling for those.
            let isBundleableTrigger: Bool = {
                guard isAllSyncEvents else { return false }
                let triggers = group.entries.compactMap { entry -> String? in
                    guard entry.event == "sync.start" else { return nil }
                    return entry.message.replacingOccurrences(of: "trigger=", with: "")
                }
                // No sync.start at all = legacy/unknown — treat as
                // bundleable (default to compression for noise).
                if triggers.isEmpty { return true }
                let userInitiated: Set<String> = ["manual", "shortcut", "debug"]
                return !triggers.contains(where: { userInitiated.contains($0) })
            }()
            if isBundleableTrigger {
                pendingBundle.append(group)
            } else {
                flushBundle()
                result.append(.single(group))
            }
        }
        flushBundle()
        return result
    }

    /// Per-row band-tint flags. Walks `entries` and toggles a running
    /// boolean each time a non-empty `runId` differs from the previous
    /// non-empty `runId`. Empty-runId rows inherit the current band so
    /// stray singletons (routine `sync` events with no run association)
    /// don't visually break the surrounding group.
    /// Build the run-scoped context for an anchor entry — collects
    /// every visible journal-tail entry sharing the anchor's runId.
    /// Empty-runId rows (rare; fixture-only) collapse to a single-
    /// entry context. journalTail is bounded by the host, so this is
    /// limited to whatever's currently rendered on Status — older
    /// out-of-window run entries don't show up. Acceptable for v1;
    /// adding "drill into a historical run not in the tail" is a
    /// follow-up.
    private func journalRunContext(anchor: CairnFixtures.JournalTailEntry) -> JournalRunDetailContext {
        guard !anchor.runId.isEmpty else {
            return JournalRunDetailContext(anchor: anchor, entries: [anchor])
        }
        let siblings = journalTail.filter { $0.runId == anchor.runId }
        return JournalRunDetailContext(
            anchor: anchor,
            entries: siblings.isEmpty ? [anchor] : siblings
        )
    }

    private static func journalBandTints(for entries: [CairnFixtures.JournalTailEntry]) -> [Bool] {
        var bands: [Bool] = []
        bands.reserveCapacity(entries.count)
        var current = false
        var prevRunId: String? = nil
        for entry in entries {
            let id = entry.runId
            if !id.isEmpty, let prev = prevRunId, prev != id {
                current.toggle()
            }
            bands.append(current)
            if !id.isEmpty {
                prevRunId = id
            }
        }
        return bands
    }

    /// Color the trailing runId suffix by the run's outcome — green
    /// for `.complete`, red for `.aborted`, info-tone for `.restored`.
    /// Falls back to `t.textHint` for runIds with no resolved outcome
    /// (in-flight, sync-only, or never-promoted-to-runs entries).
    private func runIdSuffixColor(
        for runId: String,
        in map: [String: CairnFixtures.RunFixture.Status]
    ) -> Color {
        guard let status = map[runId] else { return t.textHint }
        switch status {
        case .complete:  return t.verifiedInk
        case .aborted:   return t.dangerInk
        case .restored:  return t.infoInk
        }
    }

    /// Mapping pinned to the event-name strings `JournalTailEntry.from`
    /// actually emits. The previous version checked stale names
    /// (`safety.ok`, `tag.create`, `delete.batch`, `abort`) that the
    /// post-Wave-2 pipeline never writes — so every row rendered in
    /// the default `textBody` color regardless of severity.
    private func eventColor(_ ev: String) -> Color {
        switch ev {
        case "trash.ok", "run.complete", "restore.ok":
            return t.verifiedInk
        case "trash.fail", "restore.fail":
            return t.dangerInk
        case "run.abort":
            return t.dangerInk
        case "pending.hold":
            return t.pendingInk
        case "tag.apply", "restore.start", "run.start", "plan.trash", "exclude.add":
            return t.infoInk
        case "sync":
            return t.textBody
        default:
            return t.textBody
        }
    }
}

// MARK: - SyncChecklist animator

/// The SyncPhaseChecklist's expand/collapse spring. `target` lives in
/// `@State` and is driven via `withAnimation(.cairnSpring) { ... }`
/// from `onChange(of: isAnimating)`, which establishes an explicit
/// animation transaction — more reliable than the implicit
/// `.animation(_:value:)` modifier, which under some modifier-chain
/// configurations falls through to a critically-damped curve and
/// loses the spring's overshoot.
///
/// Subview wrapper keeps the @State stable across StatusScreen body
/// re-evals (the parent rebuilds 16+ times during a sync start;
/// SwiftUI's diff skips this view as long as props are unchanged, so
/// the animation-in-progress isn't disturbed).
private struct SyncChecklistAnimator: View {
    let isAnimating: Bool
    let isContentVisible: Bool
    let phase: CairnAppModel.SyncPhase
    let expandedHeight: CGFloat
    let reduceMotion: Bool

    @State private var target: CGFloat = 0

    var body: some View {
        SyncPhaseChecklist(phase: phase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: target, alignment: .top)
            .clipped()
            .opacity(isContentVisible ? 1 : 0)
            .onChange(of: isAnimating) { _, syncing in
                let newTarget: CGFloat = syncing ? expandedHeight : 0
                if reduceMotion {
                    target = newTarget
                } else {
                    withAnimation(.cairnSpring) {
                        target = newTarget
                    }
                }
            }
    }
}

// MARK: - Playful sync icon

/// Constant-speed sync glyph — linear rotation at a steady angular
/// velocity, no kick, no settle, no rest. Adapted from the
/// user-provided CSS reference `@keyframes l5` which animates
/// `transform: rotate(.5turn)` over 1s with default linear easing.
///
/// One full revolution per cycle (360° / period seconds), so the
/// loop wrap is seamless: at cycle end rotation is at 360°, which
/// is visually identical to 0° at the next cycle's start. No
/// velocity discontinuity, no piecewise segments.
///
/// `TimelineView(.animation, paused:)` drives the cycle and pauses
/// cleanly when not syncing. `.transaction` opts the icon out of
/// inherited animation contexts so a parent `.animation(.spring,
/// value:)` doesn't pull the per-frame rotation updates into a
/// spring interpolation (which would visibly stutter the rotation).
private struct PlayfulSyncIcon: View {
    let isAnimating: Bool
    let color: Color
    var size: CGFloat = 22
    /// Seconds per full 360° revolution. 2.0s = 180°/sec, matching
    /// the CSS `l5` reference (.5turn per 1s).
    var period: Double = 2.0

    /// Absolute Date at which the coast-to-rest phase finishes. nil
    /// when the icon is either spinning (isAnimating == true) or
    /// fully parked. Coast always goes forward — the SF Symbol
    /// `arrow.triangle.2.circlepath` has 180° rotational symmetry,
    /// so we can land at either the next 180° boundary OR the next
    /// 360° wrap and the icon looks identical at both. Whichever is
    /// closer wins, capping post-stop motion at half a revolution.
    @State private var coastEnd: Date? = nil
    /// Rotation value to render once the coast finishes — either 0°
    /// or 180°, both visually identical for this symbol but
    /// mathematically distinct so SwiftUI's `rotationEffect` doesn't
    /// jump back to 0 from 180.
    @State private var parkedRotation: Double = 0

    var body: some View {
        // TimelineView runs continuously (no `paused:`) so the body
        // re-evaluates each frame and can detect when the coast
        // phase ends. CPU cost is negligible — when fully stopped,
        // the rotation value is constant and SwiftUI's render diff
        // skips the actual draw.
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period)
            let inCycleRotation = (elapsed / period) * 360
            let rotation: Double = {
                if isAnimating {
                    return inCycleRotation
                } else if let end = coastEnd, context.date < end {
                    // Coasting — keep spinning until the scheduled
                    // half-cycle boundary.
                    return inCycleRotation
                } else {
                    return parkedRotation
                }
            }()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.cairnScaled(size: size, weight: .semibold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(rotation))
        }
        .transaction { $0.disablesAnimations = true }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                // Resuming: clear pending coast and reset park.
                coastEnd = nil
                parkedRotation = 0
            } else {
                // Aim for the next 180° boundary — either the
                // mid-cycle 180° point or the cycle-wrap 360°/0°
                // point. Both look identical for this symbol thanks
                // to its 180° symmetry. Worst-case post-stop motion
                // is half a revolution.
                let now = Date()
                let elapsedInCycle = now.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period)
                let currentAngle = (elapsedInCycle / period) * 360
                let nextBoundary: Double = currentAngle < 180 ? 180 : 360
                let timeToBoundary = (nextBoundary - currentAngle) * period / 360
                coastEnd = now.addingTimeInterval(timeToBoundary)
                // Park value: 180 if landing mid-cycle, 0 if landing
                // at cycle-wrap (where inCycleRotation naturally
                // truncates back to 0).
                parkedRotation = nextBoundary == 360 ? 0 : 180
            }
        }
    }
}

// MARK: - Journal run detail sheet

/// Detail view shown when the user taps (or long-presses) a journal
/// row. Renders **every event in the same run** (entries sharing the
/// tapped row's `runId`) in chronological order, each as a styled-JSON
/// block. The premise: a run is the meaningful unit of activity. A
/// single sync emits start + completed + transitions; a trash run
/// emits started + planning + tags + trash + completed. Showing them
/// together puts the full story in one view rather than forcing the
/// user to tap each row individually.
///
/// Entries with an empty `runId` (rare — fixture-only rows) collapse
/// to a single-entry view. The anchor (the row the user actually
/// tapped) gets a subtle accent stripe so they can find it in a
/// multi-event group.
struct JournalRunDetailContext: Identifiable {
    let anchor: CairnFixtures.JournalTailEntry
    let entries: [CairnFixtures.JournalTailEntry]
    var id: String { "\(anchor.runId)|\(anchor.id)" }
}

private struct JournalRunDetailSheet: View {
    let context: JournalRunDetailContext

    @Environment(\.cairnTokens) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    runHeader
                    ForEach(orderedEntries) { entry in
                        eventBlock(for: entry)
                    }
                }
                .padding(16)
            }
            .background(t.bg)
            .navigationTitle(navigationTitleText)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let consolidated = consolidatedRawJSON {
                        Button {
                            UIPasteboard.general.string = consolidated
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy all events as JSON")
                    }
                }
            }
            #endif
        }
    }

    // MARK: - Derived

    /// Render oldest-first within the run so the user reads top-to-
    /// bottom as the run progressed. journalTail upstream is
    /// newest-first, so reverse here.
    private var orderedEntries: [CairnFixtures.JournalTailEntry] {
        context.entries.reversed()
    }

    private var navigationTitleText: String {
        if context.anchor.runId.isEmpty { return context.anchor.event }
        let count = context.entries.count
        return count == 1 ? "Run · 1 event" : "Run · \(count) events"
    }

    /// All entries concatenated as one JSON array, for the "Copy"
    /// toolbar button. Lets the user share the entire run's payload
    /// in a single paste.
    private var consolidatedRawJSON: String? {
        let payloads = orderedEntries.compactMap(\.rawJSON)
        guard !payloads.isEmpty else { return nil }
        if payloads.count == 1 { return payloads[0] }
        return "[\n" + payloads.joined(separator: ",\n") + "\n]"
    }

    // MARK: - Run header

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !context.anchor.runId.isEmpty {
                Text("Run id: \(context.anchor.runId)")
                    .font(.cairnScaled(size: 11, design: .monospaced))
                    .foregroundStyle(t.textHint)
                    .textSelection(.enabled)
            }
            if let span = timeSpan {
                Text(span)
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
            }
        }
    }

    private var timeSpan: String? {
        let times = orderedEntries.map(\.time)
        guard let first = times.first, let last = times.last else { return nil }
        if first == last { return first }
        return "\(first) → \(last)"
    }

    // MARK: - Event block

    @ViewBuilder
    private func eventBlock(for entry: CairnFixtures.JournalTailEntry) -> some View {
        let isAnchor = entry.id == context.anchor.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.time)
                    .font(.cairnScaled(size: 12, design: .monospaced))
                    .foregroundStyle(t.textHint)
                Text(entry.event)
                    .font(.cairnScaled(size: 13, weight: .semibold))
                    .foregroundStyle(t.text)
                Spacer(minLength: 0)
            }
            payloadBlock(for: entry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(t.divider, lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            // Anchor stripe: 3pt left border on the row the user
            // actually tapped. Lets them find their entry point in
            // a multi-event group without prose explaining it.
            if isAnchor {
                Rectangle()
                    .fill(t.accent)
                    .frame(width: 3)
                    .clipShape(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 9, bottomLeading: 9),
                            style: .continuous
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private func payloadBlock(for entry: CairnFixtures.JournalTailEntry) -> some View {
        if let json = entry.rawJSON,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            // Strip the outer `event: { caseName: { ... } }` wrapper
            // when present — we already render the event name in the
            // header above, so showing it again as a key is noise.
            // Falls through to the full parsed value when the shape
            // doesn't match (defensive against future JournalEntry
            // wire-format changes).
            let displayed = Self.unwrap(parsed)
            JSONTreeView(value: displayed)
        } else if let json = entry.rawJSON {
            // Parse failure — show raw text as a fallback.
            Text(json)
                .font(.cairnScaled(size: 12, design: .monospaced))
                .foregroundStyle(t.textBody)
                .textSelection(.enabled)
        } else {
            Text(entry.message)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// JournalEntry encodes as `{event: {caseName: {...payload...}}, runId, timestamp}`.
    /// For the per-event JSON tree, strip the outer scaffolding and
    /// render just the payload (since the header above already names
    /// the event and the run header carries runId + timestamp).
    private static func unwrap(_ parsed: Any) -> Any {
        guard let top = parsed as? [String: Any] else { return parsed }
        if let eventDict = top["event"] as? [String: Any],
           let caseName = eventDict.keys.first,
           let payload = eventDict[caseName] {
            return payload
        }
        return parsed
    }
}

// MARK: - Styled JSON tree

/// Renders a parsed JSON value (Any from `JSONSerialization`) as a
/// SwiftUI view tree with light syntax styling — keys semibold,
/// strings / numbers / bools / nulls in distinct token colors,
/// nested objects/arrays indented one level per depth. Read-only,
/// text-selectable for copy/paste of individual values.
private struct JSONTreeView: View {
    let value: Any
    var depth: Int = 0

    @Environment(\.cairnTokens) private var t

    var body: some View {
        if let dict = value as? [String: Any] {
            objectBody(dict)
        } else if let array = value as? [Any] {
            arrayBody(array)
        } else {
            JSONScalar(value: value)
                .textSelection(.enabled)
        }
    }

    private func objectBody(_ dict: [String: Any]) -> some View {
        // Stable key order — dictionaries from JSONSerialization are
        // unordered. Sorting alphabetically gives the user a
        // predictable read so they can land in the same place across
        // two different sheets opened from similar events.
        let sortedKeys = dict.keys.sorted()
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedKeys, id: \.self) { key in
                row(key: key, value: dict[key] ?? NSNull())
            }
        }
        .padding(.leading, depth == 0 ? 0 : 12)
    }

    private func arrayBody(_ array: [Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(array.enumerated()), id: \.offset) { idx, item in
                row(key: "[\(idx)]", value: item, isArrayIndex: true)
            }
        }
        .padding(.leading, depth == 0 ? 0 : 12)
    }

    @ViewBuilder
    private func row(key: String, value: Any, isArrayIndex: Bool = false) -> some View {
        if let dict = value as? [String: Any], !dict.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(key)
                    .font(.cairnScaled(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isArrayIndex ? t.textHint : t.textBody)
                    .textSelection(.enabled)
                JSONTreeView(value: dict, depth: depth + 1)
            }
        } else if let array = value as? [Any], !array.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(key)  (\(array.count))")
                    .font(.cairnScaled(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isArrayIndex ? t.textHint : t.textBody)
                    .textSelection(.enabled)
                JSONTreeView(value: array, depth: depth + 1)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key)
                    .font(.cairnScaled(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isArrayIndex ? t.textHint : t.textBody)
                JSONScalar(value: value)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Single scalar value (string, number, bool, null, or empty
/// container) rendered with a type-appropriate token color. Strings
/// get a slight quote treatment to distinguish them from bare
/// identifiers; numbers / bools / nulls each get their own color
/// for at-a-glance scanning.
private struct JSONScalar: View {
    let value: Any

    @Environment(\.cairnTokens) private var t

    var body: some View {
        switch value {
        case is NSNull:
            Text("null")
                .font(.cairnScaled(size: 13, design: .monospaced))
                .foregroundStyle(t.textHint)
        case let s as String:
            Text("\"\(s)\"")
                .font(.cairnScaled(size: 13, design: .monospaced))
                .foregroundStyle(t.accentInk)
                .fixedSize(horizontal: false, vertical: true)
        case let n as NSNumber:
            // Bool comes through as NSNumber on iOS. The objCType
            // discriminator is the only reliable way to tell them
            // apart — `is Bool` matches both.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                Text(n.boolValue ? "true" : "false")
                    .font(.cairnScaled(size: 13, design: .monospaced))
                    .foregroundStyle(t.infoInk)
            } else {
                Text(n.stringValue)
                    .font(.cairnScaled(size: 13, design: .monospaced))
                    .foregroundStyle(t.verifiedInk)
            }
        case let arr as [Any] where arr.isEmpty:
            Text("[]")
                .font(.cairnScaled(size: 13, design: .monospaced))
                .foregroundStyle(t.textHint)
        case let dict as [String: Any] where dict.isEmpty:
            Text("{}")
                .font(.cairnScaled(size: 13, design: .monospaced))
                .foregroundStyle(t.textHint)
        default:
            Text(String(describing: value))
                .font(.cairnScaled(size: 13, design: .monospaced))
                .foregroundStyle(t.text)
        }
    }
}

// MARK: - Journal run separator

/// One-line divider row inserted at the start of each contiguous-runId
/// group in the journal-tail card. Renders a thin hairline rule above
/// run metadata ("11:42 · trashed 12 · run abc12345") so the user can
/// see where one run ends and the next begins, plus tap the row to
/// drill into run detail. Pairs with the band-tint logic — bands give
/// at-a-glance grouping; the separator gives an explicit boundary +
/// metadata.
///
/// Only emitted for groups whose entries have a non-empty `runId` —
/// sync-only sections (no associated run) don't get a header.
/// Collapsed-state header for a `JournalDisplayItem.syncBundle`. Shows
/// a chevron, the run count, an aggregated time range, and the
/// dominant trigger token from the contained sync rows. Tap toggles
/// the expanded state (the host inserts the contained groups below
/// when expanded). Width-pinned to keep horizontal scroll geometry
/// consistent with the rest of the journal tail.
private struct SyncBundleHeader: View {
    let groups: [StatusScreen.JournalGroup]
    let expanded: Bool
    let width: CGFloat
    let onToggle: () -> Void

    @Environment(\.cairnTokens) private var t

    /// Roll up the contained groups into a one-line summary. Counts the
    /// distinct run IDs (each ≈ one sync execution) rather than total
    /// rows, since a single sync emits multiple row events.
    private var summary: String {
        let runCount = Set(groups.compactMap { $0.runId }).count
        let triggers = Set(groups.flatMap { $0.entries }
            .compactMap { entry -> String? in
                guard entry.event == "sync.start" else { return nil }
                // syncStarted message format: "trigger=background"
                return entry.message.replacingOccurrences(of: "trigger=", with: "")
            })
        let label = runCount == 1 ? "sync" : "syncs"
        let triggerSuffix: String
        if triggers.isEmpty {
            triggerSuffix = ""
        } else if triggers.count == 1, let only = triggers.first {
            triggerSuffix = " · trigger=\(only)"
        } else {
            triggerSuffix = " · trigger=mixed"
        }
        return "\(runCount) \(label)\(triggerSuffix)"
    }

    private var timeRange: String {
        let times = groups.flatMap { $0.entries }.map(\.time)
        guard let first = times.first, let last = times.last else { return "" }
        return first == last ? first : "\(last)–\(first)" // newest-first list → last is earliest
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                    .frame(width: 12, alignment: .leading)
                Text(timeRange)
                    .font(.cairnScaled(size: 11, design: .monospaced))
                    .foregroundStyle(t.textHint)
                Text(summary)
                    .font(.cairnScaled(size: 12, weight: .medium))
                    .foregroundStyle(t.textBody)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .background(t.surfaceAlt.opacity(expanded ? 0.5 : 0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct JournalRunSeparator: View {
    let runId: String
    let timeLabel: String
    /// Resolved RunFixture if the run has finished and rolled into
    /// `runs[]`. Nil for in-flight runs whose `runStarted` event is on
    /// disk but no terminal event yet.
    let run: CairnFixtures.RunFixture?
    let width: CGFloat
    let isTappable: Bool
    let onTap: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(timeLabel)
                    .font(.cairnScaled(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(t.textHint)
                Text("·")
                    .font(.cairnScaled(size: 10.5))
                    .foregroundStyle(t.textHint)
                if let summary = runSummaryLabel {
                    Text(summary)
                        .font(.cairnScaled(size: 10.5, weight: .medium))
                        .foregroundStyle(summaryColor)
                    Text("·")
                        .font(.cairnScaled(size: 10.5))
                        .foregroundStyle(t.textHint)
                }
                Text("run \(runId.suffix(8))")
                    .font(.cairnScaled(size: 10.5, design: .monospaced))
                    .foregroundStyle(t.textHint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(width: width, alignment: .leading)
            .background(t.surfaceAlt.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isTappable)
    }

    /// Outcome-aware short summary: "trashed 12", "aborted",
    /// "restored". Nil for in-flight runs, which then collapse the
    /// summary segment of the header to keep it tight.
    private var runSummaryLabel: String? {
        guard let run else { return nil }
        switch run.status {
        case .complete:
            if run.dryRun { return "dry-run" }
            if run.trashed > 0 { return "trashed \(run.trashed)" }
            if run.restored > 0 { return "restored \(run.restored)" }
            return "complete"
        case .aborted:  return "aborted"
        case .restored: return "restored \(run.restored)"
        }
    }

    private var summaryColor: Color {
        guard let run else { return t.textBody }
        switch run.status {
        case .complete:  return run.dryRun ? t.textBody : t.verifiedInk
        case .aborted:   return t.dangerInk
        case .restored:  return t.infoInk
        }
    }
}

// MARK: - Journal tail row

/// Off-tree text measurement so the journal card can pin its
/// `LazyVStack` to the widest realized row's actual content width.
/// All constants here mirror `JournalTailRow.body` exactly — if you
/// change a font, frame width, or HStack spacing in the row, update
/// the matching constant here or horizontal scroll will be off.
private enum JournalRowMetrics {
    // Layout constants — every value here corresponds to a literal in
    // JournalTailRow.body.
    static let severityDotFrameWidth: CGFloat = 8
    static let glyphFrameWidth: CGFloat = 14
    static let timeFrameWidth: CGFloat = 80
    static let suffixFrameWidth: CGFloat = 64
    static let hStackSpacing: CGFloat = 8
    static let suffixLeadingPad: CGFloat = 12

    // UIKit and SwiftUI text-layout can disagree by a sub-pixel; the
    // margin keeps rows from being clipped by ~1pt at the right edge.
    static let safetyMargin: CGFloat = 4

    #if canImport(UIKit)
    // Font weights/sizes mirror the SwiftUI Text styles in JournalTailRow.
    // `monospacedSystemFont` matches `.system(size:design:.monospaced)`.
    static let eventFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
    static let messageFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    #endif

    /// Computes the widest row's intrinsic content width across the
    /// given entries. O(n) over `entries`, ~microseconds per string;
    /// fine to call inline from `body`. The macOS build of this module
    /// never renders the journal card (iOS-only target shell), so the
    /// non-UIKit path returns a generous fallback sufficient to compile.
    static func maxWidth(for entries: [CairnFixtures.JournalTailEntry]) -> CGFloat {
        #if canImport(UIKit)
        let eventAttrs: [NSAttributedString.Key: Any] = [.font: eventFont]
        let messageAttrs: [NSAttributedString.Key: Any] = [.font: messageFont]
        var maxW: CGFloat = 0
        for entry in entries {
            let eventW = (entry.event as NSString).size(withAttributes: eventAttrs).width
            let messageW = (entry.message as NSString).size(withAttributes: messageAttrs).width
            // Row layout: severityDot | spacing | glyph | spacing | time | spacing | event | spacing | message ( | spacing | leadingPad | suffix )
            var width = severityDotFrameWidth
                + hStackSpacing + glyphFrameWidth
                + hStackSpacing + timeFrameWidth
                + hStackSpacing + eventW
                + hStackSpacing + messageW
            if !entry.runIdSuffix.isEmpty {
                width += hStackSpacing + suffixLeadingPad + suffixFrameWidth
            }
            if width > maxW { maxW = width }
        }
        return ceil(maxW + safetyMargin)
        #else
        return 800
        #endif
    }
}

/// One row inside the journal-tail card. Plain single-line layout;
/// horizontal scrolling happens at the *card* level (all rows shift
/// together) so column positions stay aligned. Fixed-width time and
/// event columns keep messages flush-left across rows.
private struct JournalTailRow: View {
    let entry: CairnFixtures.JournalTailEntry
    let eventInk: Color
    let isTappable: Bool
    /// Width to stretch the row tap target across. Equals
    /// `JournalRowMetrics.maxWidth(for:)` from the parent so all rows
    /// have a uniform hit area regardless of intrinsic content. The
    /// band tint moved to the enclosing group container — rows are
    /// transparent so the group-level background shows through.
    let rowWidth: CGFloat
    /// Color for the trailing `runIdSuffix`. Driven by the lookup of
    /// `entry.runId` against the runs list — green for `.complete`,
    /// red for `.aborted`, info-tone for `.restored`, hint-tone when
    /// the runId doesn't match a known run (in-flight or sync-only).
    let runIdSuffixColor: Color
    let onTap: () -> Void
    let onLongPress: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Severity dot — keyed off `entry.severity`, distinct
                // from the event glyph so "did anything go wrong?" is
                // answerable with one eye-flick. Tints from the token
                // palette so light/dark stay coherent.
                Circle()
                    .fill(severityColor)
                    .frame(width: 6, height: 6)
                    .frame(width: 8, alignment: .center)
                // Leading status glyph — at-a-glance signal that
                // doesn't require parsing event-name strings. Tinted
                // to match `eventInk` so red/green/yellow/blue
                // semantics carry through whether the user reads the
                // glyph or the event word.
                Image(systemName: entry.glyph)
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .foregroundStyle(eventInk)
                    .frame(width: 14, alignment: .center)
                // Time is fixed-width so rows scan cleanly by time
                // across the tail. The new compact format
                // (`HH:mm` today, `MMM d HH:mm` past) is
                // ~80pt — half the previous column's width.
                Text(entry.time)
                    .font(.cairnScaled(size: 11.5, design: .monospaced))
                    .foregroundStyle(t.textHint)
                    .frame(width: 80, alignment: .leading)
                // Event hugs its content (no fixed column) — a short
                // name like "sync" sits right next to its message
                // rather than drifting out to the width of the longest
                // possible event. Ragged message-start columns read a
                // bit busier, but the cost of fixed-width dead space
                // was worse.
                Text(entry.event)
                    .font(.cairnScaled(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(eventInk)
                    .fixedSize()
                Text(entry.message)
                    .font(.cairnScaled(size: 11.5, design: .monospaced))
                    .foregroundStyle(t.textMuted)
                    .lineLimit(1)
                    .fixedSize()
                // RunId suffix follows the message inline (no Spacer).
                // A Spacer in a 2D-scrolling row stretches to the
                // viewport's proposed width, capping the row's intrinsic
                // width at the viewport — horizontal scroll then
                // bounces elastically with nothing to reveal.
                if !entry.runIdSuffix.isEmpty {
                    Text(entry.runIdSuffix)
                        .font(.cairnScaled(size: 11, design: .monospaced))
                        .foregroundStyle(runIdSuffixColor)
                        .padding(.leading, 12)
                        .fixedSize()
                }
            }
            // Stretch the row to `rowWidth` so the tap target spans the
            // full content width regardless of intrinsic-row width.
            // Background painting moved to the enclosing JournalGroup
            // container — rows are transparent.
            .frame(width: rowWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tap = drill into run detail (when runId resolves);
        // long-press = open the raw-JSON sheet for the underlying
        // `JournalEntry`. Long-press is independent of `isTappable` so
        // diagnostic inspection works on every row, including
        // sync-only events that don't open run detail.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in onLongPress() }
        )
        // Disabling the row both for hit-testing and for the wrapping
        // button so untappable rows match the previous render exactly.
        // The long-press gesture above is attached via
        // `.simultaneousGesture` so it survives the tap disable.
        .allowsHitTesting(isTappable)
    }

    /// Severity tier → token color. Mirrors the event-color mapping in
    /// `eventColor` but reads off the pre-computed `Severity` enum so
    /// the dot can stay consistent even if event names change.
    private var severityColor: Color {
        switch entry.severity {
        case .info:  return t.textHint
        case .ok:    return t.verifiedInk
        case .warn:  return t.pendingInk
        case .error: return t.dangerInk
        }
    }
}

// MARK: - Sub-views

/// Shared palette for small tinted pills / progress bars. Internal so
/// `ProgressBar` (reused by `InitialScanScreen`) can reference it across
/// files in this module without duplicating the enum.
enum ChipTone {
    case verified, danger, pending, info, neutral
}

private struct Chip: View {
    let label: String
    let tone: ChipTone

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.cairnScaled(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(inkColor)
        .background(softColor)
        .clipShape(Capsule())
    }

    private var softColor: Color {
        switch tone {
        case .verified: t.verifiedSoft
        case .danger:   t.dangerSoft
        case .pending:  t.pendingSoft
        case .info:     t.infoSoft
        case .neutral:  t.surfaceAlt
        }
    }
    private var inkColor: Color {
        switch tone {
        case .verified: t.verifiedInk
        case .danger:   t.dangerInk
        case .pending:  t.pendingInk
        case .info:     t.infoInk
        case .neutral:  t.textBody
        }
    }
    private var dotColor: Color { inkColor.opacity(0.85) }
}

/// 4pt capsule progress bar. Widened access so `InitialScanScreen`
/// can reuse the exact same visual — keeping progress styling consistent
/// across every surface that shows one.
struct ProgressBar: View {
    let fraction: Double
    let tone: ChipTone
    /// Optional accessibility label. Without it, VoiceOver users get
    /// no signal that a progress indicator exists. Callers in the
    /// sync / initial-scan paths supply a context-specific label like
    /// "Scan progress"; visual-only progress bars (run-detail rows)
    /// can leave it nil and the bar stays accessibility-hidden.
    let accessibilityLabel: String?

    @Environment(\.cairnTokens) private var t

    init(fraction: Double, tone: ChipTone, accessibilityLabel: String? = nil) {
        self.fraction = fraction
        self.tone = tone
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.divider).frame(height: 4)
                Capsule().fill(fillColor).frame(width: geo.size.width * fraction, height: 4)
            }
        }
        .frame(height: 4)
        .modifier(ProgressBarAccessibility(
            fraction: fraction,
            label: accessibilityLabel
        ))
    }

    private var fillColor: Color {
        switch tone {
        case .pending: t.pending
        case .danger:  t.danger
        case .verified: t.verified
        case .info:    t.info
        case .neutral: t.textMuted
        }
    }
}

/// Conditional accessibility wiring for `ProgressBar`. When a caller
/// supplies a label the bar becomes a discoverable progress element
/// with a percent value (e.g. "Scan progress, 42%"); otherwise it's
/// hidden from VoiceOver so decorative usages don't add noise to the
/// rotor.
private struct ProgressBarAccessibility: ViewModifier {
    let fraction: Double
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%"))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

private struct RunRow: View {
    let run: CairnFixtures.RunFixture
    let onOpen: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                // Leading-edge color stripe tinted by run outcome —
                // adds an at-a-glance color cue to a list that was
                // otherwise mostly neutral text. 3pt wide × full row
                // height, matching the Callout primitive's accent
                // stripe convention.
                Rectangle()
                    .fill(iconInk)
                    .frame(width: 3)
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(iconBg)
                            .frame(width: 30, height: 30)
                        Image(systemName: iconName)
                            .font(.cairnScaled(size: 13, weight: .semibold))
                            .foregroundStyle(iconInk)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(verb)
                                .font(.cairnScaled(size: 14, weight: .medium))
                                .foregroundStyle(t.text)
                            if run.restored > 0 {
                                Chip(label: "\(run.restored) restored", tone: .neutral)
                            }
                        }
                        HStack(spacing: 4) {
                            Text(CairnTimeHelpers.relativeTime(run.startedAt, now: Date()))
                                .font(.cairnScaled(size: 11.5))
                                .foregroundStyle(t.textHint)
                            Text("·")
                                .font(.cairnScaled(size: 11.5))
                                .foregroundStyle(t.textHint)
                            Text(String(run.id.suffix(8)))
                                .font(.cairnScaled(size: 10.5, design: .monospaced))
                                .foregroundStyle(t.textHint)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.cairnScaled(size: 12, weight: .semibold))
                        .foregroundStyle(t.textHint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var verb: String {
        if run.status == .aborted { return "Aborted" }
        if run.dryRun { return "Dry-run" }
        if run.trashed == 0 { return "No changes" }
        return "\(run.trashed) trashed"
    }

    private var iconName: String {
        if run.status == .aborted { return "exclamationmark.triangle.fill" }
        if run.dryRun { return "eye" }
        return "trash"
    }

    private var iconBg: Color {
        if run.status == .aborted { return t.dangerSoft }
        if run.dryRun { return t.pendingSoft }
        return t.verifiedSoft
    }

    private var iconInk: Color {
        if run.status == .aborted { return t.dangerInk }
        if run.dryRun { return t.pendingInk }
        return t.verifiedInk
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Status — steady (medium library)") {
    StatusScreen()
        .cairnTheme()
}

#Preview("Status — threshold tripped") {
    StatusScreen(appState: .thresholdTripped)
        .cairnTheme()
}

#Preview("Status — server down") {
    StatusScreen(degraded: .serverDown)
        .cairnTheme()
}

#Preview("Status — first-run dry-run nudge") {
    StatusScreen(appState: .dryRun, library: CairnFixtures.small)
        .cairnTheme()
}

#Preview("Status — dark") {
    StatusScreen()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
