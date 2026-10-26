import SwiftUI
import CairnCore

/// First-run indexing screen. Takes over the main window while the
/// initial full-library hash runs — that work populates
/// `LocalHashStore` with every asset's SHA1 and saves a
/// `PHPersistentChangeToken` baseline. Without that baseline, cairn
/// can't detect user deletions, so there's nothing useful to render on
/// the main tabs until the baseline lands.
///
/// Why its own screen (rather than a banner on Status):
///  - On large libraries the initial scan takes minutes to tens of
///    minutes. A banner-sized affordance buried in a scroll view makes
///    that feel incidental; dedicating the whole window makes the
///    magnitude visible and discourages the user from tapping around.
///  - Sets honest expectations about iOS foreground-only work:
///    "backgrounding pauses the scan" is core info that gets lost in a
///    secondary UI.
///  - Gives cancellation + resume a prominent home. Users expect to
///    be able to bail out of a multi-minute operation.
public struct InitialScanScreen: View {
    public let total: Int
    public let hashed: Int
    /// Assets with actual checksums in the store. Differs from `hashed`
    /// when assets are deferred (too large for foreground download) or
    /// skipped (above hard ceiling).
    public let indexed: Int
    /// Assets trust-seeded from the Immich server in this scan via the
    /// fast-initial-scan path (matched on `deviceAssetId`). These
    /// skipped local hashing entirely; their checksums came from
    /// server-computed SHA1. Surfaced as a dedicated stat alongside
    /// `hashed` so the user can see what was verified locally vs
    /// imputed. `0` when fast-initial-scan is off or no matches.
    public let imputed: Int
    /// Actual count of items in the deferred queue (will retry later).
    /// The gap `hashed - indexed - deferredQueueCount` = permanently
    /// skipped (above hard ceiling).
    public let deferredQueueCount: Int
    public let isActive: Bool
    public let startedAt: Date?
    /// When non-nil, the scan is *paused*: elapsed is this frozen value
    /// rather than a live `now - startedAt` computation. See
    /// `CairnAppModel.pausedSyncElapsedSeconds`.
    public let pausedElapsed: TimeInterval?
    /// Count of `hashed` at the start of the current session — i.e.,
    /// the resume baseline (cached entries from a prior run that we're
    /// crediting toward progress for visual continuity). Subtract from
    /// `hashed` for any rate / ETA computation; counting cached toward
    /// elapsed-rate makes the ETA wildly optimistic.
    public let initialHashed: Int
    /// Persisted per-asset hash duration (ms) from prior sessions on
    /// this device. When non-nil, shown as a bootstrap ETA on tap-
    /// Start before the live rate has warmed up — at the low-
    /// confidence (orange) tier so the user reads it as provisional.
    /// `nil` only on a fresh install.
    public let persistedRate: Double?
    /// Current high-level sync phase. Surfaced as a small label under
    /// the progress bar during pre-hashing (`.preparing`,
    /// `.fetchingServer`) so the user knows something is happening
    /// even before per-asset progress can advance. Hidden when
    /// `.hashing` (the existing X / Y counter is more informative)
    /// or when idle.
    public let phase: CairnAppModel.SyncPhase
    /// Live count of server assets received via paginated
    /// `listAllAssets`. Ticks up per page. Surfaced under the
    /// pre-phase label during `.preparing` on large libraries where
    /// the server fetch dominates wall-clock time and would
    /// otherwise look frozen for tens of seconds to many minutes.
    public let serverAssetsFetched: Int
    /// Best-known total server asset count (from `assetStatistics()`),
    /// when available. When non-nil, the fetched-count line shows
    /// "X / Y assets" with a proportional bar instead of an open
    /// counter.
    public let serverAssetsExpected: Int?
    /// Live count of phone assets enumerated during the pre-hash library
    /// scan. `nil` outside that phase. Rendered as its own line so the
    /// scan doesn't drive the main bar to 100% and snap back when hashing
    /// begins.
    public let scanned: Int?
    @Binding public var settings: CairnSettings
    public let onStart: () -> Void
    public let onCancel: () -> Void
    public let onStartOver: () -> Void
    public let onDismiss: () -> Void

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var optionsExpanded: Bool = false
    /// Latched true the moment the user taps "Stop indexing." The
    /// scan's actual cancellation can take a moment (the orchestrator
    /// finishes the in-flight hash batch before honoring it), so the
    /// UI flips to a "Stopping…" affordance with a spinner immediately
    /// — the user sees their tap registered without waiting for
    /// `isActive` to flip false. Reset on the next `isActive`
    /// transition (in either direction) so a re-start works cleanly.
    @State private var cancelRequested: Bool = false

    // MARK: - ETA sample-and-hold state

    /// Last published ETA value. Visible to the user as the REMAINING
    /// cell. Held stable between re-publishes so the displayed number
    /// doesn't bounce on every TimelineView tick — the underlying rate
    /// computation re-runs on every body re-eval, but the user only
    /// sees a fresh value when enough new evidence has accumulated.
    @State private var publishedEta: TimeInterval? = nil
    /// Wall-clock at the most recent ETA publish. Combined with
    /// `publishedEtaHashed`, decides when the next publish is allowed.
    @State private var publishedEtaAt: Date? = nil
    /// `hashed` value at the most recent ETA publish. Re-publish gate is
    /// "at least N more assets hashed since last publish OR M seconds
    /// elapsed" — whichever fires first.
    @State private var publishedEtaHashed: Int = 0
    /// Republish when at least this many additional assets have
    /// hashed since the last publish. Faster scans get more frequent
    /// updates; slow iCloud-bound scans coast on the time floor below.
    private static let etaRepublishMinAssets: Int = 50
    /// Republish at least this often regardless of hash velocity, so
    /// the user sees periodic refreshes during long iCloud-bound waits
    /// even if no new asset has finished. Kept above 5s so the visible
    /// value isn't visually thrashing.
    private static let etaRepublishMinSeconds: TimeInterval = 8

