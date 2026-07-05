import Foundation

/// User-tunable configuration the iOS app (and CLI) persists between runs.
///
/// Intentionally excludes secrets (server URL, API key) — those have a
/// different security story and live in `SecretStore`, backed by Keychain
/// on iOS. Also excludes iOS-only concepts (Photos permission state,
/// Background Refresh state) which belong in the iOS target — `CairnCore`
/// stays pure Foundation + CryptoKit so the Kotlin port stays tractable.
///
/// Every field has a sensible default; a fresh install should be safe
/// without the user touching settings. See the plan doc's "Safety rails"
/// section for the rationale behind these specific defaults.
public struct CairnSettings: Sendable, Codable, Equatable {
    /// Abort a run if it would trash more than this percent of matched
    /// assets. **Stored in human-readable percent units: `1.0` means 1%.**
    /// Defense against a bug, permission regression, or library-wipe
    /// event cascading into a mass delete on the server.
    ///
    /// Note the unit difference vs `SafetyConfig.maxDeletePercent`,
    /// which is the same conceptual rail but stored as a *fraction*
    /// (`0.01` means 1%). The CLI converts via `/100.0` at the
    /// `SafetyRails.evaluate` boundary; the iOS app's
    /// `DryRunSheet.overPct` check uses these settings units directly.
    /// If you ever feed `settings.maxDeletePercent` into
    /// `SafetyConfig`, divide by 100 first.
    public var maxDeletePercent: Double

    /// Floor below which the percent rail is bypassed — on a small library
    /// (say 200 photos) 1% is 2 photos, which is noise. This sets the
    /// minimum run size that triggers the threshold check.
    public var minDeleteFloor: Int

    /// Local notification when a safety rail trips and a run is aborted.
    /// Default on — silently skipping a destructive-intent run that the
    /// user opted into is worse than one extra notification.
    public var notifyOnAbort: Bool

    /// Whether the journal records every API request or just headline
    /// events. Off by default because verbose journals grow quickly and
    /// can leak checksums into support bundles users share.
    public var verboseLogging: Bool

    /// How aggressively cairn acts on deletion candidates. See the plan
    /// doc's "Confirmed-deletion signal (Wave 4)" section for the full
    /// rationale.
    public var deletionStrictness: DeletionStrictness

    /// Number of days a confirmed-deleted checksum must age before it
    /// becomes eligible to trash. Gives the user a grace period to catch
    /// and recover from an accidental mass-offload before the server-side
    /// delete fires. Values outside `Self.quarantineDaysRange` are tolerated
    /// on decode (legacy files and manual edits round-trip unchanged); UI
    /// surfaces should clamp on write.
    public var quarantineDays: Int

    /// Permitted range for `quarantineDays`. `0` opts out (the held bucket
    /// is always empty). `90` caps cautious users at three months — long
    /// enough to recover from real mistakes, short enough to bound store
    /// growth and keep pending-review queues manageable.
    public static let quarantineDaysRange: ClosedRange<Int> = 0...90

    /// Per-asset iCloud-download soft limit (in megabytes) that the
    /// foreground hashing pipeline will accept. Assets whose combined
    /// unavailable-resource size exceeds this are **deferred**: queued
    /// into `DeferredHashStore` and drained later — a small batch on
    /// each subsequent incremental scan, or the whole queue during a
    /// `BGProcessingTask` slot (which ignores this soft limit entirely).
    ///
    /// Rationale: on iCloud-optimized libraries, large videos can take
    /// minutes each to fetch-then-hash. Without a limit, a first scan
    /// can stall for hours on a handful of multi-hundred-MB clips.
    /// Smaller values ship more work into the background bucket and
    /// make the foreground experience faster; larger values hash more
    /// on-demand but at the cost of responsiveness.
    public var iCloudDownloadLimitMB: Int

    /// Permitted range for `iCloudDownloadLimitMB`. `5` MB knocks out
    /// essentially every video and Live Photo motion track from the
    /// initial pass — aggressive. `500` MB lets almost everything
    /// through, approximating uncapped. Default `100` is a compromise
    /// that lets most short clips hash on the first pass while keeping
    /// multi-hundred-MB/GB videos in the background-drain bucket.
    public static let iCloudDownloadLimitMBRange: ClosedRange<Int> = 5...500

    /// Optional hard never-touch ceiling (in megabytes). Assets whose
    /// iCloud-download size exceeds this are **never hashed**, by any
    /// path — not foreground, not background. They're effectively
    /// out-of-scope for cairn: no checksum, not entered into
    /// `ObservedStore`, not added to `DeferredHashStore`. A consequence
    /// is that if the user later deletes them from iPhone, cairn won't
    /// propagate the deletion to Immich (because the checksum was never
    /// in `observed`). Use this for multi-GB iCloud-archived videos you
    /// want cairn to ignore entirely.
    ///
    /// `nil` = off (no hard ceiling, default). Values outside
    /// `iCloudMaxEverBytesMBRange` are tolerated on decode but should
    /// be clamped on write by the UI.
    public var iCloudMaxEverBytesMB: Int?

    /// Override for the system color scheme. Default is `.system` (follow
    /// iOS Settings). Users who prefer a fixed appearance — or who find
    /// one scheme more readable — can pin `.light` or `.dark` here.
    public var appearance: AppearanceOverride

    /// Surface a prominent Status banner when the total deletion
    /// backlog (held-by-quarantine + pending-review + eligible-to-
    /// trash) reaches this count. 0 disables the banner entirely.
    /// The existing pending-candidates card on Status surfaces the
    /// count regardless; this threshold is the escalation signal
    /// for "you've accumulated a lot — come take a look."
    public var deletionBacklogAlertThreshold: Int

    /// Max disk space for cached full-resolution thumbnails (per server).
    /// FIFO eviction when exceeded. Default 100 MB.
    public var thumbnailCacheCapMB: Int

    /// Max disk space for thumbhash placeholders (per server). Default 5 MB.
    /// ~180K assets at 28 bytes each — a safety net, not a practical limit.
    public var thumbhashCapMB: Int

    public static let thumbnailCacheCapMBRange: ClosedRange<Int> = 10...500
    public static let thumbhashCapMBRange: ClosedRange<Int> = 1...20

    /// Permitted range for `deletionBacklogAlertThreshold`. 0 opts
    /// out; 500 caps a truly noise-tolerant user. Count-based (not
    /// percent) so behavior doesn't drift with library size —
    /// percent-based safety exists separately on the trash run rail.
    public static let deletionBacklogAlertThresholdRange: ClosedRange<Int> = 0...500

    /// Permitted range for `iCloudMaxEverBytesMB` when set. `50` MB is
    /// below the default soft-limit so a sensible UI clamps it above
    /// that; `10240` MB (10 GB) is an aggressive upper bound covering
    /// essentially every personal-library case. Callers should clamp
    /// on write.
    public static let iCloudMaxEverBytesMBRange: ClosedRange<Int> = 50...10_240

    /// Which slice of the user's Photos library cairn manages. Default
    /// `.fullLibrary` matches the original behavior (every visible asset
    /// in the user library is in scope). `.selectedAlbums` restricts
    /// cairn's view to a hand-picked set of Photos albums (identified
    /// by `PHAssetCollection.localIdentifier`); photos outside those
    /// albums are silently ignored — never hashed, never proposed for
    /// trash, never enter the Observed / Confirmed flow until they're
    /// added to a selected album.
    public var indexingScope: IndexingScope

    /// How many times the retry driver will re-attempt a failed trash
    /// before parking the intent. Once this cap is hit, the intent stays
    /// in the queue (still visible to the user, still drainable on a
    /// manual "Retry now" tap) but the driver stops touching it
    /// automatically — a transient-looking failure that's actually a
    /// real, persistent problem (wrong API key, dead server) shouldn't
    /// flap forever. Default 5; clamped to `maxRetryAttemptsRange`.
    public var maxRetryAttempts: Int