    /// Rolling window of recent **raw** live ETAs (one per publish
    /// tick). Used for two purposes:
    ///   1. Computing CV → drives confidence color. The CV needs to
    ///      reflect actual volatility of the underlying rate, so it
    ///      operates on the un-smoothed values.
    ///   2. Computing the median → published value (display). Median
    ///      is robust to single outlier bursts (e.g., one fast batch
    ///      of cached hashes after a slow iCloud wait), so the user
    ///      sees a stable number even when the cumulative rate is
    ///      jumpy on a heterogeneous workload.
    @State private var recentLiveEtas: [TimeInterval] = []
    private static let etaSampleWindowSize: Int = 5

    /// Rolling buffer of `(time, cumulative-hashed)` checkpoints used
    /// to compute a *recent-window* hashing rate that adapts to
    /// conditions changing mid-scan. The cumulative rate
    /// (`elapsed / sessionWork`) underestimates ETA badly when a fast
    /// early phase (locally-cached photos) gives way to a slow phase
    /// (iCloud-pending originals downloading at 2-15s each); the
    /// recent-window rate catches that within `etaRateWindowSeconds`
    /// instead of taking the entire session to converge. Kept capped
    /// by both time (filtered on read) and sample count (filtered on
    /// write) so memory stays bounded under fast-emit conditions.
    @State private var rateSamples: [(date: Date, hashed: Int)] = []
    /// Time horizon for the recent-window rate. 90 seconds is the
    /// sweet spot between "long enough to smooth single-asset
    /// outliers" and "short enough to adapt when iCloud throttling
    /// kicks in." If a single iCloud-bound asset takes 30s, the
    /// window still holds 2-3 samples of recent activity for the
    /// rate computation; a multi-minute hashing-rate shift surfaces
    /// in the visible ETA within ~one window.
    private static let etaRateWindowSeconds: TimeInterval = 90
    /// Hard cap on rate-sample buffer size. Bounds memory regardless
    /// of emit rate. 200 covers ~3 minutes of one-per-second emits;
    /// faster emit rates trim down naturally via the time filter.
    private static let etaRateSampleCap: Int = 200
    /// Minimum samples before CV is meaningful. With 2 samples the
    /// CV is just `|a-b| / ((a+b)/2)` — too noisy. 3 is the smallest
    /// useful window.
    private static let etaCvMinSamples: Int = 3
    /// CV thresholds for confidence tiering. Values were picked from
    /// what feels right for a long-running ETA — 5% drift across 5
    /// samples is "stable", 15%+ is "bouncing." Tunable once we see
    /// these in the wild.
    private static let etaCvHighConfidenceMax: Double = 0.05
    private static let etaCvMediumConfidenceMax: Double = 0.15

    public init(
        total: Int,
        hashed: Int,
        indexed: Int = 0,
        imputed: Int = 0,
        deferredQueueCount: Int = 0,
        isActive: Bool,
        startedAt: Date?,
        pausedElapsed: TimeInterval? = nil,
        initialHashed: Int = 0,
        persistedRate: Double? = nil,
        phase: CairnAppModel.SyncPhase = .idle,
        serverAssetsFetched: Int = 0,
        serverAssetsExpected: Int? = nil,
        scanned: Int? = nil,
        settings: Binding<CairnSettings> = .constant(.defaults),
        onStart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onStartOver: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) {
        self.total = total
        self.hashed = hashed
        self.indexed = indexed
        self.imputed = imputed
        self.scanned = scanned
        self.deferredQueueCount = deferredQueueCount
        self.isActive = isActive
        self.startedAt = startedAt
        self.pausedElapsed = pausedElapsed
        self.initialHashed = initialHashed
        self.persistedRate = persistedRate
        self.phase = phase
        self.serverAssetsFetched = serverAssetsFetched
        self.serverAssetsExpected = serverAssetsExpected
        self._settings = settings
        self.onStart = onStart
        self.onCancel = onCancel
        self.onStartOver = onStartOver
        self.onDismiss = onDismiss
    }

    // MARK: - Derived state

    /// Fraction complete in `0...1`. Clamped against `total == 0`
    /// (which happens briefly before the fetch enumerates).
    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(hashed) / Double(total))
    }

    /// Elapsed = frozen paused value when paused, else live
    /// `now - startedAt`. When both are nil, returns nil (no scan
    /// has run yet this session).
    ///
    /// Two variants: `elapsedTime(now:)` takes an explicit current
    /// time so a `TimelineView` tick can drive periodic re-evaluation
    /// of the displayed ELAPSED cell. `elapsed` (no-arg) uses
    /// `Date()` — kept for internal computations (ETA derivation,
    /// confidence tiers) where the precise tick alignment doesn't
    /// matter.
    private func elapsedTime(now: Date) -> TimeInterval? {
        if let pausedElapsed { return pausedElapsed }
        guard let startedAt else { return nil }
        return now.timeIntervalSince(startedAt)
    }

    private var elapsed: TimeInterval? { elapsedTime(now: Date()) }

    /// True when the scan has run and been interrupted — progress is
    /// frozen at the last known values. Drives the paused CTA layout.
    private var isPaused: Bool {
        !isActive && hashed > 0
    }

    /// Minimum session-only assets that must hash before we publish
    /// an ETA. Lower values produce wildly bumpy estimates because
    /// the early sample is dominated by whichever assets PhotoKit
    /// happened to surface first (small / locally-cached hash in
    /// ~50ms, iCloud-fetched can take 8s+). 30 is empirically enough
    /// for a stable rate across mixed-storage libraries.
    private static let etaWarmupAssets: Int = 30
    /// Minimum wall-clock seconds before we publish an ETA. Even with
    /// 30 fast hashes, displaying "ETA = 1.2s" the first second of a
    /// scan sets the wrong expectation. Combined with the asset-count
    /// floor, this ensures the rate sample is wide enough to be honest.
    private static let etaWarmupSeconds: TimeInterval = 5

    /// Linear ETA, computed against **session-only** progress so a
    /// resumed scan that starts at `hashed=3327` doesn't divide ~0
    /// elapsed by a large cached count and report ~0s remaining.
    /// Counts cached entries toward the visible counter (continuity)
    /// but excludes them from the rate basis. Two warm-up gates keep
    /// the early estimate from being noise:
    ///   1. At least `etaWarmupAssets` actually-hashed-this-session.
    ///   2. At least `etaWarmupSeconds` wall-clock since session start.
    /// Returns `nil` until both pass.
    ///
    /// **This is the live computation.** `publishedEta` (below) is the
    /// sample-and-hold variant the user actually sees — it only
    /// republishes from this when enough new evidence has accumulated,
    /// so the visible value doesn't thrash on every render.
    ///
    /// `total - hashed` (rather than `total - sessionWork`) for the
    /// remaining-work term: cached entries don't contribute to elapsed,
    /// but they DO reduce the work that's left.
    private var liveEtaSeconds: TimeInterval? {
        guard let elapsed, total > hashed else { return nil }
        let sessionWork = max(0, hashed - initialHashed)
        guard sessionWork >= Self.etaWarmupAssets,
              elapsed >= Self.etaWarmupSeconds else { return nil }
        let remaining = Double(total - hashed)
        let cumulativeEta = (elapsed / Double(sessionWork)) * remaining

        // Recent-window rate: how fast we've been processing in the
        // last `etaRateWindowSeconds`. Falls back to cumulative when
        // the window is too small (early in the scan, sparse emits)
        // or hasn't produced any movement (paused, stuck on a single
        // long iCloud download). The cumulative branch is the
        // legacy behavior; the win is in taking the *higher* of the
        // two below — when conditions degrade mid-scan, recent
        // catches the slowdown long before cumulative converges.
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.etaRateWindowSeconds)
        guard let oldestInWindow = rateSamples.first(where: { $0.date >= cutoff }),
              oldestInWindow.hashed < hashed
        else {
            return cumulativeEta
        }
        let windowDuration = now.timeIntervalSince(oldestInWindow.date)
        let windowWork = hashed - oldestInWindow.hashed
        guard windowDuration > 0, windowWork > 0 else { return cumulativeEta }
        let recentEta = (windowDuration / Double(windowWork)) * remaining

        // Pessimistic aggregate: when the recent rate is slower than
        // the long-run rate, that's a real signal — iCloud throttling
        // is engaging, the iCloud-pending share of remaining work is
        // higher than the locally-cached early phase, hashing is
        // genuinely degrading. Surface that to the user instead of
        // smoothing it away. When recent ≈ cumulative (stable
        // conditions), the two return ~the same value and there's no
        // user-visible difference.
        return max(cumulativeEta, recentEta)
    }

    /// Bootstrap ETA derived from the device's last persisted per-
    /// asset rate (`persistedRate`, in ms). Available the moment the
    /// user taps Start — before any session-only data has been
    /// gathered — so the REMAINING cell shows a provisional number
    /// instead of "estimating…". Always rendered at low confidence
    /// (`.low` → orange) since the rate may be stale (different
    /// network, different remaining-asset composition). Returns `nil`
    /// on fresh installs (no prior runs) and when there's no work
    /// left.
    private var bootstrapEtaSeconds: TimeInterval? {
        guard let persistedRate, total > hashed else { return nil }
        return persistedRate / 1000.0 * Double(total - hashed)
    }

    /// What the publish loop considers the "current best ETA": live
    /// when warmup is complete, bootstrap otherwise. The live value
    /// always wins when available so a stale persisted rate doesn't
    /// keep masking real session data.
    private var candidateEtaSeconds: TimeInterval? {
        liveEtaSeconds ?? bootstrapEtaSeconds
    }

    /// Decide whether to publish the live ETA into the user-visible
    /// `publishedEta` slot. Three independent rules; any can trigger:
    ///   1. **First publish** — there's a live value but nothing's been
    ///      shown yet. Switch immediately so the user sees a number
    ///      the moment warmup ends rather than continuing to read
    ///      "estimating…".
    ///   2. **Asset delta** — at least `etaRepublishMinAssets` new
    ///      assets hashed since last publish. Fast scans tick the
    ///      number faster; the rate is also more reliable so we can
    ///      afford to refresh it.
    ///   3. **Time floor** — at least `etaRepublishMinSeconds` since
    ///      last publish, regardless of asset velocity. Keeps the
    ///      number from going stale during a long iCloud wait, but
    ///      doesn't fire so often that the user notices.
    /// Called from `.onChange(of: hashed)` (every progress emit) and
    /// from a TimelineView tick to handle the time-floor case.
    private func reconsiderPublishedEta(now: Date) {
        // Gate on active state — when the user pauses/cancels, the
        // TimelineView keeps ticking and we don't want to keep
        // republishing while there's no live data feeding the
        // computation. Without this guard, a paused screen would
        // flicker between the existing published value and the
        // bootstrap value as the periodic tick re-derived candidates.
        guard isActive else { return }
        guard let candidate = candidateEtaSeconds else { return }
        guard let lastAt = publishedEtaAt else {
            publishEta(candidate, at: now)
            return
        }
        let assetDelta = hashed - publishedEtaHashed
        let secondsDelta = now.timeIntervalSince(lastAt)
        if assetDelta >= Self.etaRepublishMinAssets || secondsDelta >= Self.etaRepublishMinSeconds {
            publishEta(candidate, at: now)
        }
    }

    /// Single point that mutates the published-ETA state. Adds the
    /// raw live value to the sample window (for CV) and publishes
    /// the median of that window (for display). The median is robust
    /// against single-burst outliers — one fast batch of cached
    /// hashes after a long iCloud wait won't drag the displayed value
    /// from "30min" to "55s" the way a raw cumulative rate would.
    private func publishEta(_ value: TimeInterval, at now: Date) {
        recentLiveEtas.append(value)
        if recentLiveEtas.count > Self.etaSampleWindowSize {
            recentLiveEtas.removeFirst(recentLiveEtas.count - Self.etaSampleWindowSize)
        }
        publishedEta = Self.median(of: recentLiveEtas) ?? value
        publishedEtaAt = now
        publishedEtaHashed = hashed
    }

    /// Median of a `TimeInterval` array. Used for outlier-robust
    /// publishing; CV uses mean/stddev so they coexist on the same
    /// underlying buffer (`recentLiveEtas`). Returns `nil` for empty
    /// input. Even-sized arrays return the average of the two middles.
    static func median(of samples: [TimeInterval]) -> TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    /// Reset all sample-and-hold state. Called when the scan transitions
    /// out of active (cancel, complete, dismiss) so the next session
    /// starts with a clean warmup.
    private func resetEtaPublishState() {
        publishedEta = nil
        publishedEtaAt = nil
        publishedEtaHashed = 0
        recentLiveEtas.removeAll(keepingCapacity: true)
        rateSamples.removeAll(keepingCapacity: true)
    }

    /// Display string for the "REMAINING" cell. Distinguishes between
    /// "we haven't started yet" (pre-start), "still warming up the
    /// rate sample" (active but ETA not yet computable), and a real
    /// number. Reads `publishedEta` (sample-and-hold) so the visible
    /// value doesn't bounce on every render.
    private var remainingDisplay: String {
        guard isActive || isPaused else { return "—" }
        if let eta = publishedEta { return Self.formatDuration(eta) }
        return "estimating…".loc
    }

    /// Coefficient of variation across the recent published-ETA
    /// window. Returns `nil` when fewer than `etaCvMinSamples` are
    /// in the window or when the mean is non-positive (degenerate).
    /// Used as the primary confidence signal: stability of the
    /// estimate is what "confident" actually means — sample size
    /// alone says "we have data," not "the data agrees."
    private var etaCoefficientOfVariation: Double? {
        Self.coefficientOfVariation(of: recentLiveEtas, minSamples: Self.etaCvMinSamples)
    }

    /// Pure computation extracted for unit-testing without
    /// instantiating a SwiftUI view. CV = stddev / mean. Returns
    /// `nil` when below `minSamples` or when mean is non-positive
    /// (CV would be undefined or negative).
    static func coefficientOfVariation(of samples: [TimeInterval], minSamples: Int) -> Double? {
        guard samples.count >= minSamples else { return nil }
        let n = Double(samples.count)
        // Imperative loops rather than `samples.reduce(...)` with a
        // capturing closure — the closure form crashed
        // swiftpm-testing-helper with SIGTRAP during test execution
        // on Swift 6.2.4 / 6.3.2 (the trampoline that wraps
        // captured `mean` for the `acc + ((x - mean) * (x - mean))`
        // body seems to fault). Same semantics, no captures.
        var sum: Double = 0
        for s in samples { sum += s }
        let mean = sum / n
        guard mean > 0 else { return nil }
        var variance: Double = 0
        for s in samples {
            let diff = s - mean
            variance += diff * diff
        }
        variance /= n
        return variance.squareRoot() / mean
    }

    /// Confidence in the published ETA, drives the REMAINING cell color:
    ///   - `.unknown` — no published ETA (warmup or paused). Renders
    ///     in `textMuted`. The "estimating…" copy carries the meaning.
    ///   - `.low` — bootstrap-only (no live data yet) OR small session
    ///     sample (<100 assets) OR high CV across recent estimates
    ///     (≥15%, the value is bouncing). Pending-tone (orange) reads
    ///     as "ballpark, take with grain of salt."
    ///   - `.medium` — moderate stability (CV in 5%-15% range).
    ///     Neutral textBody — informative but not authoritative.
    ///   - `.high` — stable (CV <5%) and adequate sample. Verified-
    ///     tone (green) — the figure has been holding steady.
    ///
    /// CV thresholds: 5% / 15% — picked empirically. A 10-minute ETA
    /// with CV=15% means recent estimates are spread by ±90s; that's
    /// worth flagging. CV=5% means ±30s on the same estimate — tight.
    private var etaConfidence: EtaConfidence {
        guard publishedEta != nil else { return .unknown }
        // Bootstrap-only (no live data yet): always low. The persisted
        // rate may be from a different network / library composition,
        // so we mark it provisional even though it's the most informed
        // guess we have.
        guard liveEtaSeconds != nil else { return .low }
        // Sample-size floor: under 100 assets the CV across only a few
        // samples can look spuriously stable (e.g., two early local-
        // hashes give CV ~0). Require enough total session work before
        // we trust the CV signal.
        let sessionWork = max(0, hashed - initialHashed)
        if sessionWork < 100 { return .low }
        // Not enough samples accumulated yet for CV — fall back to
        // size-based tiering until the window fills. Most syncs hit
        // CV-eligibility within ~24s (3 samples × 8s republish floor).
        guard let cv = etaCoefficientOfVariation else {
            return sessionWork >= 300 ? .medium : .low
        }
        if cv < Self.etaCvHighConfidenceMax  { return .high }
        if cv < Self.etaCvMediumConfidenceMax { return .medium }
        return .low
    }

    private enum EtaConfidence { case unknown, low, medium, high }

    /// Color for the REMAINING cell, derived from `etaConfidence`.
    /// Three-tier traffic-light gradient — orange → yellow → green —
    /// so each tier is visually distinct rather than collapsing
    /// medium into "neutral text" (which read as confident at a
    /// glance even when the underlying CV was high).
    private var remainingColor: Color {
        switch etaConfidence {
        case .unknown: return t.textMuted   // estimating…
        case .low:     return t.accentInk   // carrot orange — bouncing
        case .medium:  return t.pendingInk  // tuscan sun — moderate drift
        case .high:    return t.verifiedInk // seaweed green — stable
        }
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                heroMark
                headline
                subtext
                progressCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                expectationsCallout
                scanOptionsCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                dismissButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .background(t.bg)
        // Keyboard dismissal: drag the scroll to interactively
        // pull the numpad away, or tap empty chrome.
        .scrollDismissesKeyboard(.interactively)
        .cairnDismissKeyboardOnBackgroundTap()
        // ETA sample-and-hold:
        // - On every progress emit, reconsider whether to republish
        //   (the asset-delta gate triggers fast scans).
        // - On a hard reset (hashed → 0), drop the held value so a
        //   fresh sign-in or start-over begins with a clean warmup.
        //   We do NOT reset on `isActive → false` (pause/cancel) —
        //   keeping the last published value visible during pause
        //   gives the user context for what they're resuming, and
        //   avoids the flicker → bootstrap-republish dance the user
        //   was seeing on Stop.
        .onChange(of: hashed) { old, new in
            if new == 0 && old > 0 {
                resetEtaPublishState()
            }
            recordRateSample(hashed: new, at: Date())
            reconsiderPublishedEta(now: Date())
        }
    }

    /// Append a checkpoint to `rateSamples` and trim. Called on every
    /// `hashed` progress emit (which is the only signal we get from
    /// the reconciler about session work advancing). Trims by both
    /// time (drop anything older than 2× window so partial reads
    /// during transient back-pressure still have headroom) and count
    /// (cap at `etaRateSampleCap` to bound memory under fast-emit
    /// conditions). Cheap: ~one comparison per existing sample.
    private func recordRateSample(hashed: Int, at now: Date) {
        guard isActive else { return }
        rateSamples.append((date: now, hashed: hashed))
        let cutoff = now.addingTimeInterval(-Self.etaRateWindowSeconds * 2)
        if rateSamples.first?.date ?? now < cutoff {
            rateSamples.removeAll { $0.date < cutoff }
        }
        if rateSamples.count > Self.etaRateSampleCap {
            rateSamples.removeFirst(rateSamples.count - Self.etaRateSampleCap)
        }
    }

    private var heroMark: some View {
        // Rich multi-color rendering — this screen is a gaze-dwell
        // surface and wants the detailed art rather than the small
        // theme-responsive variant used in nav chrome.
        CairnHeroMark(size: 72)
            .padding(.bottom, 20)
    }

    private var headline: some View {
        Text("Indexing your library".loc)
            .font(.cairnScaled(size: 26, weight: .semibold))
            .tracking(-0.5)
            .foregroundStyle(t.text)
            .padding(.bottom, 8)
    }

    private var hasCache: Bool { hashed > 0 && !isActive }

    private var subtext: some View {
        Group {
            if hasCache {
                if CairnL10n.isChinese {
                    (Text.cairnWord + Text(" 发现上次运行缓存的 \(hashed.formatted(.number)) 个哈希。轻点继续以从中断处继续。"))
                } else {
                    (Text.cairnWord + Text(" found \(hashed.formatted(.number)) cached hashes from a previous run. Tap resume to pick up where you left off."))
                }
            } else {
                if CairnL10n.isChinese {
                    (Text.cairnWord + Text(" 会为每张照片计算一次哈希，以便区分真实删除与同步异常。这仅在首次运行时执行。"))
                } else {
                    (Text.cairnWord + Text(" hashes every photo once so it can tell a deletion apart from a sync hiccup. This only happens on first run."))
                }
            }
        }
        .font(.cairnScaled(size: 14))
        .foregroundStyle(t.textMuted)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
    }

    private var progressCard: some View {
        CairnCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(hashed.formatted(.number)) / \(total.formatted(.number))")
                        .font(.cairnScaled(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.text)
                    Text("processed".loc)
                        .font(.cairnScaled(size: 14))
                        .foregroundStyle(t.textMuted)
                    Spacer()
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.cairnScaled(size: 13, design: .monospaced).monospacedDigit())
                        .foregroundStyle(t.textMuted)
                }
                ProgressBar(fraction: fraction, tone: .pending, accessibilityLabel: "Initial scan progress".loc)
                if let prePhaseLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dotted.circle")
                            .font(.cairnScaled(size: 10))
                            .foregroundStyle(t.pendingInk)
                        Text(prePhaseLabel.loc)
                            .font(.cairnScaled(size: 12, weight: .medium))
                            .foregroundStyle(t.textBody)
                    }
                } else {
                    ProcessingBreakdown(indexed: indexed, deferredQueueCount: deferredQueueCount, processed: hashed)
                }
                if scanningLineVisible {
                    scanningLine
                }
                if imputed > 0 {
                    trustSeededLine
                }
                if serverFetchLineVisible {
                    serverFetchLine
                }
                timingStrip
            }
            .padding(18)
        }
    }

    /// Whether the server-fetch counter belongs on screen right now.
    /// Shows during the pre-hashing phases (where the X/Y processed
    /// counter hasn't taken over yet) any time we've received at
    /// least one server page. Hidden during `.hashing` and friends
    /// so it doesn't crowd the more-informative live counter.
    private var serverFetchLineVisible: Bool {
        guard serverAssetsFetched > 0 else { return false }
        switch phase {
        case .preparing, .fetchingServer, .imputingFromServer, .reconciling, .finalizing:
            return true
        case .hashing, .idle:
            return false
        }
    }

    /// One-line caption: "Fetched X server assets" (or "X / Y server
    /// assets" when we know the denominator). Reuses the
    /// `trustSeededLine` shape (icon + bold count + muted suffix) so
    /// the progress card reads as a coherent stat strip.
    private var serverFetchLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.cairnScaled(size: 10))
                .foregroundStyle(t.info)
            if let expected = serverAssetsExpected, expected > 0 {
                Text(CairnL10n.isChinese
                    ? "已获取 \(serverAssetsFetched.formatted(.number)) / \(expected.formatted(.number)) 项服务器资产"
                    : "\(serverAssetsFetched.formatted(.number)) / \(expected.formatted(.number)) server assets fetched")
                    .font(.cairnScaled(size: 12, weight: .medium))
                    .foregroundStyle(t.textBody)
            } else {
                Text(CairnL10n.isChinese
                    ? "已获取 \(serverAssetsFetched.formatted(.number)) 项服务器资产"
                    : "\(serverAssetsFetched.formatted(.number)) server assets fetched")
                    .font(.cairnScaled(size: 12, weight: .medium))
                    .foregroundStyle(t.textBody)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            CairnL10n.isChinese
                ? (serverAssetsExpected.map { "已获取 \(serverAssetsFetched) / \($0) 项服务器资产" } ?? "已获取 \(serverAssetsFetched) 项服务器资产")
                : (serverAssetsExpected.map { "Fetched \(serverAssetsFetched) of \($0) server assets" } ?? "Fetched \(serverAssetsFetched) server assets")
        )
    }

    /// Whether the library-scan counter belongs on screen. Shows during
    /// the pre-hash phases once enumeration has started, hidden once
    /// hashing takes over (the main counter is the live signal then).
    private var scanningLineVisible: Bool {
        guard let scanned, scanned > 0 else { return false }
        switch phase {
        case .preparing, .fetchingServer, .imputingFromServer, .reconciling, .finalizing:
            return true
        case .hashing, .idle:
            return false
        }
    }

    /// One-line caption for the pre-hash library walk: "X / Y phone assets
    /// scanned". Same icon+count+suffix shape as `serverFetchLine` so the
    /// progress card reads as a coherent stat strip. This is where the
    /// enumeration progress lives now that it no longer drives the main
    /// bar (which is reserved for hashing, so it fills exactly once).
    private var scanningLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.badge.magnifyingglass")
                .font(.cairnScaled(size: 10))
                .foregroundStyle(t.pendingInk)
            Text(CairnL10n.isChinese
                ? "已扫描 \((scanned ?? 0).formatted(.number)) / \(total.formatted(.number)) 张手机照片"
                : "\((scanned ?? 0).formatted(.number)) / \(total.formatted(.number)) phone assets scanned")
                .font(.cairnScaled(size: 12, weight: .medium))
                .foregroundStyle(t.textBody)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            CairnL10n.isChinese
                ? "已扫描 \((scanned ?? 0)) / \(total) 张手机照片"
                : "Scanned \(scanned ?? 0) of \(total) phone assets"
        )
    }

    /// One-line caption shown when the fast-initial-scan path
    /// trust-seeded any entries from the Immich server. Made distinct
    /// from the locally-hashed counter both visually (different icon +
    /// tint) and textually so the user can tell at a glance how many
    /// assets cairn verified itself versus how many it trusted from
    /// the server.
    private var trustSeededLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.cairnScaled(size: 10))
                .foregroundStyle(t.info)
            Text(CairnL10n.isChinese
                ? "\(imputed.formatted(.number)) 项信任服务器校验"
                : "\(imputed.formatted(.number)) trust-seeded from server")
                .font(.cairnScaled(size: 12, weight: .medium))
                .foregroundStyle(t.textBody)
            Text("(skipped local hashing)".loc)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            CairnL10n.isChinese
                ? "\(imputed) 项信任服务器校验，跳过本地哈希"
                : "\(imputed) assets trust-seeded from server, skipped local hashing"
        )
    }

    /// Phase label shown when the per-asset counter can't yet advance —
    /// the silent prelude window where the reconciler is fetching
    /// PhotoKit changes / building the cached-id set / resolving scope
    /// membership before any hash work begins. Surfaced as small text
    /// in the progress card. Returns `nil` once `.hashing` engages
    /// (the X/Y counter takes over) or when idle.
    private var prePhaseLabel: String? {
        guard isActive else { return nil }
        switch phase {
        case .preparing, .fetchingServer, .imputingFromServer, .reconciling, .finalizing:
            return phase.displayName.loc
        case .hashing, .idle:
            return nil
        }
    }

    /// Two-column stats strip under the progress bar. Wrapped in a
    /// single `TimelineView` ticking once per second so BOTH cells
    /// (ELAPSED + REMAINING) refresh on the same cadence. Previously
    /// only REMAINING was inside a TimelineView; ELAPSED only
    /// re-rendered when some other piece of view state changed,
    /// which meant during long pre-hash phases the elapsed clock
    /// could sit frozen for many seconds and then jump when the
    /// hash pass started ticking.
    @ViewBuilder
    private var timingStrip: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELAPSED".loc)
                        .font(.cairnScaled(size: 10, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(t.textHint)
                    Text(elapsedTime(now: context.date).map(Self.formatDuration) ?? "—")
                        .font(.cairnScaled(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.textBody)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("REMAINING".loc)
                        .font(.cairnScaled(size: 10, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(t.textHint)
                    Text(remainingDisplay)
                        .font(.cairnScaled(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(remainingColor)
                        .onChange(of: context.date) { _, now in
                            reconsiderPublishedEta(now: now)
                        }
                }
                Spacer()
            }
        }
    }

    /// Foreground-only warning. iOS suspends apps within ~5s of being
    /// backgrounded, so a 10-minute hash only progresses while the user
    /// has cairn open. Saying so up-front is less annoying than silently
    /// pausing.
    private var expectationsCallout: some View {
        Callout(.info, icon: "clock.arrow.circlepath") {
            if CairnL10n.isChinese {
                (Text("应用保持在前台时扫描速度最快。切换到后台时 iOS 会暂停处理；返回后 ") + .cairnWord + Text(" 将从中断处继续 — 无需重新计算哈希。"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                (Text("The scan runs fastest with the app open. iOS pauses the work when you background it; ") + .cairnWord + Text(" resumes where it left off when you return — nothing re-hashes."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Scan options

    /// Scan-relevant settings surfaced here so the user can tune before
    /// they commit to hashing thousands of photos — especially users
    /// with large iCloud-archived videos who'd otherwise discover the
    /// knob only after waiting for the first pass to defer them.
    /// Collapsed by default so the primary CTA stays the focus.
    private var scanOptionsCard: some View {
        CairnCard {
            VStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                        optionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.cairnScaled(size: 13, weight: .medium))
                            .foregroundStyle(t.textMuted)
                        Text("Scan options".loc)
                            .font(.cairnScaled(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        Spacer(minLength: 12)
                        Image(systemName: optionsExpanded ? "chevron.up" : "chevron.down")
                            .font(.cairnScaled(size: 11, weight: .semibold))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(optionsExpanded ? "Collapse scan options".loc : "Expand scan options".loc)

                if optionsExpanded {
                    RowDivider()
                    iCloudLimitRow
                    RowDivider()
                    InitialScanHardCeilingRow(mb: $settings.iCloudMaxEverBytesMB)
                    RowDivider()
                    ToggleRow(
                        "Keep screen on during sync".loc,
                        sub: "Prevents Auto-Lock while the sync is running. On by default for the first scan — the foreground hashing pass stalls if the device sleeps. Auto-disables after the first scan completes; re-enable from Settings → Library → Initial scan for any later big run.".loc,
                        value: $settings.keepScreenAwakeDuringSync
                    )
                }
            }
        }
    }

    /// Compact iCloud-download-limit slider. Uses the shared
    /// `SliderInputRow` primitive with the `.compact` style so the
    /// scan-options card stays dense. Int ↔ Double adapter inline
    /// because the setting is an Int but the primitive is Double-
    /// typed (matches slider semantics).
    private var iCloudLimitRow: some View {
        let binding = Binding<Double>(
            get: { Double(settings.iCloudDownloadLimitMB) },
            set: { settings.iCloudDownloadLimitMB = Int($0.rounded()) }
        )
        return SliderInputRow(
            label: "iCloud download limit".loc,
            sub: "Larger assets queue for background hashing instead of blocking the initial scan.".loc,
            value: binding,
            range: Double(CairnSettings.iCloudDownloadLimitMBRange.lowerBound)...Double(CairnSettings.iCloudDownloadLimitMBRange.upperBound),
            step: 5,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer,
            style: .compact
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if isActive {
            cancelButton
        } else if isPaused {
            VStack(spacing: 10) {
                startButton
                startOverButton
            }
        } else {
            startButton
        }
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.cairnScaled(size: 14, weight: .semibold))
                Text(hashed > 0 ? "Resume indexing".loc : "Start indexing".loc)
                    .font(.cairnScaled(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(t.primaryInk)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
    }

    private var cancelButton: some View {
        Button(action: {
            cancelRequested = true
            onCancel()
        }) {
            HStack(spacing: 8) {
                if cancelRequested {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(t.textMuted)
                }
                Text(cancelRequested ? "Stopping…".loc : "Stop indexing".loc)
                    .font(.cairnScaled(size: 14, weight: .semibold))
                    .tracking(0.66)
                    .foregroundStyle(cancelRequested ? t.textMuted : t.dangerInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(CairnPressStyle())
        .disabled(cancelRequested)
        .accessibilityLabel(cancelRequested ? "Stopping indexing".loc : "Stop indexing".loc)
        .onChange(of: isActive) { _, _ in
            // Reset on either transition so a fresh scan starts with a
            // clean Stop button, and the spinner doesn't latch if the
            // user cancels then starts again.
            cancelRequested = false
        }
    }

    /// Secondary "Start over" CTA visible only while paused. Distinct
    /// from Resume: wipes the partial hash cache so the next scan
    /// really begins from zero. Uses a quieter outline style so
    /// Resume stays the primary action.
    private var startOverButton: some View {
        Button(action: onStartOver) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.cairnScaled(size: 12, weight: .semibold))
                Text("Start over".loc)
                    .font(.cairnScaled(size: 14, weight: .medium))
            }
            .foregroundStyle(t.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
    }

    /// Tertiary "leave this screen" affordance. Always available
    /// regardless of scan state — users shouldn't feel locked to
    /// the progress view. Hashing is driven by a Task that isn't
    /// tied to this view's lifetime, so dismissing to main tabs
    /// leaves the scan running; the sync card's progress bar on
    /// Status picks up the same `syncProgress`, and the "Initial
    /// scan pending" banner routes back here when the user wants
    /// to check in.
    ///
    /// Copy adapts:
    ///   - fresh / pre-start → "Skip for now"
    ///   - active or paused → "Continue in app" (scan keeps going)
    @ViewBuilder
    private var dismissButton: some View {
        let label = (isActive || isPaused) ? "Continue in app".loc : "Skip for now".loc
        Button(action: onDismiss) {
            Text(label)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textHint)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format helpers

    /// Short duration ("1 min 23 sec", "12 sec", "2 hr 4 min"). We
    /// deliberately skip `DateComponentsFormatter` — its `.short` output
    /// ("1m, 23s") doesn't match the rest of the app's prose style.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if CairnL10n.isChinese {
            if h > 0 {
                return "\(h) 小时 \(m) 分"
            } else if m > 0 {
                return "\(m) 分 \(s) 秒"
            } else {
                return "\(s) 秒"
            }
        } else {
            if h > 0 {
                return "\(h) hr \(m) min"
            } else if m > 0 {
                return "\(m) min \(s) sec"
            } else {
                return "\(s) sec"
            }
        }
    }
}

// MARK: - Scan-option rows (local to this screen)

/// Compact variant of the hard-ceiling toggle + slider.
private struct InitialScanHardCeilingRow: View {
    @Binding var mb: Int?
    @Environment(\.cairnTokens) private var t

    /// Remembers the last enabled value so toggling off and back on
    /// restores what the user had set, not the cold-start default.
    /// See `HardCeilingRow` in SettingsScreen for the same pattern's
    /// rationale.
    @State private var rememberedValue: Int

    init(mb: Binding<Int?>) {
        self._mb = mb
        self._rememberedValue = State(initialValue: mb.wrappedValue ?? 1024)
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { mb != nil },
            set: { newValue in
                if newValue {
                    mb = rememberedValue
                } else {
                    if let current = mb {
                        rememberedValue = current
                    }
                    mb = nil
                }
            }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb ?? CairnSettings.iCloudMaxEverBytesMBRange.lowerBound) },
            set: { newValue in
                let rounded = Int(newValue.rounded())
                mb = rounded
                rememberedValue = rounded
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Never-touch ceiling".loc)
                    .font(.cairnScaled(size: 14))
                    .foregroundStyle(t.textBody)
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    // `t.verified` for the on-state — see SettingsScreen
                    // `HardCeilingRow` for the rationale; `t.text`
                    // resolves to bone in dark mode and gives no thumb
                    // contrast.
                    .tint(t.verified)
            }
            if mb != nil {
                Slider(
                    value: doubleBinding,
                    in: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                    step: 50
                )
                .tint(t.verified)
                HStack {
                    Text("Assets above this stay out of scope — ideal for multi-GB archived video.".loc)
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    EditableNumericField(
                        value: doubleBinding,
                        range: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                        step: 50,
                        unitSuffix: " MB",
                        format: { String(format: "%.0f", $0) },
                        parse: NumericInputParse.integer
                    )
                }
            } else {
                Text("Off. Every asset is eligible, however large.".loc)
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(t.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#if DEBUG
private struct InitialScanPreviewHost: View {
    @State var settings: CairnSettings = .defaults
    let total: Int
    let hashed: Int
    let imputed: Int
    let isActive: Bool
    let startedAt: Date?
    let pausedElapsed: TimeInterval?
    let phase: CairnAppModel.SyncPhase

    init(
        total: Int,
        hashed: Int,
        imputed: Int = 0,
        isActive: Bool,
        startedAt: Date?,
        pausedElapsed: TimeInterval?,
        phase: CairnAppModel.SyncPhase = .idle
    ) {
        self.total = total
        self.hashed = hashed
        self.imputed = imputed
        self.isActive = isActive
        self.startedAt = startedAt
        self.pausedElapsed = pausedElapsed
        self.phase = phase
    }

    var body: some View {
        InitialScanScreen(
            total: total,
            hashed: hashed,
            imputed: imputed,
            isActive: isActive,
            startedAt: startedAt,
            pausedElapsed: pausedElapsed,
            phase: phase,
            settings: $settings
        )
        .cairnTheme()
    }
}

#Preview("InitialScan — active mid-run") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -180), pausedElapsed: nil,
        phase: .hashing
    )
}

#Preview("InitialScan — fast-initial-scan mid-hash") {
    InitialScanPreviewHost(
        total: 600, hashed: 145, imputed: 3_618, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -22), pausedElapsed: nil,
        phase: .hashing
    )
}

#Preview("InitialScan — imputation phase") {
    InitialScanPreviewHost(
        total: 0, hashed: 0, imputed: 0, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -2), pausedElapsed: nil,
        phase: .imputingFromServer
    )
}

#Preview("InitialScan — paused (resumable)") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: false,
        startedAt: nil, pausedElapsed: 180
    )
}

#Preview("InitialScan — fresh (nothing hashed)") {
    InitialScanPreviewHost(
        total: 0, hashed: 0, isActive: false,
        startedAt: nil, pausedElapsed: nil
    )
}

#Preview("InitialScan — dark") {
    InitialScanPreviewHost(
        total: 4_218, hashed: 1_245, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -180), pausedElapsed: nil,
        phase: .hashing
    )
    .preferredColorScheme(.dark)
}

#Preview("InitialScan — dark fast-initial-scan") {
    InitialScanPreviewHost(
        total: 600, hashed: 145, imputed: 3_618, isActive: true,
        startedAt: Date(timeIntervalSinceNow: -22), pausedElapsed: nil,
        phase: .hashing
    )
    .preferredColorScheme(.dark)
}
#endif