    /// Permitted range for `maxRetryAttempts`. `1` means "one shot, then
    /// park" — basically opts out of automatic retry. `20` is generous
    /// for users on flaky home networks. Default `5` is a balance.
    public static let maxRetryAttemptsRange: ClosedRange<Int> = 1...20

    /// User-facing override for how clock times are rendered across
    /// the app — journal rows, run times, sync detail timeline.
    /// Default `.system` honors iOS Settings → General → Date & Time
    /// → 24-Hour Time, which is what most users expect; `.h12` and
    /// `.h24` are explicit overrides for users who want to pin a
    /// specific format regardless of the device preference (e.g. a
    /// 24-hour-preferring user temporarily on a US-locale loaner
    /// device).
    public var timeDisplayFormat: TimeDisplayFormat

    /// How many assets the foreground initial-scan hash pipeline will
    /// run concurrently. Drives the `TaskGroup` ceiling in
    /// `PhotoKitPersistentChangeReconciler.hashAssets` — higher values
    /// saturate iCloud bandwidth on network-bound libraries and win
    /// some NAND parallelism on local libraries, but raise peak memory
    /// (Live Photo videos / ProRes clips reserve tens of MB each during
    /// the fetch). Default 4 is the conservative value previous builds
    /// hardcoded; advanced users can raise it for faster initial scans
    /// on devices with headroom, or lower it on memory-pressed older
    /// hardware.
    ///
    /// Changes take effect on the next sync — the reconciler reads this
    /// at construction time, not per-batch, so changing it mid-scan
    /// doesn't retroactively widen the active TaskGroup.
    public var hashConcurrency: Int

    /// Permitted range for `hashConcurrency`. `1` opts out of parallelism
    /// entirely (useful for diagnosing thermal / memory issues by
    /// comparing serial vs parallel timing). `16` is the practical
    /// ceiling — beyond that, PhotoKit's per-asset overhead and
    /// SwiftData write serialization dominate and the next added task
    /// produces diminishing returns. UI clamps on write.
    public static let hashConcurrencyRange: ClosedRange<Int> = 1...16

    /// `hashConcurrency` forced into `hashConcurrencyRange`. The single
    /// place the clamp lives — a persisted file from a build with a
    /// wider range, or an out-of-bounds debug-tools poke, can't push an
    /// illegal width into the hash pipeline. Callers (the reconciler
    /// construction site) use this rather than re-deriving the bound.
    public var clampedHashConcurrency: Int {
        min(Self.hashConcurrencyRange.upperBound,
            max(Self.hashConcurrencyRange.lowerBound, hashConcurrency))
    }

    /// Opt-in switch for the incremental server-side sync path
    /// (`POST /api/sync/stream` change-data-capture instead of the
    /// paginated `search/metadata` rescan). Default **off** during
    /// initial roll-out so existing installs stay on the well-tested
    /// path until a user explicitly enables it.
    ///
    /// When on:
    ///   - First sync after enable: bootstraps via the stream with
    ///     `reset: true`, populating a per-(URL, userId) local cache.
    ///   - Subsequent syncs: stream only the changes since the last
    ///     ack — typically zero to tens of events instead of ~N/250
    ///     pages.
    ///
    /// On any stream failure (including missing `sync.*` scopes on
    /// the API key) the live-reconciliation path falls back to the
    /// paginated discovery, so flipping this on never blocks sync —
    /// the worst case is "no faster than before."
    ///
    /// Plan to flip the default to `true` once a full release cycle
    /// of beta soak-testing surfaces no regressions.
    public var useIncrementalServerSync: Bool

    /// Optional age cutoff on which phone deletions propagate to the
    /// server. When set to N (days), cairn ignores phone-delete events
    /// for any asset whose `PHAsset.creationDate` is older than
    /// `now - N`. The asset stays on Immich; no quarantine entry is
    /// written. Use case: you've already curated your Immich library
    /// and want to bulk-clean older photos off the phone without those
    /// deletions mirroring to the server.
    ///
    /// Only protects **old** photos. Recent deletions still propagate
    /// through the normal quarantine path — this isn't a "stop
    /// propagating everything" switch.
    ///
    /// Default `nil` (no cutoff; every deletion is in scope, matching
    /// the original behavior). Values outside `propagationMaxAgeDaysRange`
    /// are tolerated on decode for forward compatibility; UI should
    /// clamp on write.
    public var propagationMaxAgeDays: Int?

    /// Permitted range for `propagationMaxAgeDays` when set. `30` days
    /// is the smallest practical cutoff (anything tighter starts
    /// catching photos in normal recent-deletes-and-undo flows).
    /// `3650` days (~10 years) is an aggressive upper bound — most
    /// libraries don't have photos older than that — but lets users
    /// who want a very wide horizon still pick one. Default `nil`
    /// (off) when first enabled is up to the UI; reasonable starting
    /// values are 365 (one year) or 730 (two years).
    public static let propagationMaxAgeDaysRange: ClosedRange<Int> = 30...3650

    /// Fast initial scan: trust Immich's server-computed checksum for
    /// any phone asset whose `(originalFilename, creationDate)` pair
    /// matches an unambiguous non-trashed server row, and seed the
    /// local hash cache from the server instead of re-hashing
    /// locally. On iCloud-Optimized libraries this can drop initial
    /// scan from hours to seconds, since matched assets skip the
    /// original-resource download.
    ///
    /// (History note: originally joined on `deviceAssetId`, but
    /// Immich dropped that column from the asset schema in Apr 2026.
    /// The current join uses the closest stable proxy: filename +
    /// capture date, with strict unambiguity so collisions fall
    /// through to local hashing.)
    ///
    /// Only the matched subset is imputed; everything else (web
    /// uploads, photos from other devices, fresh-phone restore case,
    /// ambiguous filename collisions) still hashes locally. Imputed
    /// entries are flagged in the cache; the modDate-skip path
    /// automatically re-hashes any imputed asset whose pixel bytes
    /// later change. Deletions resolved through imputed entries are
    /// logged for telemetry.
    ///
    /// Default **off** — the user opts in at onboarding (or later in
    /// Settings) after seeing both paths explained. The tradeoff is
    /// non-trivial (much faster setup vs every checksum computed by
    /// cairn itself), so the choice is presented neutrally rather than
    /// taken silently.
    ///
    /// Design: `docs/active-design/fast-initial-scan-plan.md`.
    public var fastInitialScan: Bool

    /// Override iOS Auto-Lock while a sync is foreground-active.
    /// Sets `UIApplication.shared.isIdleTimerDisabled = true` for the
    /// duration of the sync; clears it when the sync ends (success,
    /// cancel, or error) and on app backgrounding. Only affects the
    /// auto-lock timer — pressing the side button to lock manually
    /// still works.
    ///
    /// Default **on**. The factory default is calibrated for the
    /// first-sync case (large library, multi-minute server fetch +
    /// imputation + local hashing, where letting the screen go dark
    /// pauses the foreground sync after iOS's ~30-second background
    /// grace expires). On first successful completion of the initial
    /// scan, cairn auto-flips this to `false` for the user — the
    /// per-sync battery cost isn't worth it for the seconds-long
    /// incremental syncs that follow. Users who later run a big
    /// onboarding round or bulk deletion can re-enable manually
    /// from Settings to keep the screen alive for that work.
    public var keepScreenAwakeDuringSync: Bool

    /// When on, the `DiagnosticLogFlusher` continuously polls OSLog and
    /// persists cairn's recent entries to a rolling disk file so the
    /// diagnostic export captures activity across app launches (the kind
    /// of cross-launch history needed for a useful bug report). Off by
    /// default — the periodic poll + file write is needless background
    /// work for users who aren't actively reporting an issue. Toggle it
    /// on, reproduce the problem, then Export. The export still works
    /// while off, just limited to the current process's OSLog buffer.
    public var persistentDiagnosticLogging: Bool

    public init(
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        notifyOnAbort: Bool = true,
        verboseLogging: Bool = false,
        deletionStrictness: DeletionStrictness = .strict,
        quarantineDays: Int = 14,
        iCloudDownloadLimitMB: Int = 100,
        iCloudMaxEverBytesMB: Int? = nil,
        appearance: AppearanceOverride = .system,
        deletionBacklogAlertThreshold: Int = 25,
        thumbnailCacheCapMB: Int = 100,
        thumbhashCapMB: Int = 5,
        indexingScope: IndexingScope = .fullLibrary,
        maxRetryAttempts: Int = 5,
        timeDisplayFormat: TimeDisplayFormat = .system,
        hashConcurrency: Int = 4,
        useIncrementalServerSync: Bool = false,
        fastInitialScan: Bool = false,
        propagationMaxAgeDays: Int? = nil,
        keepScreenAwakeDuringSync: Bool = true,
        persistentDiagnosticLogging: Bool = false
    ) {
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.notifyOnAbort = notifyOnAbort
        self.verboseLogging = verboseLogging
        self.deletionStrictness = deletionStrictness
        self.quarantineDays = quarantineDays
        self.iCloudDownloadLimitMB = iCloudDownloadLimitMB
        self.iCloudMaxEverBytesMB = iCloudMaxEverBytesMB
        self.appearance = appearance
        self.deletionBacklogAlertThreshold = deletionBacklogAlertThreshold
        self.thumbnailCacheCapMB = thumbnailCacheCapMB
        self.thumbhashCapMB = thumbhashCapMB
        self.indexingScope = indexingScope
        self.maxRetryAttempts = maxRetryAttempts
        self.timeDisplayFormat = timeDisplayFormat
        self.hashConcurrency = hashConcurrency
        self.useIncrementalServerSync = useIncrementalServerSync
        self.fastInitialScan = fastInitialScan
        self.propagationMaxAgeDays = propagationMaxAgeDays
        self.keepScreenAwakeDuringSync = keepScreenAwakeDuringSync
        self.persistentDiagnosticLogging = persistentDiagnosticLogging
    }

    /// The factory defaults. Kept as a single constant so tests and the
    /// "reset to defaults" UI path reference the same source of truth.
    public static let defaults: CairnSettings = CairnSettings()

    // Custom Codable so legacy payloads (written before newer fields
    // existed) decode cleanly: missing keys fall back to the current
    // default, matching how a fresh install would experience them.
    private enum CodingKeys: String, CodingKey {
        case maxDeletePercent, minDeleteFloor, notifyOnAbort
        case verboseLogging, deletionStrictness, quarantineDays
        case iCloudDownloadLimitMB, iCloudMaxEverBytesMB, appearance
        case deletionBacklogAlertThreshold
        case thumbnailCacheCapMB, thumbhashCapMB
        case indexingScope
        case maxRetryAttempts
        case timeDisplayFormat
        case hashConcurrency
        case useIncrementalServerSync
        case fastInitialScan
        case propagationMaxAgeDays
        case keepScreenAwakeDuringSync
        case persistentDiagnosticLogging
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CairnSettings.defaults
        self.maxDeletePercent = try c.decodeIfPresent(Double.self, forKey: .maxDeletePercent) ?? d.maxDeletePercent
        self.minDeleteFloor = try c.decodeIfPresent(Int.self, forKey: .minDeleteFloor) ?? d.minDeleteFloor
        self.notifyOnAbort = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAbort) ?? d.notifyOnAbort
        self.verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? d.verboseLogging
        self.deletionStrictness = try c.decodeIfPresent(DeletionStrictness.self, forKey: .deletionStrictness) ?? d.deletionStrictness
        self.quarantineDays = try c.decodeIfPresent(Int.self, forKey: .quarantineDays) ?? d.quarantineDays
        self.iCloudDownloadLimitMB = try c.decodeIfPresent(Int.self, forKey: .iCloudDownloadLimitMB) ?? d.iCloudDownloadLimitMB
        self.iCloudMaxEverBytesMB = try c.decodeIfPresent(Int.self, forKey: .iCloudMaxEverBytesMB) ?? d.iCloudMaxEverBytesMB
        self.appearance = try c.decodeIfPresent(AppearanceOverride.self, forKey: .appearance) ?? d.appearance
        self.deletionBacklogAlertThreshold = try c.decodeIfPresent(Int.self, forKey: .deletionBacklogAlertThreshold) ?? d.deletionBacklogAlertThreshold
        self.thumbnailCacheCapMB = try c.decodeIfPresent(Int.self, forKey: .thumbnailCacheCapMB) ?? d.thumbnailCacheCapMB
        self.thumbhashCapMB = try c.decodeIfPresent(Int.self, forKey: .thumbhashCapMB) ?? d.thumbhashCapMB
        self.indexingScope = try c.decodeIfPresent(IndexingScope.self, forKey: .indexingScope) ?? d.indexingScope
        self.maxRetryAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRetryAttempts) ?? d.maxRetryAttempts
        self.timeDisplayFormat = try c.decodeIfPresent(TimeDisplayFormat.self, forKey: .timeDisplayFormat) ?? d.timeDisplayFormat
        self.hashConcurrency = try c.decodeIfPresent(Int.self, forKey: .hashConcurrency) ?? d.hashConcurrency
        self.useIncrementalServerSync = try c.decodeIfPresent(Bool.self, forKey: .useIncrementalServerSync) ?? d.useIncrementalServerSync
        self.fastInitialScan = try c.decodeIfPresent(Bool.self, forKey: .fastInitialScan) ?? d.fastInitialScan
        self.propagationMaxAgeDays = try c.decodeIfPresent(Int.self, forKey: .propagationMaxAgeDays) ?? d.propagationMaxAgeDays
        self.keepScreenAwakeDuringSync = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwakeDuringSync) ?? d.keepScreenAwakeDuringSync
        self.persistentDiagnosticLogging = try c.decodeIfPresent(Bool.self, forKey: .persistentDiagnosticLogging) ?? d.persistentDiagnosticLogging
    }
}

/// How clock times render across the cairn UI — journal tail rows,
/// per-run "time of day," sync-timeline timestamps. Stored as a raw
/// string so the JSON shape is stable and human-inspectable.
///
/// `.system` is the default: the renderer asks `Locale.current` for
/// the right pattern via `setLocalizedDateFormatFromTemplate`, which
/// honors iOS Settings → General → Date & Time → 24-Hour Time.
///
/// `.h12` and `.h24` override the locale and pin the format. Useful
/// for a 24-hour-preferring user temporarily on a US-locale loaner,
/// or for screenshots that need a consistent format across devices.
public enum TimeDisplayFormat: String, Sendable, Codable, Equatable, CaseIterable {
    case system
    case h12
    case h24

    /// Human label for the picker row in Settings.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .h12: return "12-hour"
        case .h24: return "24-hour"
        }
    }

    /// Format `date` as a clock time only — no day or date component.
    /// `.system` resolves the pattern via the `jm` template against
    /// `locale`. The `j` template character is special in CLDR/ICU:
    /// it stands for "locale-determined hour cycle" — resolves to
    /// `h` (12-hour with AM/PM) when iOS Settings → General → Date
    /// & Time → 24-Hour Time is off, and to `H` (24-hour) when it's
    /// on. `H` and `h` are explicit cycle pins and would IGNORE the
    /// user preference. `.h12` and `.h24` deliberately pin explicit
    /// patterns regardless of locale.
    ///
    /// `locale` defaults to `.autoupdatingCurrent` so a fresh helper
    /// call always sees the latest user preference. Pass a specific
    /// locale only for tests or screenshot pipelines that need a
    /// pinned output regardless of host configuration.
    public func formatClockTime(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let df = DateFormatter()
        switch self {
        case .system:
            df.locale = locale
            df.setLocalizedDateFormatFromTemplate("jm")
        case .h12:
            df.dateFormat = "h:mm a"
            df.locale = Locale(identifier: "en_US_POSIX")
        case .h24:
            df.dateFormat = "HH:mm"
            df.locale = Locale(identifier: "en_US_POSIX")
        }
        return df.string(from: date)
    }

    /// Like `formatClockTime` but includes seconds — for the sync-detail
    /// phase timeline and activity feed, where events within the same
    /// minute need to be distinguishable. `.system` uses the `jms`
    /// skeleton (locale-resolved hour cycle + seconds); `.h12`/`.h24` pin
    /// explicit patterns the same way `formatClockTime` does.
    public func formatClockTimeWithSeconds(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let df = DateFormatter()
        switch self {
        case .system:
            df.locale = locale
            df.setLocalizedDateFormatFromTemplate("jms")
        case .h12:
            df.dateFormat = "h:mm:ss a"
            df.locale = Locale(identifier: "en_US_POSIX")
        case .h24:
            df.dateFormat = "HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
        }
        return df.string(from: date)
    }

    /// Format `date` for the journal tail: a clock time when `date`
    /// falls on the same calendar day as `now`, else `MMM d`-prefixed
    /// so a stale row reads as "yesterday or earlier" at a glance.
    /// The clock component honors `self` exactly as `formatClockTime`
    /// does — `.system` uses the `j` skeleton (locale-resolved hour
    /// cycle), `.h12`/`.h24` pin explicit patterns.
    public func formatJournalTime(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return formatClockTime(date, locale: locale)
        }
        let df = DateFormatter()
        switch self {
        case .system:
            df.locale = locale
            df.setLocalizedDateFormatFromTemplate("MMMdjm")
        case .h12:
            df.dateFormat = "MMM d h:mm a"
            df.locale = Locale(identifier: "en_US_POSIX")
        case .h24:
            df.dateFormat = "MMM d HH:mm"
            df.locale = Locale(identifier: "en_US_POSIX")
        }
        return df.string(from: date)
    }
}

/// Which slice of the user's Photos library cairn watches.
///
/// Encoded as a tagged-payload object, e.g.
/// `{"kind":"fullLibrary"}` or
/// `{"kind":"selectedAlbums","albums":["AB12...","CD34..."]}`. The
/// hand-rolled coding keeps the on-disk shape stable and human-readable,
/// and avoids the synthesized `{"selectedAlbums":{"_0":[...]}}` format
/// that ties the JSON to Swift's enum-associated-value internals.
///
/// `albums` is `Set<String>` of `PHAssetCollection.localIdentifier`
/// values. Stable across launches; PhotoKit also returns these values
/// from the picker UI.
public enum IndexingScope: Sendable, Equatable {
    case fullLibrary
    case selectedAlbums(Set<String>)

    /// Convenience: `true` iff a specific album set is being watched.
    public var isRestricted: Bool {
        switch self {
        case .fullLibrary: return false
        case .selectedAlbums: return true
        }
    }

    /// The selected album localIdentifiers when restricted; empty set
    /// when `.fullLibrary`. Useful for callers that just want a flat
    /// collection without unwrapping the enum each time.
    public var albumLocalIdentifiers: Set<String> {
        switch self {
        case .fullLibrary: return []
        case .selectedAlbums(let ids): return ids
        }
    }
}

extension IndexingScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, albums
    }

    private enum Kind: String, Codable {
        case fullLibrary, selectedAlbums
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fullLibrary:
            self = .fullLibrary
        case .selectedAlbums:
            let albums = try c.decodeIfPresent(Set<String>.self, forKey: .albums) ?? []
            self = .selectedAlbums(albums)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullLibrary:
            try c.encode(Kind.fullLibrary, forKey: .kind)
        case .selectedAlbums(let ids):
            try c.encode(Kind.selectedAlbums, forKey: .kind)
            // Encode as a sorted array for stable JSON; the Swift
            // `Set<String>` decode side accepts any ordering.
            try c.encode(ids.sorted(), forKey: .albums)
        }
    }
}

/// User-facing override for the system color scheme. Serialized as the
/// raw string (`"system"` / `"light"` / `"dark"`) so the on-disk format
/// is stable and human-readable.
public enum AppearanceOverride: String, Sendable, Codable, Equatable, CaseIterable {
    /// Follow iOS Settings → Display & Brightness (the default).
    case system
    /// Force light mode regardless of the system preference.
    case light
    /// Force dark mode regardless of the system preference.
    case dark
}

/// How aggressively cairn translates "no longer in the local library"
/// into "trash on the server."
///
/// Also gates whether cairn auto-trashes eligible candidates on sync
/// (see `autoTrashesEligibleCandidates`): `.strict` never does,
/// `.trusting` and `.autonomous` do (within the safety rails).
///
/// `.strict` requires a positive deletion signal — a
/// `PHPhotoLibrary.fetchPersistentChanges` event that named the
/// checksum's `localIdentifier` as deleted — before any candidate is
/// trashed. Diff-discovered candidates that lack the positive signal
/// are held in pending review for manual approval, and nothing is
/// trashed without an explicit user confirmation. The default (made so
/// once auto-trash landed, so auto-deletion is opt-in): the safest
/// choice, and the right one for users who want both signals in parallel.
///
/// `.trusting` skips the positive-signal gate. Any diff-discovered
/// candidate flows through the normal pipeline, gated only by the
/// quarantine window — and once past it, auto-trashes on the next sync
/// (within the safety rails). Quarantine alone gives a large recovery
/// margin without a "pending review" queue.
///
/// `.autonomous` also skips the quarantine wait. Every diff-discovered
/// candidate is eligible to trash immediately on the next run — no
/// held-by-quarantine bucket, no pending review for unconfirmed items.
/// For users who run cairn from a known-stable environment (a
/// scheduled CLI cron over a specific photo album, say) and treat
/// the quarantine clock as friction rather than safety. Skipping
/// quarantine means an accidental "Remove from this iPhone" deletes
/// on Immich within the next sync — only choose this when the
/// orchestration around cairn is providing safety some other way.
public enum DeletionStrictness: String, Sendable, Codable, Equatable, CaseIterable {
    case strict
    case trusting
    case autonomous

    /// Whether cairn auto-trashes ready-to-trash candidates on each sync
    /// under this level (still gated by the safety rails), rather than
    /// leaving them for manual confirmation. `.strict` (Cautious) is
    /// manual-only; `.trusting` (Balanced, after the quarantine window)
    /// and `.autonomous` (Autonomous, immediately) auto-trash.
    public var autoTrashesEligibleCandidates: Bool {
        switch self {
        case .strict: return false
        case .trusting, .autonomous: return true
        }
    }
}

/// Narrow protocol over settings persistence. The iOS target may back
/// this with a SwiftData-adjacent store or UserDefaults; the CLI uses
/// `JSONFileSettingsStore`. `load()` never errors on "nothing saved yet" —
/// a fresh install gets `.defaults`, not a thrown error the caller has to
/// handle specially on every startup.
public protocol SettingsStore: Sendable {
    func load() async throws -> CairnSettings
    func save(_ settings: CairnSettings) async throws
}

/// Default file-backed implementation: one JSON blob at a fixed path.
/// Writes are atomic (write-to-temp + rename) so an interrupted save
/// can't produce a half-written file that fails to decode on next launch.
/// Missing file is not an error — it yields `.defaults`.
public actor JSONFileSettingsStore: SettingsStore {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(filePath: String) {
        self.path = URL(fileURLWithPath: filePath)
    }

    public func load() async throws -> CairnSettings {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .defaults
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(CairnSettings.self, from: data)
    }

    public func save(_ settings: CairnSettings) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        // `.atomic` is write-to-temp + rename; a crash mid-write leaves
        // the previous good file intact. No merging with prior contents —
        // the struct is the complete state, callers load/mutate/save.
        try data.write(to: path, options: .atomic)
    }
}
