import Foundation
import SwiftUI
import SwiftData
import Photos
import os
import CryptoKit
import CairnCore
import CairnIOSCore

private let syncLog = Logger(subsystem: "app.cairn.ios", category: "sync")

/// Bridges `PHPhotoLibraryChangeObserver` (NSObject protocol) into a
/// closure-based callback we can wire from `AppDependencies`. Holds a
/// strong reference to the observer so PhotoKit keeps delivering events;
/// nilled out on sign-out.
///
/// Hands the raw `PHChange` to the callback so the host can compute
/// inserted/deleted deltas against a tracked `PHFetchResult` — early
/// enough to record metadata before the asset disappears (the cull-
/// burst case where the user takes and deletes a photo within the
/// debounced-sync window).
private final class PhotoLibraryChangeBridge: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable (PHChange) -> Void
    init(onChange: @escaping @Sendable (PHChange) -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ change: PHChange) { onChange(change) }
}

@MainActor
@Observable
final class AppDependencies {

    /// Process-wide access for things that can't reach into SwiftUI's
    /// `@State` graph — primarily `AppIntent.perform()` bodies invoked
    /// from Shortcuts. Set in `init()`; reads must be on MainActor.
    /// Nil before the App struct materializes (which won't happen in
    /// practice during a Shortcut invocation — iOS launches the app
    /// first, then runs the intent, so by perform() time the singleton
    /// is populated).
    static var shared: AppDependencies?

    // MARK: - Global stores (shared across all servers)

    let secretStore: KeychainSecretStore
    let settingsStore: UserDefaultsSettingsStore
    let photos: PhotoKitPhotoEnumerator
    let globalContainer: ModelContainer
    let localHashStore: SwiftDataLocalHashStore
    let deferredHashStore: SwiftDataDeferredHashStore
    let localAssetMetadataStore: SwiftDataLocalAssetMetadataStore

    // MARK: - Per-server stores (nil until activateServer runs)

    private(set) var currentPartitionKey: ServerPartitionKey?
    /// Timestamp the *current* API key was first verified for this
    /// (URL, userId) account on this device. Read from the per-key
    /// activation map in Keychain at bootstrap and at every successful
    /// `verifyServer` call. Drives the runs/journal-tail UI filter so
    /// rotating to a new key starts a fresh-looking history (the journal
    /// file itself is intact). `.distantPast` for upgrade installs that
    /// predate per-key activation tracking — preserves their existing
    /// history. `nil` until `activateServer` has run.
    private(set) var currentKeyActivatedAt: Date?
    private(set) var serverContainer: ModelContainer?
    private(set) var observedStore: SwiftDataObservedStore?
    private(set) var exclusionStore: SwiftDataExclusionStore?
    private(set) var confirmedDeletedStore: SwiftDataConfirmedDeletedStore?
    private(set) var quarantinedAssetStore: SwiftDataQuarantinedAssetStore?
    private(set) var deletionSourceStore: SwiftDataDeletionSourceStore?
    private(set) var tokenStore: SwiftDataPersistentChangeTokenStore?
    private(set) var thumbnailStore: SwiftDataThumbnailStore?
    private(set) var editRetirementStore: SwiftDataEditRetirementStore?
    private(set) var statusSnapshotStore: SwiftDataStatusSnapshotStore?
    private(set) var pendingTrashStore: SwiftDataPendingTrashIntentStore?
    private(set) var serverAssetCacheStore: SwiftDataServerAssetCacheStore?
    private(set) var syncAckStore: SwiftDataSyncAckStore?
    /// Coordinator for the incremental server-side sync path
    /// (`POST /api/sync/stream`). Non-nil iff both the cache store and
    /// an `immichClient` are wired. Live reconciliation calls
    /// `syncToCache` first when `model.settings.useIncrementalServerSync`
    /// is on; falls back to paginated discovery on any error.
    private(set) var serverAssetSyncCoordinator: ServerAssetSyncCoordinator?
    private(set) var journal: DeletionJournal?

    var persistentChangeReconciler: PhotoKitPersistentChangeReconciler? {
        guard let confirmed = confirmedDeletedStore,
              let observed = observedStore,
              let tokens = tokenStore else { return nil }

        let limitMB = model.settings.iCloudDownloadLimitMB
        let bytesLimit: Int64? = limitMB > 0 ? Int64(limitMB) * 1024 * 1024 : nil
        let ceilingBytes = Self.megabytesToBytes(model.settings.iCloudMaxEverBytesMB)

        let isLimitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        let activeScope = model.settings.indexingScope
        // Snapshot the propagation cutoff at build time. Since this
        // property rebuilds the reconciler on every access, the value
        // is fresh per scan — a Settings toggle takes effect on the
        // next call to `persistentChangeReconciler`. No need for a
        // MainActor hop inside the reconciler's scan path.
        let propagationCutoff = model.settings.propagationMaxAgeDays
        return PhotoKitPersistentChangeReconciler(
            hashStore: localHashStore,
            confirmedDeleted: confirmed,
            observed: observed,
            tokens: tokens,
            deferredStore: deferredHashStore,
            metadataStore: localAssetMetadataStore,
            editRetirement: editRetirementStore,
            deletionSource: deletionSourceStore,
            maxAssets: Self.resolveTestingAssetCap(),
            maxICloudBytesPerAsset: bytesLimit,
            hardCeilingBytes: ceilingBytes,
            requireExplicitDeletionEvent: isLimitedAccess,
            scope: activeScope,
            propagationMaxAgeDays: { propagationCutoff },
            maxConcurrentHashes: model.settings.clampedHashConcurrency,
            onHashProgress: { [weak self] done, total, newChecksums in
                // Fetch all MainActor-isolated state in one hop.
                struct Snapshot {
                    let hashStore: SwiftDataLocalHashStore?
                    let serverSet: Set<Checksum>?
                    let deferredStore: SwiftDataDeferredHashStore?
                    let ceilingBytes: Int64?
                }
                let snap: Snapshot = await MainActor.run {
                    guard let self else {
                        return Snapshot(hashStore: nil, serverSet: nil, deferredStore: nil, ceilingBytes: nil)
                    }
                    return Snapshot(
                        hashStore: self.localHashStore,
                        serverSet: self.serverChecksumSet,
                        deferredStore: self.deferredHashStore,
                        ceilingBytes: Self.megabytesToBytes(self.model.settings.iCloudMaxEverBytesMB)
                    )
                }
                guard let hashStore = snap.hashStore else {
                    await MainActor.run {
                        guard let self else { return }
                        let baseline = self.model.syncProgress?.initialHashed ?? done
                        let imputed = self.model.syncProgress?.imputed ?? 0
                        self.model.syncProgress = .init(hashed: done, total: total, initialHashed: baseline, imputed: imputed)
                    }
                    return
                }
                let indexed = (try? await hashStore.indexedCount()) ?? 0
                let batchMatched: Int = {
                    guard let serverSet = snap.serverSet else { return 0 }
                    return newChecksums.filter { serverSet.contains($0) }.count
                }()
                // Recompute deferred queue counts so the sync card's
                // "queued" line ticks down live as items get removed
                // per-asset by the drain loop. Without this the label
                // stays stale until end-of-drain.
                var queueCount = 0
                var queueAboveCeiling = 0
                var queueBytes: Int64 = 0
                if let deferredStore = snap.deferredStore {
                    let entries = (try? await deferredStore.snapshot()) ?? []
                    for entry in entries {
                        if let cb = snap.ceilingBytes, let size = entry.sizeBytes, size > cb {
                            queueAboveCeiling += 1
                        } else {
                            queueCount += 1
                            if let size = entry.sizeBytes { queueBytes += size }
                        }
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    // Optimistic-cancel guard: when the user taps Stop,
                    // `cancelActiveSync` flips `isSyncing` to false
                    // immediately, but the reconciler is still unwinding
                    // and may emit a few more progress callbacks. Don't
                    // let those re-flip syncProgress / library and cause
                    // the visible counter to keep ticking after the user
                    // thinks they stopped. The cache write inside the
                    // reconciler is independent of this branch — work
                    // already started still persists.
                    guard self.model.isSyncing else { return }
                    // First emit of a session captures the resume baseline
                    // (i.e. count of cached-from-prior-run assets). The ETA
                    // computation on InitialScanScreen subtracts this so the
                    // rate is calculated from session-only work, not work
                    // that already finished on a prior launch.
                    let baseline = self.model.syncProgress?.initialHashed ?? done
                    let imputed = self.model.syncProgress?.imputed ?? 0
                    self.model.syncProgress = .init(hashed: done, total: total, initialHashed: baseline, imputed: imputed)
                    let prevMatched = self.model.library.matched
                    self.model.library = self.model.library
                        .with(indexed: indexed, matched: prevMatched + batchMatched)
                    if snap.deferredStore != nil {
                        self.model.deferredQueue = .init(
                            count: queueCount,
                            aboveCeiling: queueAboveCeiling,
                            totalKnownBytes: queueBytes
                        )
                    }
                    // First-hash detection: flip the high-level phase
                    // from `.preparing` to `.hashing` the moment we see
                    // hashing progress. The reconciler runs detached, so
                    // we can't mark this from the call site; the progress
                    // callback is the natural signal.
                    if self.model.syncPhase == .preparing {
                        self.model.transitionSyncPhase(to: .hashing)
                    }
                    // Persist a fresh per-asset rate to UserDefaults
                    // for the next session's bootstrap ETA. Same warmup
                    // gates as the on-screen publish (30 assets, 5s) so
                    // we don't persist noise from the very first emits.
                    // Live update — the persisted value tracks the
                    // current session as it progresses, so a relaunch
                    // mid-scan picks up the freshest rate. UserDefaults
                    // writes are cheap; no throttling needed.
                    if let started = self.model.syncStartedAt {
                        let elapsed = Date().timeIntervalSince(started)
                        let baseline = self.model.syncProgress?.initialHashed ?? 0
                        let sessionWork = max(0, done - baseline)
                        if sessionWork >= 30 && elapsed >= 5 {
                            let perAssetMs = (elapsed * 1000.0) / Double(sessionWork)
                            Self.savePersistedSyncRate(perAssetMs)
                            self.model.persistedSyncRate = perAssetMs
                        }
                    }
                    // Throttled activity-feed emit. `onHashProgress` itself
                    // is already throttled (every N or every Yms — see
                    // `progressEveryN` / `progressEveryMs` in the
                    // reconciler), so this just lifts the same data into
                    // the user-facing feed.
                    self.model.appendSyncActivity(.init(
                        kind: .hashed,
                        detail: total > 0
                            ? "\(done.formatted(.number)) / \(total.formatted(.number)) hashed"
                            : "\(done.formatted(.number)) hashed"
                    ))
                }
            },
            onPhaseChange: { [weak self] phaseName, elapsedMs in
                // Reconciler-internal phase boundaries (fetchPersistentChanges,
                // cachedLocalIds, observeAndFilter, hashing, orphanSweep, etc.).
                // Each fires once with the elapsed-ms for the segment that
                // just closed. Surface them in the activity feed as `.note`
                // entries so the drill-down sheet shows the granular
                // progression alongside the high-level phase.
                guard let self else { return }
                await MainActor.run {
                    self.model.appendSyncActivity(.init(
                        kind: .note,
                        detail: "\(phaseName) · \(elapsedMs.formatted(.number))ms"
                    ))
                }
            },
            onHashStarted: { [weak self] assetID, filename, sizeBytes in
                guard let self else { return }
                await MainActor.run {
                    let item = CairnAppModel.HashingItem(
                        assetID: assetID,
                        filename: filename,
                        sizeBytes: sizeBytes,
                        startedAt: Date()
                    )
                    self.model.applyHashEvent(.started(item))
                }
            },
            onHashDownloadProgress: { [weak self] assetID, fraction in
                guard let self else { return }
                await MainActor.run {
                    self.model.applyHashEvent(.downloadProgress(assetID: assetID, fraction: fraction))
                }
            },
            onHashFinished: { [weak self] assetID in
                guard let self else { return }
                await MainActor.run {
                    self.model.applyHashEvent(.finished(assetID: assetID))
                }
            }
        )
    }

    nonisolated static let massOffloadRecentWindow: TimeInterval = 24 * 60 * 60

    nonisolated static func resolveTestingAssetCap() -> Int? {
        let key = "CAIRN_ASSET_CAP"
        let ud = UserDefaults.standard
        if let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty {
            if let n = Int(raw), n > 0 {
                ud.set(n, forKey: key)
                return n
            }
            ud.removeObject(forKey: key)
            return nil
        }
        let stored = ud.integer(forKey: key)
        return stored > 0 ? stored : nil
    }

    private(set) var immichClient: ImmichClient?

    /// Foreground PhotoKit change observer. Hashes inserts immediately
    /// when cairn is open so a take→delete in the same session doesn't
    /// lose the photo's checksum (and therefore the chance to propagate
    /// the deletion to the server).
    private var photoLibraryBridge: PhotoLibraryChangeBridge?
    private var pendingForegroundSyncTask: Task<Void, Never>?

    /// Wall-clock time of the most recent `requestSync` completion.
    /// `scheduleForegroundSync` uses this to suppress sync triggers
    /// that arrive in the immediate post-sync window — those are
    /// almost always `photoLibraryDidChange` events fired by PhotoKit
    /// in response to iCloud asset downloads cairn's own hash pipeline
    /// caused, NOT genuine new user activity. Without the cooldown the
    /// observer + scheduler form a self-perpetuating loop where every
    /// sync triggers the next one.
    private var lastSyncEndedAt: Date?

    /// How long after a sync ends to ignore observer-triggered sync
    /// requests. Picked to comfortably cover the iCloud activity tail
    /// from a long sync (most events arrive within a few seconds of
    /// sync end). Real user actions — taking a photo, deleting one —
    /// produce events that show up well outside this window.
    private static let postSyncObserverCooldown: TimeInterval = 15

    /// Tracked fetch the foreground observer diffs against. Required to
    /// turn a `PHChange` into `insertedObjects` without re-enumerating
    /// the whole library — that's how we capture metadata eagerly,
    /// before the debounced-sync runs (which is too late if the user
    /// deletes the asset in the meantime).
    private var trackedLibraryFetch: PHFetchResult<PHAsset>?

    /// Server-side checksum set, populated early in the sync so the
    /// hash-progress callback can compute a running "matched" count.
    /// Cleared at the start of each reconciliation and filled once
    /// the server fetch completes.
    private var serverChecksumSet: Set<Checksum>?

    /// Cached `[Checksum: ServerAsset]` from the most recent sync.
    /// Drives Excluded-assets screen enrichment (filename / kind /
    /// thumbnail-id) without an extra network round-trip when the
    /// user opens Settings → Excluded assets. Stale tolerated — the
    /// next sync refreshes; if the asset list shifted server-side
    /// the stale entry just shows an outdated filename for one render.
    private var serverAssetsByChecksum: [Checksum: ServerAsset]?

    private(set) var thumbnailLoader: ImmichThumbnailLoader?

    /// Background network reachability probe. Owns an
    /// `NWPathMonitor` so the current connection status is always
    /// cheap to read, plus a canary-HEAD method for the
    /// "satisfied path but broken upstream" case. The sync error
    /// path uses its `classify()` result to pick a more actionable
    /// error message than the generic URLError fallback.
    let reachabilityProbe: ReachabilityProbe

    // MARK: - Model wired into the UI

    let model: CairnAppModel

    // MARK: - Init

    init() {
        let secretStore = KeychainSecretStore()
        let settingsStore = UserDefaultsSettingsStore()
        let photos = PhotoKitPhotoEnumerator()

        let container: ModelContainer = {
            if let disk = try? CairnSwiftDataContainer.makeGlobal() {
                return disk
            }
            do {
                return try CairnSwiftDataContainer.makeGlobal(inMemory: true)
            } catch {
                fatalError("cairn can't initialize a SwiftData container on disk OR in memory — \(error). The app requires at least one of these to function. If this keeps happening, check Settings → Storage for free space and reinstall cairn.")
            }
        }()

        self.secretStore = secretStore
        self.settingsStore = settingsStore
        self.photos = photos
        self.globalContainer = container
        self.localHashStore = SwiftDataLocalHashStore(container: container)
        self.deferredHashStore = SwiftDataDeferredHashStore(container: container)
        self.localAssetMetadataStore = SwiftDataLocalAssetMetadataStore(container: container)
        self.reachabilityProbe = ReachabilityProbe()

        let actions = AppDependencies.makePreviewActions()
        self.model = CairnAppModel(
            needsOnboarding: false,
            actions: actions
        )
        model.isBootstrapping = true

        rewireActions()

        AppDependencies.shared = self
    }

    // MARK: - Server activation

    func activateServer(url: URL, apiKey: String, userId: String? = nil) throws {
        let key = ServerPartitionKey(from: url, userId: userId)

        // One-time migration: if a previous build left a URL-only
        // partition directory at this URL, rename it in place to the
        // new (URL, userId) shape. Only triggers when userId is
        // present (otherwise the legacy dirname IS the new dirname);
        // best-effort — if rename fails (file in use, permission
        // issue) we leave the legacy dir alone and create a fresh
        // one, accepting state loss but avoiding a hard failure.
        if userId != nil {
            Self.migrateLegacyServerPartitionIfNeeded(url: url, userId: userId)
        }

        let containerURL = Self.serverContainerURL(for: key)
        let container: ModelContainer = {
            if let disk = try? CairnSwiftDataContainer.makePerServer(url: containerURL) {
                return disk
            }
            do {
                return try CairnSwiftDataContainer.makePerServer(url: containerURL, inMemory: true)
            } catch {
                fatalError("cairn can't initialize per-server SwiftData container — \(error)")
            }
        }()

        self.currentPartitionKey = key
        self.serverContainer = container
        self.observedStore = SwiftDataObservedStore(container: container)
        self.exclusionStore = SwiftDataExclusionStore(container: container)
        self.confirmedDeletedStore = SwiftDataConfirmedDeletedStore(container: container)
        self.quarantinedAssetStore = SwiftDataQuarantinedAssetStore(container: container)
        self.deletionSourceStore = SwiftDataDeletionSourceStore(container: container)
        self.tokenStore = SwiftDataPersistentChangeTokenStore(container: container)
        self.editRetirementStore = SwiftDataEditRetirementStore(container: container)
        self.statusSnapshotStore = SwiftDataStatusSnapshotStore(container: container)
        self.pendingTrashStore = SwiftDataPendingTrashIntentStore(container: container)
        let cacheStore = SwiftDataServerAssetCacheStore(container: container)
        let ackStore = SwiftDataSyncAckStore(container: container)
        self.serverAssetCacheStore = cacheStore
        self.syncAckStore = ackStore
        let thumbStore = SwiftDataThumbnailStore(container: container)
        self.thumbnailStore = thumbStore

        let journalURL = Self.serverJournalURL(for: key)
        self.journal = DeletionJournal(path: journalURL)

        // Pick up any cached session token so the coordinator's
        // `/sync/*` requests authenticate via Bearer instead of x-api-key
        // (which Immich rejects for those endpoints). Best-effort:
        // Keychain hiccups degrade to API-key-only mode rather than
        // failing activation.
        let cachedSessionToken: String? = (try? secretStore.sessionToken())
        let client = ImmichClient(
            baseURL: url,
            apiKey: apiKey,
            sessionToken: cachedSessionToken,
            session: ImmichClient.makeAppURLSession()
        )
        self.immichClient = client
        self.thumbnailLoader = ImmichThumbnailLoader(
            baseURL: url,
            apiKey: apiKey,
            session: ImmichClient.makeAppURLSession(),
            onFetched: { assetId, data in
                try? await thumbStore.saveThumbnail(assetId: assetId, data: data)
            }
        )
        self.serverAssetSyncCoordinator = ServerAssetSyncCoordinator(
            client: client,
            cache: cacheStore,
            ackStore: ackStore
        )
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CAIRN_SCREENSHOT_MODE") {
            AppDependencies.seedFromFixtures(into: model)
            // Without this, CairnAppRoot's loading-screen gate stays on
            // and the main tab bar never renders — every UI test that
            // calls `waitForMainTabs` then times out at 15s and fails.
            // The non-fixture branches below all clear the flag before
            // returning; the fixture branch must too.
            model.isBootstrapping = false
            return
        }
        #endif

        // App Store review mode. Activated by the magic URL in
        // verifyServer; the flag persists in UserDefaults so a
        // reviewer who backgrounds the app and returns lands in the
        // same fixture state. Sign-out clears the flag.
        if Self.isReviewModeActive() {
            await MainActor.run {
                AppDependencies.seedReviewMode(into: model)
            }
            return
        }

        // Hydrate the persisted per-asset rate from prior sessions so
        // `InitialScanScreen` can show a bootstrap ETA on tap-Start
        // rather than waiting through 30 assets of warmup. The value
        // displays at low-confidence tier until session-only data
        // dominates — see comments on `model.persistedSyncRate`.
        model.persistedSyncRate = Self.loadPersistedSyncRate()

        // Keychain reads can fail in three structurally-different ways
        // that an unguarded `try?` flattens together:
        //
        //   1. SecretStoreError.missing on every attempt — the user
        //      has never saved credentials, or signed out. Correct to
        //      route to onboarding.
        //
        //   2. SecretStoreError.missing on the very first attempt,
        //      then present on the next — iOS occasionally returns
        //      errSecItemNotFound for items that exist during the
        //      brief post-launch window before the per-app Keychain
        //      cache is hot. Force-quit-and-relaunch races and the
        //      first-after-unlock window are the common triggers.
        //      Routing to onboarding here is the "brief onboarding
        //      flash → fixed after relaunch" pattern.
        //
        //   3. Any other Keychain OSStatus error — most often
        //      errSecInteractionNotAllowed (device just unlocked /
        //      app resumed during the locked window) or transient
        //      errSecAuthFailed. The credentials are intact; we just
        //      can't read them right now.
        //
        // Strategy: retry up to `maxAttempts` times with a small delay.
        // For the first `missingRetryWindow` attempts, treat `.missing`
        // as potentially transient — only after the cache should be
        // hot do we accept it as authoritative. OSStatus failures
        // retry the full window. Truly-missing credentials still
        // route to onboarding, just after a brief delay.
        //
        // The 2-attempt (~400ms) `.missing` window we shipped earlier
        // turned out to be too short on some launches: users reported
        // the onboarding flash still recurred occasionally. Doubling
        // the window to ~1.2s should comfortably cover the post-
        // launch Keychain warm-up on devices that need longer, while
        // adding only a one-time penalty for genuine fresh installs.
        var url: URL? = nil
        var apiKey: String? = nil
        var transientFailure = false
        let maxAttempts = 10
        let missingRetryWindow = 6
        var successOnAttempt = -1
        for attempt in 0..<maxAttempts {
            transientFailure = false
            var observedMissing = false
            do {
                url = try secretStore.serverURL()
            } catch SecretStoreError.missing {
                url = nil
                observedMissing = true
            } catch {
                transientFailure = true
                if attempt == maxAttempts - 1 {
                    syncLog.error("[cairn.boot] keychain serverURL read failed after \(maxAttempts, privacy: .public) attempts: \(String(describing: error), privacy: .public)")
                }
            }
            do {
                apiKey = try secretStore.apiKey()
            } catch SecretStoreError.missing {
                apiKey = nil
                observedMissing = true
            } catch {
                transientFailure = true
                if attempt == maxAttempts - 1 {
                    syncLog.error("[cairn.boot] keychain apiKey read failed after \(maxAttempts, privacy: .public) attempts: \(String(describing: error), privacy: .public)")
                }
            }
            // Clean read of both fields, neither missing — done.
            if !transientFailure && !observedMissing {
                successOnAttempt = attempt
                break
            }
            // Observed missing past the retry window with no OSStatus
            // churn — accept as authoritative and stop retrying.
            if !transientFailure && observedMissing && attempt >= missingRetryWindow { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Diagnostic: when we did succeed, log which attempt got us
        // there. Tells us in Console.app whether the retry was needed
        // at all and how long the post-launch Keychain warm-up
        // actually was for this user. `attempt > 0` is the interesting
        // case — it means the first read failed transiently.
        if successOnAttempt > 0 {
            syncLog.notice("[cairn.boot] keychain reads succeeded on attempt \(successOnAttempt + 1, privacy: .public)/\(maxAttempts, privacy: .public) (first \(successOnAttempt, privacy: .public) attempt(s) returned .missing transiently)")
        }
        if (url != nil) != (apiKey != nil) {
            // Exited the loop with exactly one field present — note
            // this so the field record shows whether we ever saw the
            // missing field present during retries (if not, it really
            // is gone).
            syncLog.notice("[cairn.boot] mixed credential state after retries — url present=\(url != nil, privacy: .public), apiKey present=\(apiKey != nil, privacy: .public)")
        }
        // One-time Keychain accessibility migration. Older builds
        // wrote credentials with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
        // which returns errSecItemNotFound when iOS wakes the app
        // for background sync after the screen has relocked — the
        // root cause of the recurring "onboarding flash" reports.
        // We re-write every Keychain item with the more permissive
        // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` tier so
        // background reads succeed. Gated by a UserDefaults flag so
        // we only do the rewrite once per install.
        let migrationKey = "cairn.keychain.accessibility_migrated_v1"
        if url != nil || apiKey != nil, !UserDefaults.standard.bool(forKey: migrationKey) {
            secretStore.migrateAccessibility()
            UserDefaults.standard.set(true, forKey: migrationKey)
            syncLog.notice("[cairn.boot] migrated Keychain items to AfterFirstUnlockThisDeviceOnly accessibility")
        }

        #if DEBUG
        if url == nil || apiKey == nil {
            let ud = UserDefaults.standard
            let env = ProcessInfo.processInfo.environment
            if let seedURL = (env["CAIRN_DEV_SEED_URL"] ?? ud.string(forKey: "CAIRN_DEV_SEED_URL")).flatMap(URL.init(string:)),
               let seedKey = env["CAIRN_DEV_SEED_KEY"] ?? ud.string(forKey: "CAIRN_DEV_SEED_KEY"),
               !seedKey.isEmpty {
                syncLog.notice("[cairn.boot] using seed credentials (Keychain unavailable or empty)")
                url = seedURL
                apiKey = seedKey
                try? secretStore.setServerURL(seedURL)
                try? secretStore.setAPIKey(seedKey)
            }
        }
        #endif

        if transientFailure {
            // Persistent Keychain error across retries. Don't route
            // to onboarding — that would invalidate a session whose
            // credentials are intact. Surface as an error the user
            // can dismiss + retry by relaunching.
            syncLog.error("[cairn.boot] credentials unreadable; preserving session, surfacing error instead of forcing onboarding")
            model.lastError = "cairn couldn't read its credentials from the Keychain. This is usually temporary — try opening the app again in a moment."
            model.isBootstrapping = false
            return
        }

        guard let url, let apiKey else {
            syncLog.notice("[cairn.boot] no credentials in keychain — routing to onboarding (url=\(url == nil ? "missing" : "present", privacy: .public), apiKey=\(apiKey == nil ? "missing" : "present", privacy: .public))")
            model.needsOnboarding = true
            model.isBootstrapping = false
            return
        }

        Self.migrateFromLegacyIfNeeded(serverURL: url)
        // Per-user partitioning: prefer the cached userId from a
        // previous successful verify. nil falls back to URL-only
        // partitioning (matches pre-migration behavior). The
        // opportunistic-fetch path runs lazily on the next sync via
        // `refreshUserIdentityIfNeeded` — bootstrap doesn't block on
        // network reachability.
        let cachedUserId = try? secretStore.userId()
        do {
            try activateServer(url: url, apiKey: apiKey, userId: cachedUserId)
        } catch {
            // SwiftData container creation failed and the in-memory
            // fallback in `activateServer` already trapped, OR the
            // function itself doesn't currently throw (the `try?` was
            // legacy). Either way, log so a future failure surfaces
            // somewhere, and fall back to onboarding.
            syncLog.error("[cairn.boot] activateServer failed: \(String(describing: error), privacy: .public)")
            model.needsOnboarding = true
            model.isBootstrapping = false
            return
        }

        // Per-key activation timestamp — drives the runs/journal-tail
        // filter so rotating to a new API key (still same Immich user)
        // gives a fresh-looking history. Bootstrap path: if this key's
        // fingerprint isn't in the map, seed with `.distantPast` so
        // existing users upgrading to per-key activation tracking
        // don't lose their visible history. The verifyServer path
        // seeds with `now` for genuinely-new keys.
        let bootFingerprint = Self.apiKeyFingerprint(apiKey)
        self.currentKeyActivatedAt = Self.upsertKeyActivation(
            in: secretStore,
            fingerprint: bootFingerprint,
            seedAt: .distantPast
        )

        #if DEBUG
        if ProcessInfo.processInfo.environment["CAIRN_RESET"] == "1" {
            // Bootstrap-time debug reset. Use the same aggregated-
            // failure pattern so a Keychain or SwiftData hiccup
            // surfaces in the log instead of being silently dropped.
            let lh = self.localHashStore
            let tk = self.tokenStore
            let eh = self.observedStore
            let cd = self.confirmedDeletedStore
            let ds = self.deletionSourceStore
            let er = self.editRetirementStore
            let ss = self.statusSnapshotStore
            let qa = self.quarantinedAssetStore
            var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                ("local hash cache", { try await lh.clear() }),
            ]
            if let tk { ops.append(("change-token store", { try await tk.clear() })) }
            if let eh { ops.append(("observed store", { try await eh.clear() })) }
            if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
            if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
            if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
            if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
            if let qa { ops.append(("quarantined-asset store", { try await qa.clear() })) }
            let failures = await Self.aggregateClears(ops)
            if !failures.isEmpty {
                let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                syncLog.error("[cairn.reset.debug] partial failure: \(detail, privacy: .public)")
            }
        }
        #endif

        model.needsOnboarding = false
        model.serverHost = url.host() ?? url.absoluteString
        model.serverURL = url
        model.apiKey = apiKey
        model.apiKeyMasked = AppDependencies.mask(apiKey)
        model.hasSessionToken = (try? secretStore.sessionToken()) != nil
        model.settings = (try? await settingsStore.load()) ?? .defaults

        // One-time auto-trash opt-out migration. Auto-trash (Balanced /
        // Autonomous auto-deleting eligible candidates on sync) is new;
        // no prior shipped build ever auto-trashed, so a user sitting on
        // Balanced/Autonomous never consented to auto-deletion. On the
        // first launch of the build that introduces auto-trash, reset any
        // auto-trashing strictness back to Cautious so nobody is silently
        // switched into automatic deletion — they re-opt-in from Settings.
        // Gated by a UserDefaults flag so it runs exactly once (and never
        // stomps a deliberate re-selection made afterward).
        let autoTrashMigrationKey = "cairn.migration.autotrash_optout_v1"
        if !UserDefaults.standard.bool(forKey: autoTrashMigrationKey) {
            if model.settings.deletionStrictness.autoTrashesEligibleCandidates {
                model.settings.deletionStrictness = .strict
                try? await settingsStore.save(model.settings)
                syncLog.notice("[cairn.migration] reset auto-trashing strictness to Cautious on first auto-trash build launch (auto-deletion is now opt-in)")
            }
            UserDefaults.standard.set(true, forKey: autoTrashMigrationKey)
        }

        // Start the persistent diagnostic-log flusher only if the user has
        // opted in. Off by default, so the 20s OSLog poll + rolling-file
        // writes don't run on every launch — they're for active bug
        // reporting (toggle in Settings → Advanced). Live changes are
        // handled by the onChange hook in CairnAppRoot.
        if model.settings.persistentDiagnosticLogging {
            Task { await DiagnosticLogFlusher.shared.start() }
        }

        if let client = immichClient {
            // Run the server probes OFF the bootstrap critical path. They
            // only refresh the connection banner, server count, missing-
            // permissions, and the legacy identity cache — none of which
            // gates which screen renders. Inline, a black-holed server
            // (VPN down, DNS hang) left the root showing Color.clear for up
            // to 4×30s of serial request timeouts. As a task, bootstrap
            // finishes and the UI appears immediately; the banner updates
            // reactively as each probe lands.
            let cachedUserIdForProbe = cachedUserId
            Task { @MainActor [weak self] in
                guard let self else { return }
                let start = Date()
                do {
                    let pong = try await client.ping()
                    let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                    syncLog.notice("[cairn.boot] server healthy: ping=\(pong), \(latencyMs)ms")
                    self.model.connectionStatus = .healthy(latencyMs: latencyMs)
                    self.model.degraded = .none
                } catch {
                    syncLog.notice("[cairn.boot] ping failed: \(error)")
                    if let degraded = Self.degradedState(for: error) {
                        self.model.degraded = degraded
                        self.model.connectionStatus = degraded == .authStale ? .authStale : .offline
                    }
                }
                if let stats = try? await client.assetStatistics() {
                    self.model.library = self.model.library.with(server: stats.total)
                }
                if let keyInfo = try? await client.apiKeyInfo() {
                    let missing = ImmichClient.missingPermissions(granted: keyInfo.permissions)
                    self.model.missingPermissions = missing
                    if !missing.isEmpty {
                        syncLog.notice("[cairn.boot] missing permissions: \(missing.joined(separator: ", "))")
                    }
                }
                // Best-effort server version + supported-range advisory.
                // Soft signal only — surfaced on the Connection page, never
                // gates sync. Older Immich without /server/version just
                // leaves both nil.
                if let version = try? await client.serverVersion() {
                    self.model.serverVersion = version
                    self.model.serverVersionAdvisory = ImmichVersionSupport.advisory(for: version)
                    if let advisory = self.model.serverVersionAdvisory {
                        syncLog.notice("[cairn.boot] server version \(String(describing: version), privacy: .public) — advisory: \(advisory, privacy: .public)")
                    } else {
                        syncLog.notice("[cairn.boot] server version \(String(describing: version), privacy: .public)")
                    }
                }
                // Opportunistic identity refresh for legacy installs. If
                // we activated with `userId: nil` (cache empty), fetch
                // identity now that we have a working client. Persist;
                // user-visible re-activation happens on next launch (we
                // don't swap containers underneath an active sync).
                if cachedUserIdForProbe == nil, let identity = try? await client.usersMe() {
                    try? self.secretStore.setUserIdentity(id: identity.id, email: identity.email)
                    syncLog.notice("[cairn.boot] cached user identity: \(identity.email, privacy: .public) (\(identity.id, privacy: .public)). New partition takes effect on next launch.")
                }
            }
        }

        await refreshExcludedChecksums()
        await refreshQuarantineCount()
        await refreshPendingTrashCount()

        let tokenExists = (try? await tokenStore?.load()) != nil
        model.hasCompletedInitialScan = tokenExists

        // Build-110 upgrade migration: existing installs that already
        // completed their initial scan before this build shipped never
        // hit the false→true `hasCompletedInitialScan` transition that
        // auto-flips `keepScreenAwakeDuringSync` off after first run.
        // They'd be stuck holding the screen on every incremental sync
        // forever without intervention. One-shot UserDefaults-gated
        // fix-up: if the initial scan is already complete AND the
        // toggle is still at its factory default true AND we haven't
        // migrated yet, flip and persist. Manual re-enables after this
        // ran are preserved — the flag is set unconditionally so
        // future bootstraps no-op.
        if tokenExists,
           model.settings.keepScreenAwakeDuringSync,
           !Self.hasMigratedKeepScreenAwake()
        {
            model.settings.keepScreenAwakeDuringSync = false
            try? await settingsStore.save(model.settings)
            syncLog.notice("[cairn.migration] keepScreenAwakeDuringSync auto-disabled on first bootstrap after build-110 upgrade (initial scan was already complete)")
        }
        // Always mark migrated after first bootstrap on a build that
        // ships this code path, so users who happened to land on the
        // exact toggle = false / scan-incomplete state still avoid
        // having the migration block any subsequent re-enable.
        if !Self.hasMigratedKeepScreenAwake() {
            Self.markKeepScreenAwakeMigrated()
        }

        // Build-121 metadata backfill: previous-build metadata rows
        // don't have `allResourceFilenames` populated. Without that
        // field the build-121 alive-on-phone fix for edited assets
        // can't see the non-primary resource filenames it needs to
        // suppress them. Fires once per partition; cost scales with
        // metadata row count. Runs detached so bootstrap doesn't
        // block.
        await migrateResourceFilenamesIfNeeded()

        await refreshLibrarySizeStats()

        // Restore last-known status counts so Status doesn't render
        // blank until the next sync completes. Cosmetic only — a load
        // failure leaves the model at defaults rather than aborting
        // bootstrap. The next `performLiveReconciliation` will overwrite
        // these with fresh values.
        //
        // `try? await store?.load()` flattens both error and store-nil
        // into a single `StatusSnapshot??`; collapse to `StatusSnapshot?`
        // before the conditional bind.
        let restoredSnapshot: StatusSnapshot? = await {
            guard let store = statusSnapshotStore else { return nil }
            return try? await store.load()
        }()
        if let snapshot = restoredSnapshot {
            let current = model.library
            model.library = current.with(
                matched: snapshot.matchedCount,
                candidates: snapshot.deleteCandidatesCount
            )
            model.inferredOrphanCount = snapshot.inferredOrphanCount
            model.lastCheckedAt = snapshot.computedAt
            // `pendingReviewCount` itself isn't restored from the status
            // snapshot — it's derived from `model.reconciliation`, which
            // `restoreQuarantineReconciliationIfNeeded` (below) rebuilds
            // from the persisted held-asset payloads. That makes the
            // quarantine queue render at launch instead of staying blank
            // until the next sync.
            _ = snapshot.pendingReviewCount
        }

        // Rehydrate the held (quarantine) bucket into `model.reconciliation`
        // so the Pending Review list + Status quarantine line survive a
        // cold launch with no sync. Without this, both are blank until a
        // reconciliation runs — and the foreground catch-up sync is
        // stale-gated, so relaunching shortly after a sync left the
        // quarantine queue invisible. Cosmetic-only and best-effort: a
        // failure leaves `reconciliation` nil (prior behavior).
        await restoreQuarantineReconciliationIfNeeded(computedAt: restoredSnapshot?.computedAt)

        if let cap = Self.resolveTestingAssetCap() {
            syncLog.notice("[cairn.boot] testing asset cap in effect: \(cap)")
        } else {
            syncLog.notice("[cairn.boot] no asset cap — full library will be hashed")
        }

        // Buffer enough history for the user to scroll back through
        // recent activity on Status without leaving the screen. 500
        // rows ≈ months of normal use; reading them once costs the
        // same I/O as the full `readAll` we already run for runs.
        // Settings → Clear journal still exists for anyone who wants
        // the slate wiped.
        await refreshJournalTail()

        await refreshDeferredQueueSummary()
        await refreshRunsList()

        rewireActions()
        registerPhotoLibraryObserver()
        registerLocaleChangeObserver()
        model.isBootstrapping = false
    }

    /// Re-render the cached journal tail when the user flips iOS
    /// Settings → General → Date & Time → 24-Hour Time (or otherwise
    /// changes the system locale). `model.journalTail` is a list of
    /// pre-formatted strings rebuilt only by `refreshJournalTail`;
    /// without this observer, the displayed times stay stale until
    /// the next sync. SwiftUI-driven render paths (RunsScreen rows,
    /// etc.) auto-react via `@Environment(\.locale)` so they don't
    /// need this — only the cached-string surfaces do.
    ///
    /// `NotificationCenter` retains the block observer for the app's
    /// lifetime; since `AppDependencies` is held by `CairnApp`'s
    /// `@State` for the whole process lifetime, there's no point in
    /// tracking the token for cleanup.
    private func registerLocaleChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            syncLog.notice("[cairn.boot] system locale changed; refreshing journal tail")
            Task { @MainActor in
                await self.refreshJournalTail()
            }
        }
    }

    /// Register a foreground PhotoKit change observer. When the photo
    /// library changes (insert, update, delete), eagerly record metadata
    /// for the inserted assets (filename + creationDate + size) so the
    /// orphan reconciler can match them against the server even if
    /// they're deleted before cairn finishes hashing them. Then schedule
    /// a debounced incremental sync so new photos get hashed within
    /// seconds — closing the take→quickly-delete window without waiting
    /// for background refresh.
    private func registerPhotoLibraryObserver() {
        guard photoLibraryBridge == nil else { return }
        guard Self.isUsablePhotoAuth(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { return }

        // Build the tracked fetch synchronously here on MainActor.
        // `changeDetails(for:)` requires a fetch result against which
        // PHChange can compute deltas. The same options as
        // `refreshLibrarySizeStats` so observed inserts mirror what
        // reconciliation will see.
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        self.trackedLibraryFetch = PHAsset.fetchAssets(with: opts)

        let bridge = PhotoLibraryChangeBridge { [weak self] change in
            // PhotoKit calls this on a background queue. Hop to
            // MainActor before touching `trackedLibraryFetch` and
            // before kicking the metadata-record task off the actor.
            Task { @MainActor [weak self] in
                self?.handlePhotoLibraryChange(change)
                self?.scheduleForegroundSync()
            }
        }
        PHPhotoLibrary.shared().register(bridge)
        photoLibraryBridge = bridge
        syncLog.notice("[cairn.boot] photo library observer registered")
    }

    /// Pull `insertedObjects` out of the tracked fetch and snapshot
    /// metadata for each one before the debounced sync runs. Without
    /// this hop, an asset added and then deleted within the 1.5s
    /// debounce never gets metadata recorded — and `OrphanReconciler`
    /// has nothing to match against.
    private func handlePhotoLibraryChange(_ change: PHChange) {
        guard let tracked = trackedLibraryFetch,
              let details = change.changeDetails(for: tracked) else { return }
        // Update the tracked fetch to the post-change snapshot so the
        // *next* event diffs against the right baseline.
        self.trackedLibraryFetch = details.fetchResultAfterChanges

        // Diagnostic — tells us whether the observer fired live (vs
        // cairn being suspended during the edit) and what the change
        // details report. When orphan-matching fails to surface an
        // edited-then-deleted asset, this is the first line to check:
        // if `chg=0` for an edit, the observer didn't see it and the
        // metadata pipeline falls back to scan-time (which can't fetch
        // a deleted asset).
        syncLog.notice("[cairn.observer] photoLibraryDidChange: ins=\(details.insertedObjects.count, privacy: .public) chg=\(details.changedObjects.count, privacy: .public) rm=\(details.removedObjects.count, privacy: .public)")

        // Cover both new assets AND edits-of-existing-assets. PhotoKit
        // surfaces edits as `changedObjects` (modificationDate advances,
        // bytes change). Without including them here, the observer-
        // time metadata path misses the edit-then-delete race: the
        // metadata for the about-to-be-edited id never gets refreshed,
        // and if the user deletes within the debounce window, the scan-
        // time fallback (`observeAndFilter`) can't fetch the deleted
        // asset to record metadata either, leaving OrphanReconciler with
        // nothing to match against asset_E on the server.
        // Snapshot just the identifiers on main (cheap Sendable reads),
        // then do the per-asset PHAssetResource enumeration off the main
        // thread. That loop is ~30ms/asset; a 50-photo import burst was
        // ~1.5s of synchronous main-thread stall while the app is
        // foreground and interactive. The detached task re-fetches by id
        // immediately (microseconds later), so the edit-then-delete-within-
        // debounce race the function guards against is preserved — and the
        // scan-time `observeAndFilter` path is still the fallback if an id
        // does vanish first. PHAsset isn't Sendable, so we pass ids, not
        // assets (the same hand-off shape as collectIncrementalChanges).
        let captureIds = (details.insertedObjects + details.changedObjects).map(\.localIdentifier)
        guard !captureIds.isEmpty else { return }
        let store = self.localAssetMetadataStore
        Task.detached(priority: .utility) {
            let now = Date()
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: captureIds, options: nil)
            var entries: [LocalAssetMetadata] = []
            entries.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                // Primary = the same resource cairn hashes
                // (`.fullSizePhoto` for edits, `.photo` otherwise),
                // aligning with the hash pipeline and Immich's own
                // upload-resource selection so the recorded filename
                // matches what Immich stores.
                let primary = PhotoKitPhotoEnumerator.selectPrimaryResource(from: resources)
                let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value
                entries.append(LocalAssetMetadata(
                    localIdentifier: asset.localIdentifier,
                    originalFileName: primary?.originalFilename,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    fileSize: size,
                    observedAt: now,
                    // Capture every resource filename — same alive-on-phone
                    // requirement as the reconciler metadata paths (review
                    // 1.1); this observer-time write had the same gap.
                    allResourceFilenames: resources.map(\.originalFilename).filter { !$0.isEmpty }
                ))
            }
            // Best-effort: a write failure here is non-fatal — the
            // scan-time metadata recording in `observeAndFilter` is
            // still in place as a fallback.
            try? await store.record(entries)
        }
    }

    private func unregisterPhotoLibraryObserver() {
        guard let bridge = photoLibraryBridge else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(bridge)
        photoLibraryBridge = nil
        trackedLibraryFetch = nil
    }

    /// Debounced sync trigger from the change observer. Coalesces bursts
    /// of events (e.g. import of 50 photos firing 50 changes) into one
    /// sync run.
    ///
    /// Suppresses triggers in the post-sync cooldown window — `chg=N`
    /// events fired by PhotoKit in response to iCloud downloads our
    /// previous sync caused would otherwise immediately schedule a new
    /// sync, forming a self-perpetuating loop.
    private func scheduleForegroundSync() {
        pendingForegroundSyncTask?.cancel()
        pendingForegroundSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.model.isSyncing else { return }
            if let last = self.lastSyncEndedAt,
               Date().timeIntervalSince(last) < Self.postSyncObserverCooldown {
                syncLog.notice("[cairn.observer] suppressing post-sync trigger; cooldown not expired")
                return
            }
            try? await self.model.actions.requestSync(nil)
        }
    }

    /// Cancel a pending/in-flight PhotoKit-change-driven foreground sync on
    /// backgrounding. The debounced task that hasn't fired yet is dropped;
    /// one mid-run cooperatively cancels (the requestSync cancel handler
    /// restores the prior narration). Called from the App's scene-phase
    /// background hook, alongside the UI's clean-cancel of `activeSyncTask`.
    @MainActor
    func cancelForegroundChangeSync() {
        pendingForegroundSyncTask?.cancel()
        pendingForegroundSyncTask = nil
    }

    // MARK: - Scheduled scan (called by BGAppRefreshTask)

    @discardableResult
    func runScheduledScan() async throws -> PhotoKitPersistentChangeReconciler.Result {
        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        return try await reconciler.runDeletionScan()
    }

    @discardableResult
    func runBackgroundDrain() async throws -> (
        scan: PhotoKitPersistentChangeReconciler.Result,
        drain: PhotoKitPersistentChangeReconciler.Result
    ) {
        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        let scan = try await reconciler.runDeletionScan()
        let drain = try await reconciler.drainDeferred()
        return (scan, drain)
    }

    /// Drain-only variant for BGProcessingTask slots that already
    /// invoked the sync portion via `requestSync(.scheduledHashContinuation)`.
    /// Keeps the deferred-queue drain (unlimited throughput, BG-only)
    /// separate from the journal-emitting sync.
    @discardableResult
    func drainDeferredQueueOnly() async throws -> PhotoKitPersistentChangeReconciler.Result {
        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }
        return try await reconciler.drainDeferred()
    }

    /// "Inspect asset by filename" debug helper. Triggered from
    /// Settings → Advanced. Dumps everything cairn knows about the
    /// given filename across phone library + Immich to the persistent
    /// log so the next diagnostic export shows a side-by-side view
    /// for triaging "alive-on-phone filter didn't catch this asset"
    /// reports without us needing to guess at divergence axes.
    ///
    /// Output shape (all `[cairn.diag]`-prefixed for grep):
    ///
    ///   - 1 summary line: query string, phone-match count,
    ///     server-match count
    ///   - N phone lines: `phone[i] localId=... kvc='...' res='...'
    ///     resTypes=[...] created='ISO' createdSec=N modSec=N
    ///     hidden=Bool sourceType=N mediaSubtypes=[...]`
    ///   - M server lines: `server[i] id=... name='...' created='ISO'
    ///     createdSec=N checksum=...`
    ///   - 1 verdict line per server entry: whether the current
    ///     alive-on-phone filter (engine ±1s tolerance) would suppress
    ///
    /// Case-insensitive filename match across both PHAsset KVC and
    /// PHAssetResource originalFilename. All PHAsset source types +
    /// hidden assets are enumerated so a Hidden/CloudShared/iTunes-
    /// synced match isn't accidentally excluded from the dump.
    fileprivate func inspectAssetByFilenameImpl(filename: String) async {
        let needle = filename.lowercased()
        syncLog.notice("[cairn.diag] inspect: starting query='\(filename, privacy: .public)' (case-insensitive)")

        struct PhoneMatch {
            let localId: String
            let kvcName: String?
            let resourceNames: [(type: String, name: String)]
            let createdDate: Date?
            let modDate: Date?
            let isHidden: Bool
            let sourceType: PHAssetSourceType
            let isLivePhoto: Bool
        }

        // Phone-side scan. Two-pass strategy because
        // `PHAssetResource.assetResources(for:)` is ~30 ms per asset
        // on real hardware — a naive "check every asset's resources"
        // loop blows past an hour on a 100k-asset library, which is
        // exactly the library size that needs the most diagnostic help.
        //
        // Pass 1: KVC `filename` only (fast — pure in-memory property
        //   access, ~0.1 ms per asset). Catches the common case where
        //   the asset's name and the server's `originalFileName` agree
        //   on the same string.
        // Pass 2 (only if pass 1 finds nothing): enumerate
        //   PHAssetResource for every asset and match on any resource's
        //   `originalFilename`. Slow but covers the rare divergence
        //   case where the phone-side asset has a different KVC name
        //   from the resource that was uploaded.
        let phoneMatches: [PhoneMatch] = await Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            opts.includeHiddenAssets = true
            opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let fetch = PHAsset.fetchAssets(with: opts)
            let total = fetch.count
            syncLog.notice("[cairn.diag] inspect: enumerating \(total, privacy: .public) phone assets (KVC pass first)")
            var matches: [PhoneMatch] = []

            // ---- Pass 1: KVC-only filter ----
            var pass1Scanned = 0
            fetch.enumerateObjects { asset, _, _ in
                let kvc = asset.value(forKey: "filename") as? String
                if let k = kvc, k.lowercased() == needle {
                    let resources = PHAssetResource.assetResources(for: asset)
                    let resNames: [(type: String, name: String)] = resources.map { res in
                        (Self.resourceTypeName(res.type), res.originalFilename)
                    }
                    matches.append(PhoneMatch(
                        localId: asset.localIdentifier,
                        kvcName: kvc,
                        resourceNames: resNames,
                        createdDate: asset.creationDate,
                        modDate: asset.modificationDate,
                        isHidden: asset.isHidden,
                        sourceType: asset.sourceType,
                        isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
                    ))
                }
                pass1Scanned += 1
                if pass1Scanned % 20_000 == 0 {
                    syncLog.notice("[cairn.diag] inspect: KVC pass at \(pass1Scanned, privacy: .public)/\(total, privacy: .public)")
                }
            }
            syncLog.notice("[cairn.diag] inspect: KVC pass complete — \(matches.count, privacy: .public) match(es)")

            // ---- Pass 2: resource-level fallback ----
            if matches.isEmpty {
                syncLog.notice("[cairn.diag] inspect: KVC found nothing — running resource-level scan (slow, ~30 ms per asset × \(total, privacy: .public) = up to ~\(Int(Double(total) * 0.03), privacy: .public)s)")
                var pass2Scanned = 0
                fetch.enumerateObjects { asset, _, _ in
                    let resources = PHAssetResource.assetResources(for: asset)
                    let resNames: [(type: String, name: String)] = resources.map { res in
                        (Self.resourceTypeName(res.type), res.originalFilename)
                    }
                    if resNames.contains(where: { $0.name.lowercased() == needle }) {
                        let kvc = asset.value(forKey: "filename") as? String
                        matches.append(PhoneMatch(
                            localId: asset.localIdentifier,
                            kvcName: kvc,
                            resourceNames: resNames,
                            createdDate: asset.creationDate,
                            modDate: asset.modificationDate,
                            isHidden: asset.isHidden,
                            sourceType: asset.sourceType,
                            isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
                        ))
                    }
                    pass2Scanned += 1
                    if pass2Scanned % 5_000 == 0 {
                        syncLog.notice("[cairn.diag] inspect: resource pass at \(pass2Scanned, privacy: .public)/\(total, privacy: .public) — \(matches.count, privacy: .public) match(es) so far")
                    }
                }
                syncLog.notice("[cairn.diag] inspect: resource pass complete — \(matches.count, privacy: .public) match(es) total")
            }
            return matches
        }.value

        // Server-side scan — uses the same search/metadata endpoint
        // imputation goes through for its (filename, captureSecond)
        // join. Try exact filename; pagination unlikely needed at
        // this query specificity.
        var serverMatches: [ServerAsset] = []
        if let client = await self.immichClient {
            do {
                // The search endpoint accepts originalFileName; reuse
                // listAllAssets's pagination loop indirectly by going
                // through the search API. For our diagnostic purpose
                // we don't need full pagination — one page is enough
                // to surface any matches; if there are >1000 server
                // entries with the same filename, the user has bigger
                // questions than this tool answers.
                serverMatches = try await client.searchByOriginalFilename(filename)
            } catch {
                syncLog.error("[cairn.diag] server query failed: \(Self.describeSyncError(error), privacy: .public)")
            }
        }

        syncLog.notice("[cairn.diag] inspect summary: phoneMatches=\(phoneMatches.count, privacy: .public) serverMatches=\(serverMatches.count, privacy: .public)")
        for (i, m) in phoneMatches.enumerated() {
            let createdIso = m.createdDate.map(Self.iso8601Diag) ?? "<nil>"
            let createdSec = m.createdDate.map { Int($0.timeIntervalSince1970) } ?? -1
            let modSec = m.modDate.map { Int($0.timeIntervalSince1970) } ?? -1
            let resDump = m.resourceNames.map { "\($0.type)='\($0.name)'" }.joined(separator: ", ")
            syncLog.notice("[cairn.diag] phone[\(i, privacy: .public)] localId=\(m.localId, privacy: .public) kvc='\(m.kvcName ?? "<nil>", privacy: .public)' resources=[\(resDump, privacy: .public)] created=\(createdIso, privacy: .public) createdSec=\(createdSec, privacy: .public) modSec=\(modSec, privacy: .public) hidden=\(m.isHidden, privacy: .public) sourceType=\(m.sourceType.rawValue, privacy: .public) livePhoto=\(m.isLivePhoto, privacy: .public)")
        }
        // Build the alive-key set the same way performLiveReconciliation
        // does, then report per-server-asset whether the engine's
        // current filter (with ±1s tolerance) would suppress it.
        var aliveKeys = Set<AlivePhoneAssetKey>()
        for m in phoneMatches {
            guard let created = m.createdDate else { continue }
            let sec = Int(created.timeIntervalSince1970)
            if let n = m.kvcName, !n.isEmpty {
                aliveKeys.insert(AlivePhoneAssetKey(filename: n, secondsSince1970: sec))
            }
            for r in m.resourceNames where !r.name.isEmpty {
                aliveKeys.insert(AlivePhoneAssetKey(filename: r.name, secondsSince1970: sec))
            }
        }
        for (i, s) in serverMatches.enumerated() {
            let createdIso = s.fileCreatedAt.map(Self.iso8601Diag) ?? "<nil>"
            let createdSec = s.fileCreatedAt.map { Int($0.timeIntervalSince1970) } ?? -1
            let cks = String(s.checksum.base64.prefix(14))
            let serverName = s.originalFileName ?? "<nil>"
            // Verdict against the engine's current filter (±1s)
            let aliveOnPhone: Bool = {
                guard let name = s.originalFileName, !name.isEmpty,
                      let date = s.fileCreatedAt else { return false }
                let base = Int(date.timeIntervalSince1970)
                return (base - 1...base + 1).contains { sec in
                    aliveKeys.contains(AlivePhoneAssetKey(filename: name, secondsSince1970: sec))
                }
            }()
            syncLog.notice("[cairn.diag] server[\(i, privacy: .public)] id=\(s.id, privacy: .public) name='\(serverName, privacy: .public)' created=\(createdIso, privacy: .public) createdSec=\(createdSec, privacy: .public) checksum=\(cks, privacy: .public) livePhotoVideoId=\(s.livePhotoVideoId ?? "<nil>", privacy: .public) wouldSuppressByAliveOnPhone=\(aliveOnPhone, privacy: .public)")
        }
        syncLog.notice("[cairn.diag] inspect complete: query='\(filename, privacy: .public)' — see logs above for side-by-side. Export logs (Settings → Advanced → Export diagnostic logs) to share.")
    }

    nonisolated(unsafe) private static let iso8601DiagFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated fileprivate static func iso8601Diag(_ d: Date) -> String {
        iso8601DiagFormatter.string(from: d)
    }

    nonisolated fileprivate static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizeVideo: return "fullSizeVideo"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .adjustmentBaseVideo: return "adjustmentBaseVideo"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
        case .photoProxy: return "photoProxy"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    /// Backfill `LocalAssetMetadataStore` for cached ids that are still
    /// alive in PhotoKit but missing from the metadata store. The
    /// observer-time eager handler only captures events while cairn is
    /// alive — older photos and observer-suspended-edits leave gaps.
    /// Without this pass, OrphanReconciler can't match the affected
    /// assets when they later get edited+deleted fast.
    ///
    /// Idempotent: only writes for ids that don't already have a
    /// metadata entry, and reads via a single `snapshot()` call. Cheap
    /// on warm caches; a few seconds the first time.
    @MainActor
    private func backfillMetadataIfNeeded() async {
        // Store snapshots run on their actors' executors (the awaits free
        // main); only the id arithmetic is on main and it's cheap.
        let metadataSnapshot = (try? await self.localAssetMetadataStore.snapshot()) ?? []
        let knownIds = Set(metadataSnapshot.map(\.localIdentifier))
        let cacheIds = (try? await self.localHashStore.allLocalIdentifiers()) ?? []
        let missingFromMetadata = cacheIds.subtracting(knownIds)
        let cacheIdsCount = cacheIds.count
        let knownIdsCount = knownIds.count
        let missingCount = missingFromMetadata.count
        guard !missingFromMetadata.isEmpty else { return }

        // Move the PhotoKit enumeration + per-asset PHAssetResource reads
        // off the main actor. On iOS 26 each `PHAssetResource.assetResources(for:)`
        // call faults `PHAssetOriginalMetadataProperties` synchronously on
        // the main queue, so running the loop on MainActor stacks the
        // hop with PhotoKit's own main-queue dispatch and starves the UI
        // runloop completely. The detached task lets PhotoKit's faults
        // interleave with redraws.
        //
        // Cancellation: `Task.detached` does NOT inherit parent
        // cancellation. Without the `withTaskCancellationHandler` wrap
        // below, a Stop-indexing tap (or BG expiration) unwinds the
        // orchestrator immediately while this loop keeps grinding on a
        // background thread — the UI shows Paused while the reconciler
        // is still doing work in the console.
        // `fetchAssets(withLocalIdentifiers:)` returns only ids PhotoKit
        // can still resolve, which IS the "intersect with currently-alive"
        // filter — so we no longer run a full-library enumeration plus a
        // per-asset PHAssetResource loop on the main thread.
        let store = self.localAssetMetadataStore
        let work = Task.detached(priority: .userInitiated) {
            let now = Date()
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(missingFromMetadata), options: nil)
            var entries: [LocalAssetMetadata] = []
            entries.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                let resources = PHAssetResource.assetResources(for: asset)
                let primary = PhotoKitPhotoEnumerator.selectPrimaryResource(from: resources)
                let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value
                entries.append(LocalAssetMetadata(
                    localIdentifier: asset.localIdentifier,
                    originalFileName: primary?.originalFilename,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    fileSize: size,
                    observedAt: now,
                    allResourceFilenames: resources.map(\.originalFilename).filter { !$0.isEmpty }
                ))
            }
            return entries
        }
        let entries: [LocalAssetMetadata] = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !entries.isEmpty else { return }
        do {
            try await store.record(entries)
            syncLog.notice("[cairn.metadata] backfilled \(entries.count, privacy: .public) entries (cache=\(cacheIdsCount, privacy: .public) had-metadata=\(knownIdsCount, privacy: .public) still-missing=\(missingCount - entries.count, privacy: .public) — those PHAssets are no longer fetchable)")
        } catch {
            syncLog.error("[cairn.metadata] backfill failed: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    /// Build-121 metadata backfill: for installs already past their
    /// initial imputation pass when 121 lands, existing
    /// `LocalAssetMetadata` rows have an empty
    /// `allResourceFilenames` (the field didn't exist when those rows
    /// were written). The alive-on-phone safety check then misses
    /// edited-asset shapes — the entire reason 121 was shipped —
    /// because the resource filenames that the server has but the
    /// primary picker doesn't return never make it into the alive-
    /// key set.
    ///
    /// This migration runs once per partition (UserDefaults-gated):
    ///
    /// 1. Snapshot the metadata store.
    /// 2. Identify rows where `allResourceFilenames` is empty.
    /// 3. For each, fetch the PHAsset, call `PHAssetResource.assetResources`,
    ///    rewrite the row with the full filename list.
    /// 4. Mark migrated.
    ///
    /// Cost is `~30 ms × N` where N is the row count needing backfill
    /// — a few minutes on a 10k library, ~half an hour on a 100k
    /// library. Runs as a `Task.detached` so it doesn't block the
    /// foreground sync; logs progress every 500 rows. The completed
    /// metadata feeds the next sync's alive-key build, suppressing
    /// edited-asset quarantine entries on that pass.
    @MainActor
    private func migrateResourceFilenamesIfNeeded() async {
        guard let partition = self.currentPartitionKey else { return }
        if Self.hasMigratedResourceFilenames(for: partition) { return }
        let metadataStore = self.localAssetMetadataStore
        Task.detached(priority: .utility) {
            let snapshot = (try? await metadataStore.snapshot()) ?? []
            let needsBackfill = snapshot.filter { $0.allResourceFilenames.isEmpty }
            guard !needsBackfill.isEmpty else {
                syncLog.notice("[cairn.migration.resfn] no rows need backfill — marking migrated for partition")
                await MainActor.run {
                    Self.markResourceFilenamesMigrated(for: partition)
                }
                return
            }
            syncLog.notice("[cairn.migration.resfn] starting backfill for \(needsBackfill.count, privacy: .public) metadata rows (~\(Int(Double(needsBackfill.count) * 0.03), privacy: .public)s expected)")
            let allIds = Array(needsBackfill.map(\.localIdentifier))
            // PHAsset.fetchAssets(withLocalIdentifiers:) returns a
            // PHFetchResult keyed on the supplied identifiers; build
            // a lookup so the per-row update doesn't re-fetch.
            let opts = PHFetchOptions()
            opts.includeHiddenAssets = true
            opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: allIds, options: opts)
            var liveById: [String: PHAsset] = [:]
            liveById.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in
                liveById[asset.localIdentifier] = asset
            }
            var updates: [LocalAssetMetadata] = []
            updates.reserveCapacity(needsBackfill.count)
            var processed = 0
            for entry in needsBackfill {
                guard let asset = liveById[entry.localIdentifier] else {
                    // Asset no longer fetchable (deleted between
                    // metadata write and this migration). Skip; the
                    // dangling row will be cleaned up by
                    // OrphanReconciler / cache eviction later.
                    processed += 1
                    continue
                }
                let resources = PHAssetResource.assetResources(for: asset)
                let allNames = resources.map(\.originalFilename).filter { !$0.isEmpty }
                // Skip writing if the asset has no extra resources
                // beyond what's in `originalFileName` — saves a
                // round-trip through the store for the no-op case.
                guard !allNames.isEmpty else {
                    processed += 1
                    continue
                }
                updates.append(LocalAssetMetadata(
                    localIdentifier: entry.localIdentifier,
                    originalFileName: entry.originalFileName,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modificationDate,
                    fileSize: entry.fileSize,
                    observedAt: entry.observedAt,
                    allResourceFilenames: allNames
                ))
                processed += 1
                if processed % 500 == 0 {
                    syncLog.notice("[cairn.migration.resfn] progress: \(processed, privacy: .public)/\(needsBackfill.count, privacy: .public)")
                }
            }
            do {
                try await metadataStore.record(updates)
                syncLog.notice("[cairn.migration.resfn] complete: backfilled \(updates.count, privacy: .public) rows (skipped \(needsBackfill.count - updates.count, privacy: .public) with no extra resources or no live asset)")
                await MainActor.run {
                    Self.markResourceFilenamesMigrated(for: partition)
                }
            } catch {
                syncLog.error("[cairn.migration.resfn] write failed — will retry on next launch: \(Self.describeSyncError(error), privacy: .public)")
            }
        }
    }

    // MARK: - Fast initial scan (trust-seed imputation)

    /// Outcome of one imputation pass.
    fileprivate struct ImputationOutcome {
        let imputed: Int             // entries written to LocalHashStore as imputed
        let hits: Int                // localIds that matched a server (filename, fileCreatedAt) pair
        let ambiguous: Int           // (filename, fileCreatedAt) pairs that matched >1 server row
        let alreadyCached: Int       // matched localIds that were already in LocalHashStore
        let totalPhone: Int          // total live phone localIds enumerated
        let fellBack: Bool           // true if near-zero-hit fallback kicked in
        // Per-skip-reason breakdown of phone assets that fell through
        // to local hashing instead of being trust-seeded. Visible in
        // the activity feed so the user can see why their residue
        // size is what it is (filename-missing vs collision vs
        // server doesn't have it at all vs Live Photo).
        let missingFilename: Int     // PHAssetResource didn't yield an originalFilename
        let missingCreationDate: Int // PHAsset.creationDate was nil
        let noServerMatch: Int       // valid phone key, no matching server row
        let ambiguousPhoneSide: Int  // phone key hit an ambiguous server bucket
        let livePhotoSkipped: Int    // matched a Live Photo; imputation declined (motion-video hash drift)
    }

    /// Render the imputation outcome's skip-reason categories as a
    /// list of short `"N reason"` strings, in priority order. Empty
    /// when every phone asset was either trust-seeded or already
    /// cached (nothing falling through to local hashing for an
    /// interesting reason). The caller joins these with `", "` and
    /// prefixes "Hashing locally:" for the activity feed.
    fileprivate static func imputationBreakdownParts(outcome: ImputationOutcome) -> [String] {
        var parts: [String] = []
        if outcome.noServerMatch > 0 {
            parts.append("\(outcome.noServerMatch.formatted(.number)) not on Immich")
        }
        if outcome.livePhotoSkipped > 0 {
            parts.append("\(outcome.livePhotoSkipped.formatted(.number)) Live Photo (motion video transcoded)")
        }
        if outcome.ambiguousPhoneSide > 0 {
            parts.append("\(outcome.ambiguousPhoneSide.formatted(.number)) ambiguous (filename + date collision)")
        }
        if outcome.missingFilename > 0 {
            parts.append("\(outcome.missingFilename.formatted(.number)) no filename")
        }
        if outcome.missingCreationDate > 0 {
            parts.append("\(outcome.missingCreationDate.formatted(.number)) no capture date")
        }
        return parts
    }

    /// Trust-seed `LocalHashStore` by matching phone assets to server
    /// assets on `(originalFileName, fileCreatedAt)`.
    ///
    /// History: this originally joined on `deviceAssetId`, which the
    /// Immich mobile uploader stamped with `PHAsset.localIdentifier`.
    /// Immich dropped that column from the asset schema in migration
    /// `1776263790468` (Apr 2026) as part of moving to content-based
    /// identity (`x-immich-checksum`). With deviceAssetId gone from
    /// every response on any current Immich server, we pivoted to
    /// the closest stable proxy: filename + capture timestamp.
    ///
    /// For phone assets uploaded by Immich's mobile app from this
    /// iPhone, the pair round-trips exactly — the uploader sends
    /// `PHAsset.creationDate` as `fileCreatedAt` and PHAsset
    /// resource's `originalFilename` as `originalFileName`. The join
    /// is heuristic where deviceAssetId was rigorous, so we layer
    /// more safety:
    ///
    /// - Strict unambiguity: a candidate key must map to exactly one
    ///   non-trashed server row. Any collision falls through to
    ///   local hashing.
    /// - Second-precision timestamps so ISO-8601 / Float drift
    ///   doesn't break the match.
    /// - Near-zero-hit fallback: <5% hit rate on >100-asset libraries
    ///   skips imputation entirely (probable fresh-phone restore or
    ///   server-from-elsewhere).
    /// - Existing modDate-skip path verifies on edit; existing
    ///   imputed-deletion telemetry surfaces the count for support.
    /// - Worst case from a bad imputed value: cairn trashes the
    ///   wrong server row when the user has already asked for *some*
    ///   delete; recoverable via Immich Trash's 30-day window.
    ///
    /// See `docs/active-design/fast-initial-scan-plan.md`.
    @MainActor
    fileprivate func runImputationPass(serverAssets: [ServerAsset]) async throws -> ImputationOutcome {
        // 1. Build (filename, second-truncated fileCreatedAt) →
        //    ServerAsset map. Skip trashed rows (deletion-bound) and
        //    skip rows missing either field (no usable join key).
        //    Ambiguous keys (multiple non-trashed rows on the same
        //    filename + capture-second) get dropped entirely so
        //    those localIds fall through to local hashing.
        //
        //    Live Photo motion videos (server rows with `isLivePhoto`
        //    paired via livePhotoVideoId) aren't dereferenced —
        //    Live Photos as a class are skipped during seeding
        //    (matched server stills with non-nil livePhotoVideoId
        //    are dropped). The build-95 try at seeding the paired
        //    motion checksum produced systematic phantom orphans
        //    because Immich processes motion videos at upload time
        //    and the server's SHA1 doesn't round-trip back to the
        //    phone bytes.
        struct JoinKey: Hashable {
            let filename: String
            let secondsSince1970: Int
            init(filename: String, secondsSince1970: Int) {
                // Lowercase the filename to match every other filename
                // comparison in cairn (AlivePhoneAssetKey, OrphanReconciler,
                // MissedDeletionFinder). PhotoKit's filename sources disagree
                // on case; a case-only difference would otherwise miss the
                // imputation join — safe direction (falls through to local
                // hashing) but it also let case-variant duplicates evade the
                // strict-unambiguity collision check.
                self.filename = filename.lowercased()
                self.secondsSince1970 = secondsSince1970
            }
        }
        var byKey: [JoinKey: ServerAsset] = [:]
        var ambiguous = Set<JoinKey>()
        for asset in serverAssets where !asset.isTrashed {
            guard let filename = asset.originalFileName, !filename.isEmpty,
                  let created = asset.fileCreatedAt else { continue }
            let key = JoinKey(filename: filename, secondsSince1970: Int(created.timeIntervalSince1970))
            if byKey[key] != nil {
                ambiguous.insert(key)
            } else {
                byKey[key] = asset
            }
        }
        let ambiguousCount = ambiguous.count
        for key in ambiguous { byKey.removeValue(forKey: key) }

        // 2. Snapshot phone (localId, modDate, creationDate, filename).
        //    PHAssetResource.assetResources(for:) is a synchronous
        //    metadata-only call (no original-bytes download), but it
        //    runs per-asset — ~milliseconds each. For 6k assets ~few
        //    seconds total. Run off the main actor to keep the UI
        //    responsive. Filter resources to the primary (.photo /
        //    .video / .audio) so Live Photo's paired motion video
        //    doesn't pollute the filename slot — we want the still
        //    photo's filename here.
        //
        //    Progress updates: posts `(scanned, total)` to syncProgress
        //    every 200 assets via a fire-and-forget MainActor hop, so
        //    the InitialScanScreen's "X / Y processed" line ticks live
        //    during this otherwise-silent phase. Tens of seconds on a
        //    17k-asset library otherwise looks frozen to the user.
        let progressEmitter: @Sendable (Int, Int) -> Void = { [weak self] scanned, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.syncProgress = .init(
                    // hashed stays 0 — the scan hasn't *hashed* anything,
                    // it's enumerating. Driving `hashed` here filled the
                    // main bar to 100% then snapped it back to 0 when the
                    // hash pass began. The count goes to `scanned`, which
                    // InitialScanScreen renders as its own line.
                    hashed: 0,
                    total: total,
                    // Pre-hash library scan — leave the hash baseline
                    // uncaptured (nil) so the first onHashProgress emit
                    // establishes it from `done`.
                    initialHashed: nil,
                    imputed: self.model.syncProgress?.imputed ?? 0,
                    scanned: scanned
                )
            }
        }
        // PhoneEntry now also carries `fileSize` so we can side-effect
        // a LocalAssetMetadata write below — `recordFullEnumerationMetadata`
        // inside the subsequent full-enum pass calls
        // `PHAssetResource.assetResources` per asset to get the same
        // five fields, and on a 108k-asset library that re-scan takes
        // ~50 minutes of silent sequential work (real tester report:
        // `seeded=81353 totalPhone=108936 durationMs=496421` immediately
        // followed by an hour of silence with the screen still showing
        // imputation progress, then a background transition). Capturing
        // metadata here once and persisting it lets the full-enum pass
        // skip the entire body of its per-asset loop.
        let phoneEntries: [(localId: String, modDate: Date?, creationDate: Date?, filename: String?, fileSize: Int64?, allResourceFilenames: [String])] =
            await Task.detached(priority: .userInitiated) {
                let opts = PHFetchOptions()
                opts.includeHiddenAssets = true
                opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                let fetch = PHAsset.fetchAssets(with: opts)
                let fetchCount = fetch.count
                var out: [(localId: String, modDate: Date?, creationDate: Date?, filename: String?, fileSize: Int64?, allResourceFilenames: [String])] = []
                out.reserveCapacity(fetchCount)
                var scanned = 0
                fetch.enumerateObjects { asset, _, _ in
                    let resources = PHAssetResource.assetResources(for: asset)
                    let primary = PhotoKitPhotoEnumerator.selectPrimaryResource(from: resources)
                    let fileSize = primary.flatMap(PhotoKitPhotoEnumerator.resourceFileSize)
                    // Collect EVERY resource's originalFilename — not
                    // just the primary's. For edited assets the PHAsset
                    // KVC filename becomes a UUID-style placeholder and
                    // the primary picker returns the rendered edit's
                    // name (`FullSizeRender.mov`), so Immich's
                    // pre-edit-upload filename (e.g. `IMG_2999.MOV`)
                    // ends up on one of the *other* resources. The
                    // alive-on-phone safety check needs all of them
                    // available downstream; capturing them once during
                    // the existing PHAssetResource enumeration is
                    // free relative to making the same call later.
                    let allNames = resources.map(\.originalFilename).filter { !$0.isEmpty }
                    out.append((
                        asset.localIdentifier,
                        asset.modificationDate,
                        asset.creationDate,
                        primary?.originalFilename,
                        fileSize,
                        allNames
                    ))
                    scanned += 1
                    if scanned % 200 == 0 || scanned == fetchCount {
                        progressEmitter(scanned, fetchCount)
                    }
                }
                return out
            }.value
        let totalPhone = phoneEntries.count

        // Side-effect: persist the metadata we just captured for every
        // enumerated phone asset into `LocalAssetMetadataStore`. The
        // subsequent `runFullEnumeration` → `hashAllCurrentAssets` →
        // `recordFullEnumerationMetadata` pass filters its work to ids
        // not already in the store, so this write makes the entire
        // function a no-op for the assets imputation just walked. On
        // the user's 108k library that's the difference between
        // ~50 silent minutes and ~50 milliseconds.
        do {
            let now = Date()
            let metadataEntries = phoneEntries.map { entry in
                LocalAssetMetadata(
                    localIdentifier: entry.localId,
                    originalFileName: entry.filename,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modDate,
                    fileSize: entry.fileSize,
                    observedAt: now,
                    allResourceFilenames: entry.allResourceFilenames
                )
            }
            try? await self.localAssetMetadataStore.record(metadataEntries)
            syncLog.notice("[cairn.impute] piggyback metadata recorded for \(metadataEntries.count) phone assets (skips redundant PHAssetResource enumeration during full-enum)")
        }

        // 3. Skip localIds already in LocalHashStore. Imputation only
        //    fills gaps — it never downgrades a verified entry.
        //    Track per-skip-reason counts so the activity feed can
        //    explain *why* the residue is the size it is.
        let cachedIds = (try? await self.localHashStore.allLocalIdentifiers()) ?? []

        var seedable: [(localId: String, checksums: Set<Checksum>, modDate: Date?)] = []
        var alreadyCachedMatches = 0
        var missingFilename = 0
        var missingCreationDate = 0
        var noServerMatch = 0
        var ambiguousPhoneSide = 0
        var livePhotoSkipped = 0
        for entry in phoneEntries {
            // Skip rows already in the cache before counting skip
            // reasons — those aren't residue, they're already done.
            if cachedIds.contains(entry.localId) {
                // Only count as alreadyCachedMatches if it would have
                // matched. Cheaper to compute the key first if metadata
                // is present, but if it isn't, it's still cache-resident
                // so no skip-reason category applies.
                if let filename = entry.filename, !filename.isEmpty,
                   let created = entry.creationDate,
                   byKey[JoinKey(filename: filename, secondsSince1970: Int(created.timeIntervalSince1970))] != nil {
                    alreadyCachedMatches += 1
                }
                continue
            }
            guard let filename = entry.filename, !filename.isEmpty else {
                missingFilename += 1
                continue
            }
            guard let created = entry.creationDate else {
                missingCreationDate += 1
                continue
            }
            let key = JoinKey(filename: filename, secondsSince1970: Int(created.timeIntervalSince1970))
            if ambiguous.contains(key) {
                ambiguousPhoneSide += 1
                continue
            }
            guard let serverAsset = byKey[key] else {
                noServerMatch += 1
                continue
            }
            // Live Photos are EXCLUDED from imputation entirely.
            // Build-95 attempted to include the paired motion video's
            // checksum via livePhotoVideoId, but Immich processes
            // motion videos at upload time (transcoding, container
            // changes), so the server's stored SHA1 systematically
            // doesn't match the on-device SHA1. Imputing the wrong
            // motion-video checksum then surfaces as a phantom
            // deletion candidate the moment ObservedStore retains the
            // real phone-side hash from any prior sync (which is
            // the steady-state condition after a Clear Hash Cache).
            //
            // Letting Live Photos fall through to local hashing
            // costs the imputation speedup for them but keeps the
            // identity model honest. Non-Live-Photo stills
            // (the majority of camera-roll content) still benefit.
            //
            // The detection signal: a non-nil livePhotoVideoId on
            // the matched server asset means it's the still photo
            // half of a Live Photo pair on the server side.
            if serverAsset.livePhotoVideoId != nil {
                livePhotoSkipped += 1
                continue
            }
            seedable.append((entry.localId, [serverAsset.checksum], entry.modDate))
        }
        let hits = seedable.count + alreadyCachedMatches

        // 4. Near-zero-hit fallback. On a library with more than 100
        //    assets, if hits/total < 5% the user is likely on a fresh
        //    phone (restored from backup) or has a server library
        //    that wasn't uploaded from this device. Imputing the
        //    handful of matches buys little and accepting heuristic
        //    risk for negligible reward isn't worth it; bail.
        if totalPhone > 100, hits > 0, Double(hits) / Double(totalPhone) < 0.05 {
            return ImputationOutcome(
                imputed: 0,
                hits: hits,
                ambiguous: ambiguousCount,
                alreadyCached: alreadyCachedMatches,
                totalPhone: totalPhone,
                fellBack: true,
                missingFilename: missingFilename,
                missingCreationDate: missingCreationDate,
                noServerMatch: noServerMatch,
                ambiguousPhoneSide: ambiguousPhoneSide,
                livePhotoSkipped: livePhotoSkipped
            )
        }

        // 5. Seed LocalHashStore. setImputed replaces any prior entries
        //    for the localId (no-op for the just-checked "not cached"
        //    case but keeps the API symmetric with `set`).
        //    Progress posts every 50 writes (and once at end) so the
        //    "Matching from server…" phase no longer sits silent — the
        //    InitialScanScreen's trustSeededLine renders the imputed
        //    count and ticks live as setImputed finishes each batch.
        // Seed in chunks of one transaction each rather than one commit
        // per entry. 80k individual setImputed calls were 80k SQLite
        // saves with no hashing I/O to amortize them — most of the
        // observed multi-minute imputation phase. Chunk size bounds both
        // the batch's predicate IN-clause and the progress granularity.
        var imputedCount = 0
        let seedChunkSize = 1000
        var chunkStart = 0
        while chunkStart < seedable.count {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + seedChunkSize, seedable.count)
            var batch: [String: (checksums: Set<Checksum>, modificationDate: Date?)] = [:]
            batch.reserveCapacity(chunkEnd - chunkStart)
            for i in chunkStart..<chunkEnd {
                let entry = seedable[i]
                batch[entry.localId] = (entry.checksums, entry.modDate)
            }
            try await self.localHashStore.setImputedBatch(batch)
            imputedCount += (chunkEnd - chunkStart)
            chunkStart = chunkEnd
            let snapshot = imputedCount
            await MainActor.run { [weak self] in
                guard let self else { return }
                let prev = self.model.syncProgress
                self.model.syncProgress = .init(
                    hashed: prev?.hashed ?? 0,
                    total: prev?.total ?? 0,
                    // Preserve nil through imputation — the hash baseline is
                    // captured later, on the first onHashProgress emit.
                    initialHashed: prev?.initialHashed,
                    imputed: snapshot
                )
            }
        }

        return ImputationOutcome(
            imputed: imputedCount,
            hits: hits,
            ambiguous: ambiguousCount,
            alreadyCached: alreadyCachedMatches,
            totalPhone: totalPhone,
            fellBack: false,
            missingFilename: missingFilename,
            missingCreationDate: missingCreationDate,
            noServerMatch: noServerMatch,
            ambiguousPhoneSide: ambiguousPhoneSide,
            livePhotoSkipped: livePhotoSkipped
        )
    }

    // MARK: - Live reconciliation

    /// Sendable products of the off-main alive-on-phone library scan, so
    /// the full-library enumeration + per-Live-Photo PHAssetResource calls
    /// never touch the MainActor. `liveLocalIds` doubles as the
    /// present-on-device id set the edit-retirement and orphan passes need.
    private struct AliveScan: Sendable {
        let totalVisibleAssets: Int
        let liveLocalIds: Set<String>
        let alivePhoneAssetKeys: Set<AlivePhoneAssetKey>
    }

    @MainActor
    fileprivate func performLiveReconciliation(
        client: ImmichClient,
        observed: SwiftDataObservedStore,
        exclusions: SwiftDataExclusionStore,
        confirmed: SwiftDataConfirmedDeletedStore
    ) async throws {
        let syncStart = Date()

        // Reset the narration buffers and start the high-level phase
        // progression. Transitions go: .preparing → .hashing → .reconciling
        // → .finalizing → .idle. `.fetchingServer` runs in parallel with
        // the prep+scan; we don't drive `model.syncPhase` through it (the
        // user-facing CTA wants linear progress), but we do append a
        // synthetic `.fetchingServer` entry to `model.syncTimeline` once
        // its duration is known.
        model.resetSyncNarration()
        model.transitionSyncPhase(to: .preparing)
        model.appendSyncActivity(.init(kind: .note, detail: "Sync started"))

        await refreshLibrarySizeStats()

        // Refresh server count concurrently — don't block the scan.
        // Bootstrap already seeded this value; this just picks up
        // any changes since last launch.
        Task { [weak self] in
            guard let stats = try? await client.assetStatistics() else { return }
            await MainActor.run {
                guard let self else { return }
                self.model.library = self.model.library.with(server: stats.total)
            }
        }

        serverChecksumSet = nil
        // Reset the server-fetch progress counters so a fresh sync
        // shows "0 fetched" before pages start arriving rather than
        // the trailing value from a prior sync. `serverAssetsExpected`
        // gets populated by the `assetStatistics()` call kicked off
        // in parallel.
        model.serverAssetsFetched = 0
        model.serverAssetsExpected = nil
        let hashStoreRef = self.localHashStore
        let serverFetchStart = Date()
        // Fire-and-forget assetStatistics to populate the expected
        // total so the UI can render a proportional progress bar
        // during the paginated fetch below. Independent of the
        // `model.library.with(server:)` update task above — that one
        // is informational; this one feeds an in-flight progress UI.
        Task { [weak self] in
            guard let stats = try? await client.assetStatistics() else { return }
            await MainActor.run { self?.model.serverAssetsExpected = stats.total }
        }
        // Page-loaded callback: hops to the MainActor to update
        // `model.serverAssetsFetched`. Called once per successful
        // page inside `listAllAssets`; cheap (microseconds per hop).
        let onServerPage: @Sendable (Int) async -> Void = { [weak self] count in
            await MainActor.run {
                self?.model.serverAssetsFetched = count
            }
        }
        // Same target as onServerPage, for the incremental stream path —
        // so a long /sync/stream bootstrap surfaces a live "streaming X"
        // counter instead of sitting at 0 the way it used to. The
        // coordinator calls this synchronously on its executor, so hop to
        // the main actor inside.
        let onStreamProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in self?.model.serverAssetsFetched = count }
        }
        // Snapshot the feature-flag + coordinator/cache refs onto the
        // Task's locals so the closure doesn't re-touch MainActor state
        // mid-flight. The closure decides bootstrap-vs-incremental
        // discovery once at task start.
        let useIncremental = model.settings.useIncrementalServerSync
        let coordinator = self.serverAssetSyncCoordinator
        let cache = self.serverAssetCacheStore
        // Generation of the sync that owns this reconciliation. The
        // server-fetch task's completion writes model state; gate those
        // writes on this so a fetch that finishes after its sync was
        // cancelled (or superseded) can't stomp the live UI.
        let syncGeneration = await MainActor.run { self.model.syncGeneration }
        let serverAssetsTask = Task { [weak self] () -> (assets: [ServerAsset], outcome: DiscoveryOutcome) in
            let assets: [ServerAsset]
            let outcome: DiscoveryOutcome
            if useIncremental, let coordinator, let cache {
                do {
                    let summary = try await coordinator.syncToCache(onProgress: onStreamProgress)
                    syncLog.notice("[cairn.sync.stream] mode=\(summary.mode.rawValue, privacy: .public) upserted=\(summary.upserted, privacy: .public) deleted=\(summary.deleted, privacy: .public) ignored=\(summary.ignored, privacy: .public) durationMs=\(summary.durationMs, privacy: .public)")
                    assets = try await cache.snapshot()
                    outcome = .incremental(summary)
                } catch let err as ImmichClientError {
                    let reason: String
                    var sessionLikelyRejected = false
                    if case .missingScope(let scopes) = err {
                        reason = "missing scope \(scopes.first ?? "?")"
                        syncLog.warning("[cairn.sync.stream] missing scopes \(scopes.joined(separator: ","), privacy: .public) — falling back to paginated")
                    } else if case .httpStatus(let code, _) = err {
                        // 401 with a session token in use = the server
                        // revoked or wiped our session. Auto-clear the
                        // local token so subsequent calls don't keep
                        // hitting the same wall, and surface a
                        // .sessionExpired banner so the user can sign
                        // back in to restore incremental sync.
                        if code == 401, client.sessionToken != nil {
                            sessionLikelyRejected = true
                            reason = "session expired (401)"
                        } else {
                            reason = "stream HTTP \(code)"
                        }
                        syncLog.warning("[cairn.sync.stream] failed (\(String(describing: err), privacy: .public)) — falling back to paginated")
                    } else {
                        reason = "stream error"
                        syncLog.warning("[cairn.sync.stream] failed (\(String(describing: err), privacy: .public)) — falling back to paginated")
                    }
                    if sessionLikelyRejected, let self {
                        await MainActor.run {
                            try? self.secretStore.setSessionToken(nil)
                            if let existingClient = self.immichClient {
                                let updatedClient = existingClient.withSessionToken(nil)
                                self.immichClient = updatedClient
                                if let cache = self.serverAssetCacheStore,
                                   let acks = self.syncAckStore {
                                    self.serverAssetSyncCoordinator = ServerAssetSyncCoordinator(
                                        client: updatedClient,
                                        cache: cache,
                                        ackStore: acks
                                    )
                                }
                            }
                            self.model.hasSessionToken = false
                            self.model.degraded = .sessionExpired
                        }
                        syncLog.warning("[cairn.session] server returned 401 with session token — cleared local token, surfaced .sessionExpired banner")
                    }
                    assets = try await client.listAllAssets(onPageLoaded: onServerPage)
                    outcome = .paginated(fallbackReason: reason)
                } catch {
                    syncLog.warning("[cairn.sync.stream] failed (\(String(describing: error), privacy: .public)) — falling back to paginated")
                    assets = try await client.listAllAssets(onPageLoaded: onServerPage)
                    outcome = .paginated(fallbackReason: "stream error")
                }
            } else {
                assets = try await client.listAllAssets(onPageLoaded: onServerPage)
                outcome = .paginated(fallbackReason: nil)
            }
            let checksums = Set(assets.map(\.checksum))
            let nonTrashed = assets.filter { !$0.isTrashed }.count
            // Seed matched from already-cached hashes so a resumed scan
            // doesn't show 0 matched until the final reconciliation.
            let localChecksums = (try? await hashStoreRef.allChecksums()) ?? []
            let initialMatched = checksums.intersection(localChecksums).count
            // Build the per-checksum lookup once. Same allocation
            // budget as the existing `serverChecksumSet` build, just
            // a richer payload — used to enrich the Excluded assets
            // screen with filenames + thumbnail asset IDs.
            var byChecksum: [Checksum: ServerAsset] = [:]
            byChecksum.reserveCapacity(assets.count)
            for asset in assets { byChecksum[asset.checksum] = asset }
            await MainActor.run {
                // Don't write server state for a sync that's no longer the
                // active one. Without this guard a fetch that completes
                // after its sync threw/was cancelled would mutate the
                // Server / Matched counts under the idle UI (or a successor
                // sync). Mirrors the isSyncing guard on onHashProgress.
                guard let self, self.model.syncGeneration == syncGeneration else { return }
                self.serverChecksumSet = checksums
                self.serverAssetsByChecksum = byChecksum
                self.model.library = self.model.library.with(server: nonTrashed, matched: initialMatched)
            }
            return (assets, outcome)
        }
        // Cancel the server fetch on any early exit from this function
        // (thrown error, cancellation). On the happy path the task is
        // already awaited to completion before we return here, so this is
        // a no-op; on an early throw it stops an otherwise-orphaned
        // paginated fetch that could run for minutes of network + battery.
        defer { serverAssetsTask.cancel() }

        guard let reconciler = persistentChangeReconciler else {
            throw CancellationError()
        }

        // Fast initial scan: when enabled, block on the server fetch
        // BEFORE the hash pass so we can pre-seed LocalHashStore with
        // imputed checksums for matching phone localIds. The hash pass
        // skips them via the modDate-match path; only the residue
        // hashes locally. This serializes server-fetch with hashing
        // (the existing flow ran them in parallel), but the residue
        // savings dwarf the serialization cost on any non-trivial
        // library. The near-zero-hit fallback inside `runImputationPass`
        // protects the fresh-phone-restore case.
        // Imputation only fires when there's no PhotoKit change-token
        // — i.e., this sync is a full enumeration (bootstrap install,
        // post-Clear-Hash-Cache, post-Reset-Index, post-Rescan-Library).
        // On normal incremental syncs the cache is already populated
        // and imputation would find nothing to seed; running it anyway
        // just serializes the server fetch + PHAssetResource enumeration
        // ahead of the hash pass for no payoff. The change-token is
        // the load-bearing signal because every place that resets the
        // hash cache also clears the token.
        let isBootstrapScan = (try? await tokenStore?.load()) == nil
        // Imputation-completion gate: a partition that has never run a
        // full imputation pass to completion gets another shot, even
        // if the token is already set. This catches the failure mode
        // where the user starts a sync (token nil → imputation runs),
        // sync gets interrupted partway through, but a subsequent full
        // enumeration completes and saves the token. Under a
        // token-only gate that asset cache would be locked out of
        // server matching until the user manually wiped it. The
        // marker lives in UserDefaults keyed by partition; see
        // `imputationCompletionKey(for:)`.
        let imputationPreviouslyCompleted: Bool = {
            guard let partition = self.currentPartitionKey else { return false }
            return Self.imputationCompletedAt(for: partition) != nil
        }()
        if model.settings.fastInitialScan && (isBootstrapScan || !imputationPreviouslyCompleted) {
            model.transitionSyncPhase(to: .imputingFromServer)
            let imputeStart = Date()
            let serverPrefetch = try await serverAssetsTask.value
            let outcome = try await runImputationPass(serverAssets: serverPrefetch.assets)
            let imputeMs = Int(Date().timeIntervalSince(imputeStart) * 1000)
            syncLog.notice("[cairn.impute] seeded=\(outcome.imputed) hits=\(outcome.hits) ambiguous=\(outcome.ambiguous) alreadyCached=\(outcome.alreadyCached) totalPhone=\(outcome.totalPhone) fellBack=\(outcome.fellBack) missingFilename=\(outcome.missingFilename) missingCreationDate=\(outcome.missingCreationDate) noServerMatch=\(outcome.noServerMatch) ambiguousPhoneSide=\(outcome.ambiguousPhoneSide) durationMs=\(imputeMs)")
            model.syncTimeline.append(.init(
                phase: .imputingFromServer,
                startedAt: imputeStart,
                durationMs: imputeMs
            ))
            // Main summary line.
            let detail: String
            if outcome.fellBack {
                detail = "Trust-seeding skipped — only \(outcome.hits.formatted(.number))/\(outcome.totalPhone.formatted(.number)) matched (full local hashing)"
            } else if outcome.imputed == 0 {
                detail = "Trust-seeding: 0 new matches (full local hashing for residue)"
            } else {
                detail = "Trust-seeded \(outcome.imputed.formatted(.number)) of \(outcome.totalPhone.formatted(.number)) from server"
            }
            model.appendSyncActivity(.init(kind: .note, detail: detail))
            // Skip-reason breakdown: surface as a follow-up activity
            // entry so curious users can see *why* the residue is the
            // size it is. Each category is a real, distinct cause:
            // ambiguous = filename + capture-date collision on server;
            // no server match = simply not on Immich; missing metadata
            // = PHAsset lacks one of the join-key fields. Only emit
            // when there's something to say.
            let breakdownParts = Self.imputationBreakdownParts(outcome: outcome)
            if !breakdownParts.isEmpty {
                model.appendSyncActivity(.init(
                    kind: .note,
                    detail: "Hashing locally: " + breakdownParts.joined(separator: ", ")
                ))
            }
            // Mark imputation completed for this partition. Reaching
            // this point means `runImputationPass` ran end-to-end
            // without throwing — every matchable phone localId got
            // its server checksum seeded (or was skipped for a
            // documented reason: Live Photo, already-cached,
            // ambiguous, missing metadata, no server match). Future
            // syncs on the same cache skip the imputation phase
            // entirely until the marker is cleared via
            // `clearHashCache`, `verifyImputedChecksums`, or
            // sign-out.
            if let partition = self.currentPartitionKey {
                Self.markImputationCompleted(for: partition)
            }
            // Surface the imputed count onto syncProgress so it survives
            // through the hash pass and the InitialScanScreen stats strip
            // can render "imputed Y" alongside "hashed X of Z". The hash
            // pass will reconstruct syncProgress on first emit; both
            // onHashProgress paths preserve the imputed field by reading
            // the prior value before overwriting.
            //
            // `total` set to the phone library count, NOT 0. Previously
            // we left total at 0, which had a visible regression: the
            // InitialScanScreen's top counter would jump from
            // "0 / <library size>" (its fallback before imputation
            // surfaces) to "0 / 0" (after imputation resets), then to
            // "1 / <hash pass total>" on the first hash tick. The user
            // saw the scope of work disappear briefly. Pinning total to
            // the phone count keeps the counter monotonic and meaningful
            // through the imputation→hashing transition.
            // initialHashed: nil — NOT 0. After imputation seeds the cache,
            // the hash pass resumes near the imputed count, so its first
            // emit's `done` is large; capturing that as the baseline (nil →
            // done on first emit) keeps session work at ~0. Writing 0 here
            // instead made sessionWork = done immediately → optimistic ETA
            // and a poisoned persisted per-asset rate.
            model.syncProgress = .init(hashed: 0, total: outcome.totalPhone, initialHashed: nil, imputed: outcome.imputed)
            // Drop back to .preparing so the next phase transition (to
            // .hashing on first onHashProgress) reads as a single step
            // in the timeline rather than a regression.
            model.transitionSyncPhase(to: .preparing)
        }

        // High-level phase stays `.preparing` until the first
        // `onHashProgress` callback flips it to `.hashing`. The scan's
        // internal phases (fetchPersistentChanges, observeAndFilter,
        // discoverUntracked, etc.) appear in the activity feed via
        // `onPhaseChange` for forensic detail without disrupting the
        // user-visible CTA.
        let t0 = Date()
        let scan = try await reconciler.runDeletionScan(skipDrain: true)
        syncLog.notice("[cairn.sync] scan took \(Int(Date().timeIntervalSince(t0) * 1000))ms (events=\(scan.changeEventsProcessed))")
        let burst = scan.newlyConfirmedDeleted.count
        // Surface the propagation-cutoff outcome to the activity feed
        // when any deletions were filtered out. Without this the
        // setting feels invisible — the user enables it, deletes some
        // old photos, sees nothing change in the app. The line in the
        // SyncDetailSheet timeline is the receipt that it worked.
        if scan.skippedTooOldForPropagation > 0,
           let days = model.settings.propagationMaxAgeDays {
            model.appendSyncActivity(.init(
                kind: .note,
                detail: "Skipped propagation (older than \(days)d): \(scan.skippedTooOldForPropagation.formatted(.number))"
            ))
        }

        // The reconciler has already mutated `ConfirmedDeletedStore`,
        // `LocalHashStore`, and `ObservedStore`. Persist the
        // scan-derived stats onto the model NOW so a downstream
        // failure (server unreachable, etc.) doesn't leave the UI
        // showing stale numbers — the local detection is real and
        // user-visible regardless of what happens next.
        model.lastScanBurstCount = burst
        await refreshLibrarySizeStats()

        try Task.checkCancellation()
        let t1 = Date()

        // Post-scan prelude: four independent reads that each block on
        // their own SwiftData fetch / PhotoKit enumeration. Run them
        // in parallel rather than serially. On a 50k-photo library with
        // Live Photo doubling, each store fetch is hundreds of ms
        // (full-table materialization), and the visible PHAsset fetch
        // off the main actor is another hundred-ish; serial they stack
        // to ~1s of dead time before the engine sees anything.
        // The whole alive-on-phone scan — the full-library PHAsset fetch,
        // the per-asset enumeration, the per-Live-Photo PHAssetResource
        // calls (~10ms each), and the metadata-store key build — runs on
        // one detached task and returns plain Sendable products. The old
        // code fetched off-main but then enumerated on the MainActor
        // (three separate times, see below), with the Live-Photo resource
        // calls stacking to tens of seconds of main-thread stall on a
        // library with many Live Photos. `liveLocalIds` is reused by the
        // edit-retirement and orphan passes instead of re-enumerating.
        let metadataStoreRef = self.localAssetMetadataStore
        let testingCap = Self.resolveTestingAssetCap()
        async let cacheSummaryTask = self.localHashStore.summary()
        async let observedSnapshotTask = observed.snapshot()
        async let exclusionSnapshotTask = exclusions.snapshot()
        async let confirmedSnapshotTask = confirmed.snapshot()
        async let aliveScanTask: AliveScan = Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            // Include hidden + every PhotoKit source type for the
            // alive-on-phone safety check. An asset still physically
            // present in any form on the device — Hidden album, iCloud
            // Shared Library, iTunes-synced — is alive from cairn's
            // deletion-detection perspective even though some of those
            // sources can't be trashed from Photos.app. Filtering to
            // .typeUserLibrary only would let a server asset whose
            // (filename, fileCreatedAt) matched a Hidden/CloudShared
            // phone asset slip past the filter into quarantine.
            opts.includeHiddenAssets = true
            opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let fetch = PHAsset.fetchAssets(with: opts)
            var total = fetch.count
            if let cap = testingCap, total > cap { total = cap }

            // Build a `(filename, fileCreatedAt-second)` set for every
            // alive phone asset. **Filename source robustness:**
            // `PHAsset.value(forKey:"filename")` (KVC) and
            // `PHAssetResource.originalFilename` (what Immich's uploader
            // ships) can disagree (usually case), so populate from BOTH
            // PHAsset KVC and the metadata store; the AlivePhoneAssetKey
            // constructor lowercases so case-only differences fall away.
            var aliveKeys = Set<AlivePhoneAssetKey>()
            var liveIds = Set<String>()
            aliveKeys.reserveCapacity(fetch.count * 2)
            liveIds.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in
                liveIds.insert(asset.localIdentifier)
                guard let created = asset.creationDate else { return }
                let createdSecond = Int(created.timeIntervalSince1970)
                if let filename = asset.value(forKey: "filename") as? String, !filename.isEmpty {
                    aliveKeys.insert(AlivePhoneAssetKey(filename: filename, secondsSince1970: createdSecond))
                }
                // Live Photos: include the paired motion video's resource
                // filename — Immich uploads it as a SEPARATE server asset
                // (the MOV) so without it the motion half misses the
                // filter and surfaces as a phantom quarantine entry.
                // mediaSubtypes guards the ~10ms PHAssetResource call to
                // only assets that actually have a paired video.
                if asset.mediaSubtypes.contains(.photoLive) {
                    let resources = PHAssetResource.assetResources(for: asset)
                    for resource in resources {
                        switch resource.type {
                        case .pairedVideo, .fullSizePairedVideo:
                            let resName = resource.originalFilename
                            if !resName.isEmpty {
                                aliveKeys.insert(AlivePhoneAssetKey(filename: resName, secondsSince1970: createdSecond))
                            }
                        default:
                            break
                        }
                    }
                }
            }
            // Metadata-store source — same filename path as the imputation
            // join and Immich's uploader. For edited assets the server's
            // entry has the pre-edit upload filename, which lives in a
            // non-primary resource captured at imputation time. Filter to
            // live ids so a since-deleted row can't suppress a real hash.
            let metadataForAliveSet = (try? await metadataStoreRef.snapshot()) ?? []
            for entry in metadataForAliveSet where liveIds.contains(entry.localIdentifier) {
                guard let created = entry.creationDate else { continue }
                let createdSecond = Int(created.timeIntervalSince1970)
                if let filename = entry.originalFileName, !filename.isEmpty {
                    aliveKeys.insert(AlivePhoneAssetKey(filename: filename, secondsSince1970: createdSecond))
                }
                for resourceName in entry.allResourceFilenames where !resourceName.isEmpty {
                    aliveKeys.insert(AlivePhoneAssetKey(filename: resourceName, secondsSince1970: createdSecond))
                }
            }
            return AliveScan(totalVisibleAssets: total, liveLocalIds: liveIds, alivePhoneAssetKeys: aliveKeys)
        }.value

        let cacheSummary = try await cacheSummaryTask
        let local = cacheSummary.checksums
        let indexedCount = cacheSummary.distinctIdCount
        let aliveScan = await aliveScanTask
        let totalVisibleAssets = aliveScan.totalVisibleAssets
        let liveLocalIds = aliveScan.liveLocalIds
        let alivePhoneAssetKeys = aliveScan.alivePhoneAssetKeys

        syncLog.notice("[cairn.sync] local checksums fetched in \(Int(Date().timeIntervalSince(t1) * 1000))ms (\(indexedCount) entries)")

        // Bulk metadata backfill: cairn's observer-time metadata path
        // only covers events fired while cairn is alive (foreground or
        // recently active). Older photos cached before the metadata
        // store existed, OR observed during a window when cairn was
        // suspended, end up in `LocalHashStore` without a matching
        // `LocalAssetMetadataStore` row. Without metadata, the orphan
        // reconciler can't match those assets if they later get
        // edited-then-deleted-fast (the eager observer can miss the
        // change, and observeAndFilter can't fetch a deleted asset).
        // Snapshot metadata for any cached id that's still alive in
        // PhotoKit but missing from the store. Idempotent —
        // `record(_:)` upserts, so repeating the call is cheap.
        await backfillMetadataIfNeeded()

        let t2 = Date()
        // Drain the parallel store fetches kicked off above. They were
        // launched alongside `cacheSummary` / `visibleFetch` so by the
        // time `backfillMetadataIfNeeded` returns most are already
        // resolved — these awaits collect, they don't initiate.
        var observedSet = try await observedSnapshotTask
        // Recovery path for users upgrading across the SwiftData entity
        // rename (StoredEverSeenChecksum → StoredObservedChecksum). The
        // new table starts empty; LocalHashStore is keyed on a different
        // @Model class and survives intact. Without this, an
        // events=0 incremental sync after upgrade (stable library, no
        // PhotoKit changes since the last token) leaves Observed empty
        // and silently produces zero deletion candidates forever — the
        // engine's diff requires an entry in Observed for any candidate
        // to surface. Backfilling from LocalHashStore (`local`, fetched
        // a few lines up) brings the witness set back without re-hashing
        // PHAsset bytes — the SHA1s are already cached. Idempotent:
        // subsequent syncs see Observed populated and skip this branch.
        if observedSet.isEmpty, !local.isEmpty {
            syncLog.notice("[cairn.recover] observed empty, localHash has \(local.count, privacy: .public) entries — bootstrapping")
            try? await observed.union(local)
            observedSet = local
        }
        let exclusionSnapshot = try await exclusionSnapshotTask
        let exclusionSet = Set(exclusionSnapshot.keys)
        let exclusionAddedAt = exclusionSnapshot.mapValues(\.addedAt)
        var confirmedMap = try await confirmedSnapshotTask

        // Edit-retirement: union the firstObserved SHA1s for every
        // alive `localIdentifier` into the "current local" set the
        // engine sees. Effect: while a photo is alive in PhotoKit,
        // its original-content anchor never enters the candidate
        // diff, even if intermediate edits have replaced its
        // current-bytes SHA1 in `LocalHashStore`. Without this
        // union, edited-but-kept photos would have their original
        // SHA1 silently classified as a deletion candidate (it's in
        // observed, absent from current-bytes), and the wrong-
        // semantics fix would be only half-applied.
        var editRetirementHeld: Set<Checksum> = []
        if let editRetirementStore {
            let snapshot = try await editRetirementStore.snapshot()
            if !snapshot.isEmpty {
                // Reuse the alive-scan's liveLocalIds instead of
                // re-enumerating the full library on main again.
                for (id, anchorSet) in snapshot where liveLocalIds.contains(id) {
                    editRetirementHeld.formUnion(anchorSet)
                }
            }
        }
        let extendedLocal = local.union(editRetirementHeld)

        // Wrongly-stamped quarantine cleanup. Pre-fix code paths (and
        // the EditRetirementStore-migration era) may have stamped the
        // original SHA1 of an edited photo into ConfirmedDeletedStore
        // when the edit ran. Now that it's anchored as firstObserved
        // for a live id, it must NOT be sitting in quarantine — the
        // edit-retirement contract is "anchor protects, no quarantine."
        // Drop any held checksum from ConfirmedDeletedStore on every
        // sync. Idempotent: nothing to remove for assets that never
        // hit the buggy path. Mirrors the existing `confirmedDeleted.remove(allRecentlyObserved)`
        // restoration step but covers the wider "anchored by alive id"
        // surface, including assets not edited this scan.
        if !editRetirementHeld.isEmpty {
            try? await confirmed.remove(editRetirementHeld)
        }

        syncLog.notice("[cairn.sync] store snapshots took \(Int(Date().timeIntervalSince(t2) * 1000))ms (edit-retirement-held=\(editRetirementHeld.count))")
        let t3 = Date()
        // Drive the high-level phase to `.fetchingServer` for the blocking
        // wait on the parallel fetch. The fetch started early (alongside
        // hashing), but the user-visible CTA stayed pinned on
        // "Processing N/N" at 100% while we blocked here — on a large
        // server that's minutes of frozen-looking UI. Stepping the phase
        // surfaces the real "Fetching server" label + the live
        // serverAssetsFetched counter (StatusScreen reads it for this
        // phase). The transition to `.reconciling` below closes the entry;
        // if the fetch already finished it's a sub-frame flash. This
        // replaces the old already-closed synthetic timeline entry (which
        // double-counted once a real phase entry existed).
        model.transitionSyncPhase(to: .fetchingServer)
        let (serverAssets, discoveryOutcome) = try await serverAssetsTask.value
        let serverFetchMs = max(0, Int(Date().timeIntervalSince(serverFetchStart) * 1000))
        syncLog.notice("[cairn.sync] server fetch took \(Int(Date().timeIntervalSince(t3) * 1000))ms (\(serverAssets.count) assets)")
        model.appendSyncActivity(.init(
            kind: .fetched,
            detail: "\(serverAssets.count.formatted(.number)) server assets · \(serverFetchMs.formatted(.number))ms"
        ))
        // Discovery-path receipt — lets the user confirm which
        // server-side discovery path actually ran without grepping
        // OSLog. Streaming success in success tone; paginated fallback
        // after a streaming attempt in warn tone (so a missing-scope
        // or transient failure is visible at a glance).
        let discoveryEntry = Self.discoveryActivity(for: discoveryOutcome)
        model.appendSyncActivity(discoveryEntry)

        try Task.checkCancellation()
        model.transitionSyncPhase(to: .reconciling)

        // Thumbhash population runs after reconciliation completes —
        // don't block the user-facing result for cache warming.
        let thumbhashWork: [(assetId: String, data: Data)] = {
            guard thumbnailStore != nil else { return [] }
            return serverAssets.compactMap { asset in
                guard observedSet.contains(asset.checksum),
                      let hash = asset.thumbhash,
                      let data = Data(base64Encoded: hash) else { return nil }
                return (assetId: asset.id, data: data)
            }
        }()
        let settings = model.settings

        // Scope-aware indexing: when the user has restricted cairn to
        // specific albums, fetch the album-tag map and pass it (along
        // with the active scope) into the engine. The engine filters
        // Observed entries to only those whose tags intersect the scope
        // before computing candidates — out-of-scope photos quietly
        // exclude themselves from the diff. `nil` for full-library mode
        // (the default) preserves the legacy behavior.
        let observedAlbumTags: [Checksum: Set<String>]?
        let selectedAlbumScope: Set<String>?
        switch settings.indexingScope {
        case .fullLibrary:
            observedAlbumTags = nil
            selectedAlbumScope = nil
        case .selectedAlbums(let albumIds):
            observedAlbumTags = (try? await observed.snapshotWithTags()) ?? [:]
            selectedAlbumScope = albumIds
        }

        // Limited Photo Access guard: when iOS is exposing only the
        // user's selected subset, force `.strict` regardless of the
        // user's stored preference. Combined with the reconciler-side
        // `requireExplicitDeletionEvent` flag, this means selection
        // changes that vanish photos from PhotoKit go to pendingReview
        // instead of trash. The user's original strictness setting is
        // preserved in `CairnSettings`; if they switch back to full
        // access later, normal behavior resumes.
        let rawAuth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let limitedAccess = rawAuth == .limited
        let effectiveStrictness: DeletionStrictness = limitedAccess
            ? .strict
            : settings.deletionStrictness

        // Mirror the live auth state into the model so Settings'
        // Permissions row + the Status one-shot toast can show real
        // state. Set on every sync so foreground transitions back from
        // iOS Settings (.limited → .full or vice versa) reflect
        // immediately on the next reconciliation.
        let photoAuthOutcome: SetupScreen.PhotoAuthOutcome? = {
            switch rawAuth {
            case .authorized: return .full
            case .limited:    return .limited
            case .denied, .restricted: return .denied
            case .notDetermined: return nil
            @unknown default: return nil
            }
        }()
        await MainActor.run { self.model.photoAuthStatus = photoAuthOutcome }

        // Limbo recovery. Find SHA1s in Observed-but-absent-from-Local
        // that were never stamped to ConfirmedDeleted — i.e., the
        // user-visible "unconfirmed delete candidate that bypasses
        // quarantine" bug class. Several edge cases produce this state:
        // mid-loop reconciler interrupt, race in the re-hash path,
        // deletion event for an id with empty `LocalHashStore[id]`.
        // Stamp them with `now` so the engine routes them through the
        // held bucket on this pass instead of straight to ready-to-trash.
        // The user gets a quarantine window to review / exclude.
        // Idempotent: a SHA1 that's already in confirmedMap is excluded
        // upfront, and `ConfirmedDeletedStore.union` is first-write-wins
        // so a parallel-path stamp can't reset the clock.
        // Alive-on-phone safety: any server asset whose `(filename,
        // fileCreatedAt-second)` matches a live phone asset gets
        // protected. Collect those checksums so limbo recovery
        // doesn't stamp them and the engine knows to suppress them
        // as deletion candidates downstream.
        var aliveOnPhoneServerChecksums = Set<Checksum>()
        for asset in serverAssets where !asset.isTrashed {
            guard let filename = asset.originalFileName, !filename.isEmpty,
                  let created = asset.fileCreatedAt else { continue }
            // ±1 second tolerance, matching ReconciliationEngine's
            // alive-on-phone match exactly. An exact-second check here
            // would let the engine suppress a 1s-drifted asset as a
            // candidate (it tolerates ±1s) while limbo recovery still
            // stamped it into ConfirmedDeleted — quietly aging out the
            // quarantine clock on an asset that's actually alive, so a
            // later genuine delete skips the held bucket. The two probes
            // must agree on the boundary case the tolerance was added for.
            let baseSecond = Int(created.timeIntervalSince1970)
            let aliveOnAnyAdjacent = (baseSecond - 1...baseSecond + 1).contains { sec in
                alivePhoneAssetKeys.contains(
                    AlivePhoneAssetKey(filename: filename, secondsSince1970: sec)
                )
            }
            if aliveOnAnyAdjacent {
                aliveOnPhoneServerChecksums.insert(asset.checksum)
            }
        }

        let limboNow = Date()
        let limbo = ReconciliationEngine.limboChecksums(
            observed: observedSet,
            currentLocal: extendedLocal,
            confirmedDeleted: Set(confirmedMap.keys),
            excluded: exclusionSet.union(aliveOnPhoneServerChecksums)
        )
        if !limbo.isEmpty {
            syncLog.notice("[cairn.recover] limbo: \(limbo.count, privacy: .public) observed-not-local-not-confirmed checksum(s) stamping to ConfirmedDeleted with now — starts a fresh quarantine clock")
            try? await confirmed.union(limbo, at: limboNow)
            // Reflect the stamping into the in-memory map so the
            // current engine call sees the freshly-stamped entries
            // and routes them to the held bucket on THIS pass — not
            // next pass. Without this, the engine would still see
            // them as unconfirmed for one more sync.
            for checksum in limbo {
                confirmedMap[checksum] = limboNow
            }
        }

        // Diagnostic: surface the inputs and outputs of the engine
        // call so "items in unconfirmed not held" reports can be
        // narrowed without a rebuild. Counts only.
        syncLog.notice("[cairn.engine] input: server=\(serverAssets.count, privacy: .public) local=\(extendedLocal.count, privacy: .public) observed=\(observedSet.count, privacy: .public) confirmed=\(confirmedMap.count, privacy: .public) excluded=\(exclusionSet.count, privacy: .public) strictness=\(String(describing: effectiveStrictness), privacy: .public) qDays=\(settings.quarantineDays, privacy: .public) scope=\(selectedAlbumScope?.count ?? -1, privacy: .public)")

        // Run the engine off the MainActor — it's a pure function over
        // up-to-100k-element sets (hundreds of ms of CPU) and blocking
        // main for it stutters the UI. Inputs and output are all Sendable.
        let engineInput = ReconciliationInput(
            serverAssets: serverAssets,
            currentLocalChecksums: extendedLocal,
            observedChecksums: observedSet,
            excludedChecksums: exclusionSet,
            confirmedDeletedAt: confirmedMap,
            now: Date(),
            quarantineDays: settings.quarantineDays,
            strictness: effectiveStrictness,
            observedAlbumTags: observedAlbumTags,
            selectedAlbumScope: selectedAlbumScope,
            excludedAtByChecksum: exclusionAddedAt,
            alivePhoneAssetKeys: alivePhoneAssetKeys
        )
        var result = await Task.detached(priority: .userInitiated) {
            ReconciliationEngine.compute(engineInput)
        }.value
        syncLog.notice("[cairn.engine] output: delete=\(result.deleteCandidates.count, privacy: .public) pending=\(result.pendingReviewCandidates.count, privacy: .public) held=\(result.heldByQuarantineCandidates.count, privacy: .public) recycled=\(result.recycledExclusionCandidates.count, privacy: .public) excludedCount=\(result.excludedCandidateCount, privacy: .public) aliveOnPhone=\(result.aliveOnPhoneCandidateCount, privacy: .public)")

        // Per-candidate diagnostic dump for the delete bucket. Tells us
        // whether each candidate landed there via:
        //   - "past-quarantine"  → ConfirmedDeleted has an old timestamp
        //                          (first-write-wins collision OR genuinely
        //                          old confirmed delete)
        //   - "unconfirmed"      → no ConfirmedDeleted entry at all
        //                          (PhotoKit change-log + orphan sweep both
        //                          missed it at deletion time)
        // Capped at 20 lines per sync to keep journals readable on bursts.
        let nowForDiag = Date()
        let qInterval = TimeInterval(max(0, model.settings.quarantineDays) * 86_400)
        for asset in result.deleteCandidates.prefix(20) {
            let confirmedAt = confirmedMap[asset.checksum]
            let status: String
            if let confirmedAt {
                let pastQuarantine = confirmedAt.addingTimeInterval(qInterval) <= nowForDiag
                status = pastQuarantine ? "past-quarantine(confirmedAt=\(confirmedAt.ISO8601Format()))" : "in-quarantine(confirmedAt=\(confirmedAt.ISO8601Format()))"
            } else {
                status = "unconfirmed(no ConfirmedDeleted entry)"
            }
            syncLog.notice("[cairn.diag] delete candidate: file=\(asset.originalFileName ?? "(no name)", privacy: .public) checksum=\(asset.checksum.base64, privacy: .public) \(status, privacy: .public)")
        }

        // Token-expiry safety gate. A full re-enumeration triggered by an
        // expired (or unparseable) persistent-change token means the change
        // events that would have stamped quarantine clocks are gone — every
        // deletion accumulated during the dormant window arrives as a
        // negative-signal-only candidate. Promote them all into the pending
        // bucket so the user reviews them before anything trashes,
        // regardless of strictness.
        let wasTokenExpiry = scan.fullEnumerationCause == .tokenExpired
        if wasTokenExpiry {
            result = result.gatedForReview()
        }

        // Orphan reconciliation. Catches the cull-burst case the
        // SHA1-based reconciler can't see: photo taken, uploaded to
        // Immich, and deleted locally before cairn could hash it. By
        // the time we look, the bytes are gone — `ObservedStore` never
        // got the checksum. We match server assets against the metadata
        // we captured at observer time (filename + creationDate). See
        // `OrphanReconciler` for the match algorithm. Orphans land in
        // `pendingReviewCandidates` regardless of strictness; the user
        // must approve.
        var inferredOrphanLocalIds: [Checksum: String] = [:]
        do {
            let metadataSnapshot = try await self.localAssetMetadataStore.snapshot()
            syncLog.notice("[cairn.orphan] starting match: serverAssets=\(serverAssets.count, privacy: .public) metadata=\(metadataSnapshot.count, privacy: .public) observed=\(observedSet.count, privacy: .public)")
            if !metadataSnapshot.isEmpty {
                // Reuse the alive-scan's liveLocalIds — same filter, same
                // result as re-enumerating the full library a third time.
                let presentLocalIds = liveLocalIds
                // Surface orphan candidate counts BEFORE the match so we
                // can tell whether the gate is filtering them out vs the
                // match algorithm not finding correlations.
                let nonTrashedNonObserved = serverAssets.filter { !$0.isTrashed && !observedSet.contains($0.checksum) }
                let absentMetadataCount = metadataSnapshot.filter { !presentLocalIds.contains($0.localIdentifier) }.count
                syncLog.notice("[cairn.orphan] gate: server-non-trashed-non-observed=\(nonTrashedNonObserved.count, privacy: .public) metadata-for-absent-ids=\(absentMetadataCount, privacy: .public) presentLocalIds=\(presentLocalIds.count, privacy: .public)")
                let orphans = await Task.detached(priority: .userInitiated) {
                    OrphanReconciler.match(
                        serverAssets: serverAssets,
                        observed: observedSet,
                        metadata: metadataSnapshot,
                        presentLocalIdentifiers: presentLocalIds
                    )
                }.value
                syncLog.notice("[cairn.orphan] match result: \(orphans.count, privacy: .public) orphans found")
                if !orphans.isEmpty {
                    let existingPendingChecksums = Set(result.pendingReviewCandidates.map(\.checksum))
                    let existingDeleteChecksums = Set(result.deleteCandidates.map(\.checksum))
                    var pending = result.pendingReviewCandidates
                    for orphan in orphans {
                        inferredOrphanLocalIds[orphan.serverAsset.checksum] = orphan.matchedMetadata.localIdentifier
                        // By definition, orphans aren't in observed and
                        // therefore can't be in deleteCandidates; the
                        // pending dedup is defensive in case future
                        // engine changes blur the line.
                        guard !existingPendingChecksums.contains(orphan.serverAsset.checksum),
                              !existingDeleteChecksums.contains(orphan.serverAsset.checksum) else { continue }
                        pending.append(orphan.serverAsset)
                    }
                    result = ReconciliationOutput(
                        deleteCandidates: result.deleteCandidates,
                        newlyObservedChecksums: result.newlyObservedChecksums,
                        assetsInObserved: result.assetsInObserved,
                        excludedCandidateCount: result.excludedCandidateCount,
                        pendingReviewCandidates: pending,
                        heldByQuarantineCandidates: result.heldByQuarantineCandidates,
                        // These two default to []/0 in the initializer, so
                        // omitting them silently dropped the engine's
                        // recycled-exclusion review surface and the
                        // alive-on-phone telemetry whenever an inferred
                        // orphan co-occurred. Carry them through.
                        recycledExclusionCandidates: result.recycledExclusionCandidates,
                        aliveOnPhoneCandidateCount: result.aliveOnPhoneCandidateCount
                    )
                    syncLog.notice("[cairn.sync] inferred \(orphans.count) orphan(s) via metadata match")
                }
            }
        } catch {
            // Metadata snapshot is best-effort; a SwiftData fetch failure
            // shouldn't poison the whole reconciliation. The standard
            // observed reconciler still ran and its results are fine.
            syncLog.error("[cairn.sync] orphan match skipped: \(Self.describeSyncError(error), privacy: .public)")
        }

        let serverNonTrashed = serverAssets.filter { !$0.isTrashed }.count
        let liveLibrary = CairnFixtures.LibrarySize(
            local: totalVisibleAssets,
            indexed: indexedCount,
            server: serverNonTrashed,
            matched: result.assetsInObserved,
            candidates: result.deleteCandidates.count
        )
        // Merge the source-id mapping from three sources, in
        // precedence order:
        //   1. Persistent `deletionSourceStore` snapshot — the
        //      authoritative record for items not retired in this
        //      pass; survives across syncs so quarantined entries
        //      from previous scans keep their grouping linkage.
        //   2. This scan's `sourceLocalIdentifierByChecksum` —
        //      most-recent retire from a particular id; overrides
        //      the persistent record for items just retired.
        //   3. Inferred orphans — filename-matching is the most
        //      authoritative for items the SHA1 reconciler can't
        //      see (deleted before hash, never in observed).
        // Each step overwrites collisions so later sources win.
        var mergedSourceIds: [Checksum: String] = [:]
        if let deletionSourceStore {
            mergedSourceIds = (try? await deletionSourceStore.snapshot()) ?? [:]
        }
        for (checksum, localId) in scan.sourceLocalIdentifierByChecksum {
            mergedSourceIds[checksum] = localId
        }
        for (checksum, localId) in inferredOrphanLocalIds {
            mergedSourceIds[checksum] = localId
        }
        model.reconciliation = .init(
            deleteCandidates: result.deleteCandidates,
            pendingReviewCandidates: result.pendingReviewCandidates,
            heldByQuarantineCandidates: result.heldByQuarantineCandidates,
            confirmedDeletedAt: confirmedMap,
            quarantineDays: settings.quarantineDays,
            inferredOrphanLocalIdentifiers: inferredOrphanLocalIds,
            firstObservedAnchors: editRetirementHeld,
            sourceLocalIdentifiersByChecksum: mergedSourceIds,
            recycledExclusionCandidates: result.recycledExclusionCandidates
        )
        model.library = liveLibrary
        // `lastScanBurstCount` was already set right after the
        // local scan completed (so failed syncs surface it too).
        // Don't reassign here.
        model.inferredOrphanCount = inferredOrphanLocalIds.count
        model.lastScanWasTokenExpiryFullEnum = wasTokenExpiry
        // Detect the false→true transition on the initial-scan flag
        // so we can flip `keepScreenAwakeDuringSync` off automatically
        // on first successful completion. Default-on is calibrated
        // for the first-scan case; subsequent incremental syncs are
        // seconds-long and don't warrant the battery cost. Users who
        // want it back on for a specific big run (post-onboarding,
        // bulk delete) can re-enable in Settings → Library → Initial
        // scan, and that explicit re-enable persists through future
        // syncs.
        let wasFirstScanCompletion = (model.hasCompletedInitialScan == false)
        model.hasCompletedInitialScan = true
        if wasFirstScanCompletion && model.settings.keepScreenAwakeDuringSync {
            model.settings.keepScreenAwakeDuringSync = false
            Task { try? await self.settingsStore.save(self.model.settings) }
        }
        // Auto-trash the ready-to-trash candidates now, if the strictness
        // setting opts in (Balanced / Autonomous) and the safety rails
        // pass. Cautious leaves everything for manual confirmation. This
        // runs on every sync (foreground catch-up and background refresh),
        // so eligible deletions propagate without a tap. Prunes the
        // reconciliation + library counts in place, so the snapshot below
        // reflects the post-trash state.
        await autoTrashIfEligible(
            result: result,
            serverNonTrashed: serverNonTrashed,
            localCount: totalVisibleAssets,
            isFirstRun: wasFirstScanCompletion
        )

        model.lastCheckedAt = model.reconciliation?.computedAt
        await persistSnapshotFromModel()

        // Detect "user restored locally what cairn already trashed on
        // Immich." Intersect this scan's freshly-observed checksums
        // against successful trash runs from the journal (within
        // Immich's 30-day hard-delete window). A non-empty intersection
        // means the Immich mobile app's upload will silently no-op
        // because the asset is still in Immich trash with the same
        // SHA1 — silent data divergence the user can't see until the
        // server purges. The Status banner surfaces the count so the
        // user can restore on Immich too.
        if let journal {
            let entries = (try? await journal.readAll()) ?? []
            let trashedIndex = JournalReader.recentlyTrashedChecksums(
                in: entries,
                withinDays: 30
            )
            let observed = scan.recentlyObservedChecksums
            var matches: [Checksum: JournalReader.TrashedRecord] = [:]
            for cs in observed {
                if let record = trashedIndex[cs] {
                    matches[cs] = record
                }
            }
            model.restoredAfterCairnTrash = matches
        }

        // Cancel any queued pending-trash intent whose checksum cairn just
        // re-observed on the phone. The reconciler un-confirms restored
        // checksums (resetting the quarantine clock), but a
        // PendingTrashIntent queued from an earlier offline session is a
        // separate retry queue that drainPendingTrashes runs immediately
        // after this sync completes. Without this prune, a user who
        // deleted a photo while offline (intent queued) and then restored
        // it from Recently Deleted would have the server copy trashed
        // anyway on the next sync — and 30 days later Immich hard-deletes
        // a photo that's alive on the phone. Matches by checksum, so
        // duplicate-content assets are protected too (consistent with the
        // engine's trulyAbsent guard).
        let restoredChecksums = scan.recentlyObservedChecksums
        if !restoredChecksums.isEmpty {
            try? await self.pendingTrashStore?.removeIntents(containingAnyOf: restoredChecksums)
        }

        // Engine + orphan match + restoredAfterCairnTrash detection are
        // done; what's left is journal writes and the post-sync refresh
        // helpers. Bucket all of that under `.finalizing` so the
        // user-facing CTA shows a meaningful label during the brief
        // post-reconciliation cleanup.
        model.transitionSyncPhase(to: .finalizing)
        model.appendSyncActivity(.init(
            kind: .stamped,
            detail: "engine: delete=\(result.deleteCandidates.count.formatted(.number)) pending=\(result.pendingReviewCandidates.count.formatted(.number)) held=\(result.heldByQuarantineCandidates.count.formatted(.number))"
        ))

        // Record what kicked off this sync FIRST. Falls back to
        // .unknown for legacy call sites that don't pre-set the
        // model trigger (the initial bootstrap path, etc.).
        let trigger = await MainActor.run { self.model.lastSyncTrigger ?? .unknown }
        // No-op-sync filter: BG-triggered fires that found nothing
        // to do don't journal — otherwise the tail would fill with
        // empty hourly background pokes. Manual / Shortcut / Debug
        // triggers ALWAYS journal even when no-op, because a user
        // who taps Sync wants confirmation that cairn ran. Unknown
        // (legacy) follows the BG semantics — conservative.
        let triggerForcesLog: Bool = {
            switch trigger {
            case .manualForeground, .shortcut, .debugManualFire:
                return true
            case .scheduledBackground, .scheduledHashContinuation, .unknown:
                return false
            }
        }()
        let isEventfulSync = scan.didFullEnumeration
            || scan.changeEventsProcessed > 0
            || scan.drainedFromQueue > 0
            || triggerForcesLog
        if isEventfulSync, let journal {
            let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
            let elapsedMs = Int(Date().timeIntervalSince(syncStart) * 1000)
            try? await journal.append(.init(
                timestamp: Date(timeIntervalSince1970: syncStart.timeIntervalSince1970),
                runId: runId,
                event: .syncStarted(trigger: trigger)
            ))
            do {
                try await journal.append(.init(
                    runId: runId,
                    event: .syncCompleted(
                        indexed: indexedCount,
                        candidates: result.deleteCandidates.count,
                        pendingReview: result.pendingReviewCandidates.count,
                        deferredLarge: scan.deferredLarge,
                        deferredLargeBytes: scan.deferredLargeBytes,
                        deferredTimeout: scan.deferredTimeout,
                        elapsedMs: elapsedMs
                    )
                ))
                // Sync-transitions companion event: record edit-
                // retirement partitioning and per-source attribution
                // of confirmed deletions. Only fires when at least one
                // count is non-zero so the journal isn't spammed with
                // empty transition rows on quiet syncs. Same runId as
                // the syncCompleted above so the journal-tail banding
                // groups them visually.
                let totalTransitions = scan.editsProtected
                    + scan.editsQuarantined
                    + scan.confirmedFromChangeLog
                    + scan.confirmedFromOrphanSweep
                if totalTransitions > 0 {
                    try? await journal.append(.init(
                        runId: runId,
                        event: .syncTransitions(
                            editsProtected: scan.editsProtected,
                            editsQuarantined: scan.editsQuarantined,
                            confirmedFromChangeLog: scan.confirmedFromChangeLog,
                            confirmedFromOrphanSweep: scan.confirmedFromOrphanSweep
                        )
                    ))
                }
            } catch {
                // The sync itself succeeded; only the forensic journal
                // entry failed to write. Don't alert the user — that
                // makes a successful sync look like an error. Log for
                // diagnostics; the next sync will record a fresh entry.
                syncLog.error("[cairn.sync] journal write failed: \(Self.describeSyncError(error), privacy: .public)")
            }
        }

        // Keep the live journal bounded: once it exceeds ~500 runs,
        // rotate the oldest whole runs out to the sibling archive file
        // (browsable via Settings → View archived history). Cheap no-op
        // until the threshold, and a no-op for the read-back paths —
        // rotation's guard keeps anything restore / the recently-trashed
        // detector needs in the live file. Best-effort: a rotation
        // failure must never fail a sync.
        if let journal {
            do {
                if let outcome = try await journal.rotateIfNeeded(keepingRuns: Self.journalLiveRunCap) {
                    syncLog.notice("[cairn.journal.rotate] archived \(outcome.archivedRuns, privacy: .public) run(s) / \(outcome.archivedEntries, privacy: .public) entries; live now \(outcome.liveRuns, privacy: .public) run(s)")
                }
            } catch {
                syncLog.error("[cairn.journal.rotate] failed: \(Self.describeSyncError(error), privacy: .public)")
            }
        }

        // Buffer enough history for the user to scroll back through
        // recent activity on Status without leaving the screen. 500
        // rows ≈ months of normal use; reading them once costs the
        // same I/O as the full `readAll` we already run for runs.
        // Settings → Clear journal still exists for anyone who wants
        // the slate wiped.
        await refreshJournalTail()

        await refreshDeferredQueueSummary()
        await refreshRunsList()
        await refreshQuarantineCount()

        // Toast priority: the limited-photos heads-up wins on first
        // detection — explaining the trust downgrade matters more than
        // the routine "up to date" pat-on-the-back. After it fires
        // once (gated in UserDefaults below), subsequent syncs return
        // to the normal upToDate / nil pattern.
        if limitedAccess && !Self.hasShownLimitedPhotosNotice() {
            Self.markLimitedPhotosNoticeShown()
            showStatusToast(.limitedPhotosNotice)
        } else if result.deleteCandidates.isEmpty && result.pendingReviewCandidates.isEmpty {
            showStatusToast(.upToDate(indexed: indexedCount, total: totalVisibleAssets))
        } else {
            model.syncToast = nil
        }

        if let thumbStore = thumbnailStore, !thumbhashWork.isEmpty {
            Task {
                try? await thumbStore.saveThumbhashes(thumbhashWork)
                let thumbhashCap = self.model.settings.thumbhashCapMB * 1024 * 1024
                try? await thumbStore.evictThumbhashes(overCapBytes: thumbhashCap)
                let thumbnailCap = self.model.settings.thumbnailCacheCapMB * 1024 * 1024
                try? await thumbStore.evictThumbnails(overCapBytes: thumbnailCap)
            }
        }

        // Refresh the displayed connection latency now that we just
        // hit the server hard enough to know it's reachable. Free
        // signal (single small request, off the critical path) and
        // means the Settings → Connection latency reading is never
        // older than the last successful sync.
        Task { [weak self] in
            await self?.checkServerHealth()
        }
    }

    /// How many of the most-recent runs the live journal keeps before
    /// `rotateIfNeeded` rotates older whole runs out to the archive.
    /// ~500 runs spans months of normal use and far exceeds the 30-day
    /// window the read-back paths care about, so the rotation guard
    /// almost never has to override it. One constant to tune.
    static let journalLiveRunCap = 500

    /// Repopulate `model.journalTail` from the on-disk journal. Called
    /// inline at sync end and from every mutating action (trash, restore,
    /// exclude) so the Status journal card reflects the new event
    /// immediately rather than waiting for the next sync to roll
    /// through. Silent-no-op when the journal isn't yet wired or the
    /// read fails — preserves the previous tail rather than blanking it.
    @MainActor
    fileprivate func refreshJournalTail() async {
        guard let journal else { return }
        guard let recent = try? await journal.lastEntries(limit: 500) else { return }
        // Per-key activation filter: hide entries that predate the
        // current API key's first verify. Keeps the user's mental
        // model "this key sees what this key did" consistent without
        // destroying the on-disk journal. `.distantPast` on bootstrap
        // upgrade installs means no filtering, so existing users see
        // everything.
        let cutoff = currentKeyActivatedAt ?? .distantPast
        let filtered = recent.filter { $0.timestamp >= cutoff }
        let timeFormat = model.settings.timeDisplayFormat
        model.journalTail = Array(
            CairnFixtures.JournalTailEntry
                .from(entries: filtered, timeFormat: timeFormat)
                .reversed()
        )
    }

    /// Formatted, newest-first archived history for the viewer screen.
    /// Mirrors `refreshJournalTail` (same per-key activation filter,
    /// same row formatting) but reads the rotated-out archive file and
    /// *returns* the rows instead of caching them on the model — the
    /// screen owns their lifetime, so nothing lingers once it closes.
    @MainActor
    fileprivate func loadArchivedHistoryImpl() async -> [CairnFixtures.JournalTailEntry] {
        guard let journal else { return [] }
        guard let archived = try? await journal.readArchive() else { return [] }
        let cutoff = currentKeyActivatedAt ?? .distantPast
        let filtered = archived.filter { $0.timestamp >= cutoff }
        let timeFormat = model.settings.timeDisplayFormat
        return Array(
            CairnFixtures.JournalTailEntry
                .from(entries: filtered, timeFormat: timeFormat)
                .reversed()
        )
    }

    @MainActor
    fileprivate func refreshRunsList() async {
        guard let journal else {
            model.runs = []
            model.runAssets = [:]
            return
        }
        let entries = (try? await journal.readAll()) ?? []
        // Filter to entries that happened on/after this key's first
        // verify. See `refreshJournalTail` for the rationale.
        let cutoff = currentKeyActivatedAt ?? .distantPast
        let visibleEntries = entries.filter { $0.timestamp >= cutoff }
        let summaries = JournalReader.summarize(visibleEntries)
        model.runs = summaries.compactMap(CairnFixtures.RunFixture.from)

        var perRun: [String: [CairnFixtures.CandidateFixture]] = [:]
        for entry in visibleEntries {
            guard case .planningTrash(let targets) = entry.event else { continue }
            var seen: Set<String> = Set((perRun[entry.runId] ?? []).compactMap(\.assetId))
            var bucket = perRun[entry.runId] ?? []
            for target in targets where !seen.contains(target.assetId) {
                bucket.append(CairnFixtures.CandidateFixture.from(target))
                seen.insert(target.assetId)
            }
            perRun[entry.runId] = bucket
        }
        model.runAssets = perRun
    }

    @MainActor
    fileprivate func refreshLibrarySizeStats() async {
        let activeScope = model.settings.indexingScope
        let hashStore = self.localHashStore

        // Everything heavy — scope membership, the full-library PHAsset
        // fetch, and the cache counts — runs off the MainActor. This
        // function is @MainActor and called twice per sync (plus bootstrap
        // and post-action sites); doing the fetch inline stuttered the UI.
        // Only the final model write hops back.
        struct Stats: Sendable {
            let totalVisible: Int
            let indexed: Int?   // nil → indexedKnown:false (stores unavailable)
            let imputed: Int
        }
        let stats: Stats = await Task.detached(priority: .userInitiated) {
            // Resolve scope membership once. `.selectedAlbums(...)`
            // rescopes both the "Phone" count and the "Indexed"
            // intersection so the numbers reflect the user's chosen
            // managed slice. `.fullLibrary` keeps legacy semantics.
            let membership = PhotoKitScopeEnumerator.membershipMap(for: activeScope)

            let totalVisible: Int
            if let membership {
                // `.selectedAlbums(...)` — count is the union of localIds
                // across selected albums. `Phone` reads as "photos cairn
                // can manage right now," consistent with the engine's
                // scope filter.
                var n = membership.localIds.count
                if let cap = Self.resolveTestingAssetCap(), n > cap { n = cap }
                totalVisible = n
            } else {
                // Match the broader filter used by
                // `performLiveReconciliation`'s `visibleFetch` (build
                // 116+) and the alive-on-phone safety check's
                // enumeration. Without this match the `library.local`
                // "On iPhone" stat oscillates between the narrow filter's
                // count (set at sync-start) and the broad filter's count
                // (set mid-sync), rendering alternating values every sync.
                let opts = PHFetchOptions()
                opts.includeHiddenAssets = true
                opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                let fetch = PHAsset.fetchAssets(with: opts)
                var n = fetch.count
                if let cap = Self.resolveTestingAssetCap(), n > cap { n = cap }
                totalVisible = n
            }

            // "Indexed" counts distinct PHAssets (localIdentifiers) in the
            // hash cache. Use the SAME global indexedCount() the engine
            // path (liveLibrary) and the onHashProgress callback use, so
            // the value is identical at every point in a sync — no
            // transient dip. The previous version applied a per-account
            // (∩ Observed) and per-scope (∩ membership) filter here, which
            // read lower than the engine's global count whenever the cache
            // held imputed-but-not-yet-observed rows — so the displayed
            // "Indexed" flipped scoped → global across a sync (the reported
            // bug). The engine path the value settles on is global, so this
            // aligns the mid-sync writes to it. Stores unavailable → nil →
            // UI shows "—" rather than a stale count.
            let indexed: Int? = try? await hashStore.indexedCount()
            let imputed = (try? await hashStore.imputedCount()) ?? 0
            return Stats(totalVisible: totalVisible, indexed: indexed, imputed: imputed)
        }.value

        if let indexed = stats.indexed {
            model.library = model.library.with(
                local: stats.totalVisible,
                indexed: indexed,
                indexedKnown: true,
                imputed: stats.imputed
            )
        } else {
            model.library = model.library.with(local: stats.totalVisible, indexedKnown: false)
        }
    }

    /// Capture the current status counts to disk so the next cold launch
    /// can render them before sync runs. Best-effort cosmetic — failures
    /// log and bail; nothing user-visible depends on this succeeding.
    /// Drop a failed trash run into the persistent retry queue. No-op
    /// if the per-server pending store hasn't been activated (we
    /// shouldn't reach here without one, but guard rather than crash).
    fileprivate func enqueueFailedTrash(
        runId: String,
        candidates: [ServerAsset],
        assetsInPurview: Int,
        error: Error
    ) async {
        guard let store = pendingTrashStore else { return }
        let intent = PendingTrashIntent(
            createdAt: Date(),
            runId: runId,
            assets: candidates,
            assetsInPurview: assetsInPurview,
            lastAttemptedAt: Date(),
            attemptCount: 1,
            lastError: Self.describeSyncError(error)
        )
        do {
            try await store.enqueue(intent)
        } catch {
            syncLog.error("[cairn.retry-queue] enqueue failed: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    /// Common offline/failure-handling path for `confirmTrash` and
    /// `approvePending`: enqueue the intent for retry, optimistically
    /// prune the candidates from the live reconciliation so they
    /// leave the Pending Review / quarantine view, surface the error
    /// (deduped per disconnected session), and refresh the
    /// runs/journal/pending-trash counts.
    ///
    /// The user has *decided* to trash these items; the retry queue
    /// preserves that decision until connectivity returns. Without
    /// the prune, the items would remain visible in Pending Review
    /// even though they're already queued — confusing.
    fileprivate func handleTrashFailure(
        runId: String,
        candidates: [ServerAsset],
        assetsInPurview: Int,
        error: Error
    ) async {
        await enqueueFailedTrash(
            runId: runId,
            candidates: candidates,
            assetsInPurview: assetsInPurview,
            error: error
        )
        if let existing = model.reconciliation {
            let cks = Set(candidates.map(\.checksum))
            model.reconciliation = existing.removing(checksums: cks)
        }
        model.recordSyncError(
            Self.describeSyncError(error),
            isNetworkLike: Self.isNetworkLikeError(error)
        )
        await refreshRunsList()
        await refreshJournalTail()
        await refreshPendingTrashCount()
    }

    /// Auto-trash the ready-to-trash candidates a sync just surfaced, when
    /// the strictness setting opts in and the safety rails pass. Called at
    /// the end of `performLiveReconciliation`.
    ///
    /// - `.strict` (Cautious): never auto-trashes — always manual.
    /// - `.trusting` (Balanced): past-quarantine candidates auto-trash.
    /// - `.autonomous` (Autonomous): candidates auto-trash immediately (no
    ///   quarantine wait — the engine already put them straight into
    ///   `deleteCandidates`).
    ///
    /// The safety rails (percent cap + count floor from Settings, plus the
    /// first-run / empty-library guards) gate the run exactly as a manual
    /// trash would. On a rail **abort**, cairn does NOT auto-delete: the
    /// candidates stay surfaced as "Ready to trash" for the user to review
    /// and confirm manually. Everything moves to Immich's Trash (30-day
    /// recovery), same as a manual run.
    @MainActor
    private func autoTrashIfEligible(
        result: ReconciliationOutput,
        serverNonTrashed: Int,
        localCount: Int,
        isFirstRun: Bool
    ) async {
        let strictness = model.settings.deletionStrictness
        guard strictness.autoTrashesEligibleCandidates else { return }
        guard !result.deleteCandidates.isEmpty else { return }
        guard let client = immichClient, let journal else { return }

        let config = SafetyConfig(
            maxDeletePercent: model.settings.maxDeletePercent / 100.0,
            minDeleteCountForThreshold: model.settings.minDeleteFloor
        )
        let decision = SafetyRails.evaluate(
            reconciliation: result,
            totalServerAssets: serverNonTrashed,
            currentLocalCount: localCount,
            isFirstRun: isFirstRun,
            isDryRun: false,
            config: config
        )
        guard case .proceed = decision else {
            if case .abort(let reason) = decision {
                syncLog.notice("[cairn.autotrash] safety rail refused auto-trash (\(String(describing: reason), privacy: .public)); \(result.deleteCandidates.count, privacy: .public) candidate(s) left for manual review")
            }
            return
        }

        let candidates = result.deleteCandidates
        let assetsInPurview = candidates.count + result.pendingReviewCandidates.count
        let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let orchestrator = TrashOrchestrator(writer: client, journal: journal)
        do {
            let trashResult = try await orchestrator.run(
                runId: runId,
                candidates: candidates,
                assetsInPurview: assetsInPurview,
                dryRun: false
            )
            let trashedIds = Set(trashResult.trashedAssetIds)
            let trashedChecksums = Set(candidates.filter { trashedIds.contains($0.id) }.map(\.checksum))
            if let existing = model.reconciliation {
                model.reconciliation = existing.removing(checksums: trashedChecksums)
            }
            let trashedCount = trashedChecksums.count
            if trashedCount > 0 {
                let current = model.library
                model.library = current.with(
                    server: max(0, current.server - trashedCount),
                    matched: max(0, current.matched - trashedCount),
                    candidates: max(0, current.candidates - trashedCount)
                )
            }
            model.recordSyncSuccess()
            syncLog.notice("[cairn.autotrash] auto-trashed \(trashedCount, privacy: .public) candidate(s) under \(String(describing: strictness), privacy: .public) strictness")
            await refreshRunsList()
            await refreshJournalTail()
        } catch {
            // A failed auto-trash is queued for retry (drainPendingTrashes)
            // and the candidates pruned from view — the strictness setting
            // is a standing decision to trash, same as a manual confirm.
            await handleTrashFailure(
                runId: runId,
                candidates: candidates,
                assetsInPurview: assetsInPurview,
                error: error
            )
        }
    }

    /// Refresh `model.pendingTrashCount` and `pendingTrashStuckCount`
    /// from the per-server retry queue. Cheap: queue is small and the
    /// snapshot pre-decodes the JSON ServerAsset payload only when
    /// callers need it. Here we only need the row count + attempt
    /// counts.
    fileprivate func refreshPendingTrashCount() async {
        guard let store = pendingTrashStore else {
            await MainActor.run {
                self.model.pendingTrashCount = 0
                self.model.pendingTrashStuckCount = 0
            }
            return
        }
        let intents = (try? await store.snapshot()) ?? []
        let cap = await self.model.settings.maxRetryAttempts
        let stuck = intents.filter { $0.attemptCount >= cap }.count
        let total = intents.count
        await MainActor.run {
            self.model.pendingTrashCount = total
            self.model.pendingTrashStuckCount = stuck
        }
    }

    /// Drain the persistent retry queue once. Called automatically
    /// after each successful `requestSync` and from the manual "Retry
    /// now" UI action. Per-intent semantics:
    ///
    /// - **Stuck (`attemptCount >= maxRetryAttempts`)**: skipped by
    ///   the auto-drainer; only surfaces if the user invokes via the
    ///   "Retry now" path which passes `force: true`.
    /// - **Recently attempted (<60s)**: skipped to avoid tight retry
    ///   loops when multiple drain triggers fire close together.
    /// - **Success**: removed from the queue.
    /// - **404 from server**: removed from the queue. The asset is
    ///   gone — nothing left to trash.
    /// - **Any other failure**: `attemptCount` bumps,
    ///   `lastAttemptedAt` updates, `lastError` records the new
    ///   diagnostic. Stays in the queue.
    fileprivate func drainPendingTrashes(force: Bool) async {
        guard let store = pendingTrashStore,
              let client = await self.immichClient,
              let journal = await self.journal else { return }
        let intents = (try? await store.snapshot()) ?? []
        guard !intents.isEmpty else { return }
        let cap = await self.model.settings.maxRetryAttempts
        let now = Date()
        let orchestrator = TrashOrchestrator(writer: client, journal: journal)
        for intent in intents {
            // Skip stuck intents in the auto-drain path; the manual
            // Retry-now button passes force=true to override.
            if !force, intent.attemptCount >= cap { continue }
            // Debounce: don't hammer a server that just rejected us a
            // moment ago. 60s is enough to clear a transient blip
            // (DNS, 502, brief restart) without making the queue feel
            // dead between syncs.
            if let last = intent.lastAttemptedAt, now.timeIntervalSince(last) < 60, !force {
                continue
            }
            do {
                _ = try await orchestrator.run(
                    runId: intent.runId,
                    candidates: intent.assets,
                    assetsInPurview: intent.assetsInPurview,
                    dryRun: false
                )
                try? await store.remove(intent.id)
            } catch let e as ImmichClientError {
                if case .httpStatus(let code, _) = e, code == 404 {
                    // The assets are no longer on the server — drop
                    // the intent rather than retrying forever.
                    try? await store.remove(intent.id)
                } else {
                    let msg = Self.describeSyncError(e)
                    try? await store.update(
                        intent.id,
                        lastAttemptedAt: now,
                        attemptCount: intent.attemptCount + 1,
                        lastError: msg
                    )
                }
            } catch {
                let msg = Self.describeSyncError(error)
                try? await store.update(
                    intent.id,
                    lastAttemptedAt: now,
                    attemptCount: intent.attemptCount + 1,
                    lastError: msg
                )
            }
        }
        await self.refreshPendingTrashCount()
        await self.refreshRunsList()
        await self.refreshJournalTail()
    }

    @MainActor
    fileprivate func persistSnapshotFromModel() async {
        guard let store = statusSnapshotStore else { return }
        let snapshot = StatusSnapshot(
            deleteCandidatesCount: model.library.candidates,
            matchedCount: model.library.matched,
            pendingReviewCount: model.reconciliation?.pendingReviewCandidates.count ?? 0,
            inferredOrphanCount: model.inferredOrphanCount,
            computedAt: model.reconciliation?.computedAt ?? model.lastCheckedAt ?? Date()
        )
        do {
            try await store.save(snapshot)
        } catch {
            syncLog.error("[cairn.snapshot] save failed: \(Self.describeSyncError(error), privacy: .public)")
        }

        // Persist the held-asset display payloads alongside the counts
        // so the quarantine queue rehydrates at next bootstrap without a
        // server fetch. Guarded on a non-nil reconciliation: the only
        // callers reach here right after setting (main sync) or pruning
        // (approve/exclude/dismiss) `model.reconciliation`, so the held
        // bucket is current. Skipping when nil avoids a stray empty
        // write wiping the store on a path that hasn't loaded a
        // reconciliation. `ConfirmedDeletedStore` stays the source of
        // truth for *which* items are held — this is only their display
        // data, reconciled back against it at bootstrap.
        if let quarantineStore = quarantinedAssetStore,
           let held = model.reconciliation?.heldByQuarantineCandidates {
            do {
                try await quarantineStore.replace(with: held)
            } catch {
                syncLog.error("[cairn.snapshot] held-asset persist failed: \(Self.describeSyncError(error), privacy: .public)")
            }
        }
    }

    @MainActor
    fileprivate func showStatusToast(_ toast: CairnAppModel.SyncToast) {
        model.syncToast = toast
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CairnAppModel.SyncToast.autoDismissSeconds * 1_000_000_000))
            guard self?.model.syncToast == toast else { return }
            // Explicit withAnimation here so the auto-dismiss is
            // animated even though the mutation happens inside a
            // detached Task. The `cairnBannerAnimation(value:)`
            // modifier on StatusScreen *should* be enough — it
            // watches bannerVisibilityKey which includes
            // `syncToast != nil` — but in practice SwiftUI doesn't
            // always pick up the animation context for state
            // mutations originating from Task contexts. Wrapping
            // here guarantees the .transition(.cairnBanner) on the
            // banner runs with the canonical springy timing.
            withAnimation(.cairnSpring) {
                self?.model.syncToast = nil
            }
        }
    }

    @MainActor
    /// Refresh `ObservedStore` album tags to match the currently
    /// selected scope. Called from a SwiftUI `.onChange` in
    /// CairnAppRoot whenever `model.settings.indexingScope` mutates.
    /// No-op for `.fullLibrary` (the engine bypasses the tag filter
    /// in that mode, so tags don't need to match anything). For
    /// `.selectedAlbums`, walks each selected album once via
    /// `PHAssetCollection.fetchAssetCollections`, builds a
    /// `[Checksum: Set<albumId>]` map by joining album membership
    /// against `LocalHashStore`'s `[localId: Set<Checksum>]`, and
    /// upserts via `recordObserved`. Idempotent.
    fileprivate func recomputeScopeTagsImpl() async {
        let scope = await MainActor.run { model.settings.indexingScope }
        guard case .selectedAlbums(let albumIds) = scope, !albumIds.isEmpty else {
            return
        }
        guard let observedStore = self.observedStore else { return }

        // PhotoKit enumeration of selected albums runs off-main —
        // potentially hundreds of localIdentifiers across multiple
        // albums, and we don't want to block any animations while it's
        // happening.
        let albumMembership = await Task.detached(priority: .userInitiated) {
            Self.enumerateAlbumMembership(albumIds: albumIds)
        }.value

        // Join with LocalHashStore: for each known localId in any
        // selected album, attribute its checksums to the album set.
        let allHashes: [String: Set<Checksum>]
        do {
            allHashes = try await self.localHashStore.snapshot()
        } catch {
            syncLog.error("[cairn.scope] hash-store snapshot failed during tag rebuild: \(Self.describeSyncError(error), privacy: .public)")
            return
        }

        var tagsByChecksum: [Checksum: Set<String>] = [:]
        for (localId, albumIdSet) in albumMembership {
            guard let checksums = allHashes[localId] else { continue }
            for checksum in checksums {
                tagsByChecksum[checksum, default: []].formUnion(albumIdSet)
            }
        }

        do {
            try await observedStore.recordObserved(tagsByChecksum)
            syncLog.notice("[cairn.scope] tagged \(tagsByChecksum.count, privacy: .public) observed entries across \(albumIds.count, privacy: .public) selected album(s)")
        } catch {
            syncLog.error("[cairn.scope] recordObserved failed during tag rebuild: \(Self.describeSyncError(error), privacy: .public)")
        }
    }

    /// Build a `[localId: Set<albumId>]` inverted map by enumerating
    /// each selected `PHAssetCollection`'s assets. Albums that don't
    /// resolve (deleted from Photos.app since the user picked them)
    /// are silently skipped — the Settings UI will surface the missing-
    /// album warning separately.
    nonisolated static func enumerateAlbumMembership(albumIds: Set<String>) -> [String: Set<String>] {
        let identifiers = Array(albumIds)
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var inverted: [String: Set<String>] = [:]
        collections.enumerateObjects { collection, _, _ in
            let albumId = collection.localIdentifier
            // Include hidden assets so Live Photo motion videos and
            // user-hidden items (which can still be in albums) show up
            // and align with how the reconciler enumerates the library.
            let assetOpts = PHFetchOptions()
            assetOpts.includeHiddenAssets = true
            let assets = PHAsset.fetchAssets(in: collection, options: assetOpts)
            assets.enumerateObjects { asset, _, _ in
                inverted[asset.localIdentifier, default: []].insert(albumId)
            }
        }
        return inverted
    }

    fileprivate func refreshDeferredQueueSummary() async {
        let entries = (try? await deferredHashStore.snapshot()) ?? []
        let ceilingBytes = Self.megabytesToBytes(model.settings.iCloudMaxEverBytesMB)

        var actionable = 0
        var aboveCeiling = 0
        var bytes: Int64 = 0
        for entry in entries {
            if let ceilingBytes, let size = entry.sizeBytes, size > ceilingBytes {
                aboveCeiling += 1
            } else {
                actionable += 1
                if let size = entry.sizeBytes { bytes += size }
            }
        }
        model.deferredQueue = .init(count: actionable, aboveCeiling: aboveCeiling, totalKnownBytes: bytes)
    }

    /// Empty every backing store the index touches: per-(URL, userId)
    /// engine state (observed, confirmed-deleted, change-token, edit
    /// retirement, deletion source, status snapshot) plus the global
    /// content-addressed caches (local hash store, deferred queue,
    /// metadata store). Returns aggregated failures so the caller can
    /// surface a partial-success message rather than silently dropping
    /// errors. Shared between `resetIndex` (this account only) and
    /// `resetIndexAllAccounts` (which adds disk-level partition cleanup
    /// on top).
    @MainActor
    fileprivate func clearCurrentPartitionStores() async -> [(label: String, error: Swift.Error)] {
        let lh = self.localHashStore
        let dh = self.deferredHashStore
        let eh = self.observedStore
        let cd = self.confirmedDeletedStore
        let tk = self.tokenStore
        let er = self.editRetirementStore
        let ds = self.deletionSourceStore
        let mdStore = self.localAssetMetadataStore
        let ss = self.statusSnapshotStore

        // Aggregate failures so a single store's hiccup doesn't leave
        // the user with partial-but-silent state. The metadata store
        // is the input to the orphan matcher; clearing the index
        // without it would leave stale rows that could resurrect
        // ghost orphans.
        var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
            ("local hash cache", { try await lh.clear() }),
            ("deferred queue", { try await dh.clear() }),
            ("metadata store", { try await mdStore.clear() }),
        ]
        if let eh { ops.append(("observed store", { try await eh.clear() })) }
        if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
        if let tk { ops.append(("change-token store", { try await tk.clear() })) }
        if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
        if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
        if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
        return await Self.aggregateClears(ops)
    }

    /// Reset every transient `model` field that derives from the
    /// engine state we just cleared. Doesn't touch credentials,
    /// settings, or excluded entries — those survive a reset by design.
    /// Shared between `resetIndex` and `resetIndexAllAccounts`.
    @MainActor
    fileprivate func resetModelAfterIndexClear() {
        self.model.reconciliation = nil
        self.model.library = .empty
        self.model.lastScanBurstCount = 0
        self.model.inferredOrphanCount = 0
        self.model.lastScanWasTokenExpiryFullEnum = false
        self.model.restoredAfterCairnTrash = [:]
        self.model.syncProgress = nil
        self.model.hasCompletedInitialScan = false
        self.model.didAutoSyncThisSession = false
        self.model.deferredQueue = .empty
        self.model.journalTail = []
        self.model.runs = []
        self.model.runAssets = [:]
        self.model.lastCheckedAt = nil
        self.model.acknowledgedCandidateChecksums = []
    }

    /// Walk every per-(URL, userId) partition directory under
    /// `Application Support/servers/` and `Documents/servers/`, remove
    /// each one EXCEPT the current partition's. The current
    /// partition's SwiftData container is open against those files;
    /// deleting underneath it would crash. Caller is expected to have
    /// already cleared the current partition's stores via
    /// `clearCurrentPartitionStores()` so the in-memory state matches.
    nonisolated fileprivate static func removeOtherPartitionsOnDisk(except currentKey: ServerPartitionKey?) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let serversDir = appSupport.appending(path: "servers")
        let docsServersDir = documentsDirectory().appending(path: "servers")
        let currentName = currentKey?.directoryName

        // SwiftData containers and their `-shm` / `-wal` siblings live
        // in `Application Support/servers/`. Match by name prefix so
        // we catch all three files for each non-current partition.
        if let entries = try? fm.contentsOfDirectory(at: serversDir, includingPropertiesForKeys: nil) {
            for e in entries {
                let name = e.lastPathComponent
                if let cur = currentName,
                   name == "\(cur).store" || name == "\(cur).store-shm" || name == "\(cur).store-wal" {
                    continue
                }
                do { try fm.removeItem(at: e) } catch {
                    syncLog.error("[cairn.reset.all] couldn't remove \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Journal directories live in `Documents/servers/<dirName>/`.
        if let entries = try? fm.contentsOfDirectory(at: docsServersDir, includingPropertiesForKeys: nil) {
            for e in entries {
                let name = e.lastPathComponent
                if let cur = currentName, name == cur { continue }
                do { try fm.removeItem(at: e) } catch {
                    syncLog.error("[cairn.reset.all] couldn't remove journal dir \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    fileprivate func refreshExcludedChecksums() async {
        guard let exclusionStore else {
            await MainActor.run {
                self.model.excludedChecksums = []
                self.model.excludedEntries = []
            }
            return
        }
        let snapshot = (try? await exclusionStore.snapshot()) ?? [:]
        let keys = Set(snapshot.keys.map(\.base64))

        // Enrich each exclusion against the cached server-asset
        // lookup so the Excluded-assets screen can render real
        // filenames + thumbnails. When the cache hasn't been
        // populated yet (pre-first-sync), fall back to a
        // checksum-prefix placeholder so the user at least sees
        // *something* — without enrichment the previous code path
        // left `excludedEntries` permanently empty, which is what
        // produced the "Excluded list shows nothing despite engine
        // seeing 5" bug.
        let assetsByChecksum = await MainActor.run { self.serverAssetsByChecksum ?? [:] }
        let entries: [ExcludedScreenEntry] = snapshot.map { (checksum, metadata) in
            if let server = assetsByChecksum[checksum] {
                let name = server.originalFileName ?? "asset-\(server.id.prefix(8))"
                let ext = (name as NSString).pathExtension.lowercased()
                let isVideo = ["mov", "mp4", "m4v", "avi", "3gp"].contains(ext)
                let isLivePair = server.livePhotoVideoId != nil
                let kind: CairnFixtures.CandidateFixture.Kind =
                    isLivePair ? .livePair : (isVideo ? .video : .photo)
                return ExcludedScreenEntry(
                    filename: name,
                    bytes: 0,                       // server list endpoint omits size
                    kind: kind,
                    isLivePair: isLivePair,
                    metadata: metadata,
                    assetId: server.id
                )
            }
            // Fallback: no server match (cache miss, server pruned the
            // asset, etc). Show enough that the row is visible and
            // uniquely identifiable, plus actionable via unexclude.
            return ExcludedScreenEntry(
                filename: "asset-\(checksum.base64.prefix(12))",
                bytes: 0,
                kind: .photo,
                isLivePair: false,
                metadata: metadata,
                assetId: nil
            )
        }
        // Stable order: most-recently-excluded first. Surfaces the
        // user's most relevant action (the freshly-restored items
        // they may want to unexclude) at the top.
        let sorted = entries.sorted { $0.metadata.addedAt > $1.metadata.addedAt }
        await MainActor.run {
            self.model.excludedChecksums = keys
            self.model.excludedEntries = sorted
        }
    }

    fileprivate func refreshQuarantineCount() async {
        guard let confirmed = confirmedDeletedStore else {
            await MainActor.run { self.model.quarantineCount = 0 }
            return
        }
        let snapshot = (try? await confirmed.snapshot()) ?? [:]
        let days = await model.settings.quarantineDays
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let inQuarantine = snapshot.values.filter { $0 > cutoff }.count
        await MainActor.run { self.model.quarantineCount = inQuarantine }
    }

    /// Rebuild the held (quarantine) bucket of `model.reconciliation`
    /// from persisted state at bootstrap, so the Pending Review list and
    /// Status quarantine line render before the first sync of the
    /// session. `ConfirmedDeletedStore` is the source of truth for which
    /// checksums are still in-window; `quarantinedAssetStore` supplies
    /// the `ServerAsset` display payloads (the one piece not otherwise
    /// persisted). We intersect the two, so any item the snapshot lists
    /// but the authoritative store has since dropped (trashed, expired)
    /// is excluded — the rebuild self-corrects against the source of
    /// truth even if the cached payloads are stale.
    ///
    /// Only the held bucket is restored: held items are durable facts
    /// (confirmed deletions waiting out the clock), whereas the
    /// unconfirmed bucket is scan-derived and re-established by the next
    /// reconciliation. Leaves `model.reconciliation` untouched if it's
    /// already populated, if nothing is held, or if no payloads survive.
    fileprivate func restoreQuarantineReconciliationIfNeeded(computedAt: Date?) async {
        guard let confirmed = confirmedDeletedStore,
              let quarantineStore = quarantinedAssetStore else { return }
        // Don't clobber a live reconciliation (defensive — bootstrap
        // reaches here with it nil, but a racing sync could have set it).
        let alreadyPopulated = await MainActor.run { self.model.reconciliation != nil }
        if alreadyPopulated { return }

        let days = await model.settings.quarantineDays
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let confirmedSnapshot = (try? await confirmed.snapshot()) ?? [:]
        let inWindow = confirmedSnapshot.filter { $0.value > cutoff }
        guard !inWindow.isEmpty else { return }

        let payloads = (try? await quarantineStore.snapshot()) ?? [:]
        // Intersect: only items still in-window AND with a display
        // payload. Missing payloads (held before this feature shipped)
        // are simply omitted — the count may exceed the list, which is
        // the pre-existing behavior and self-heals on the next sync.
        let held = inWindow.keys.compactMap { payloads[$0] }
        guard !held.isEmpty else { return }

        let heldChecksums = Set(held.map(\.checksum))
        let confirmedDeletedAt = inWindow.filter { heldChecksums.contains($0.key) }
        let sourceIds = ((try? await deletionSourceStore?.snapshot()) ?? [:])
            .filter { heldChecksums.contains($0.key) }

        await MainActor.run {
            // Re-check under the actor: a sync that started during the
            // awaits above takes precedence over restored state.
            guard self.model.reconciliation == nil else { return }
            self.model.reconciliation = .init(
                // Held items only — `deleteCandidates` (ready-to-trash)
                // stays empty; that list is repopulated by the next sync
                // and its count is restored separately via the status
                // snapshot's `library.candidates`.
                deleteCandidates: [],
                // Held ⊆ pending review, and the unconfirmed remainder
                // isn't restored, so pending review == held here. Drives
                // the "N in quarantine" Status line and the list.
                pendingReviewCandidates: held,
                heldByQuarantineCandidates: held,
                confirmedDeletedAt: confirmedDeletedAt,
                quarantineDays: days,
                computedAt: computedAt ?? Date(),
                sourceLocalIdentifiersByChecksum: sourceIds
            )
            syncLog.notice("[cairn.boot] restored \(held.count, privacy: .public) held quarantine item(s) from persisted state")
        }
    }

    func checkServerHealth() async {
        guard let client = immichClient else { return }
        let start = Date()
        do {
            _ = try await client.ping()
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            model.degraded = .none
            model.connectionStatus = .healthy(latencyMs: latencyMs)
        } catch {
            let degraded = Self.degradedState(for: error)
            if let degraded {
                model.degraded = degraded
                model.connectionStatus = degraded == .authStale ? .authStale : .offline
            } else {
                model.connectionStatus = .offline
            }
        }
    }

    /// User-facing error copy for a Photos auth status that blocks
    /// sync. cairn now accepts `.limited` (PhotoKit transparently scopes
    /// fetches to the user's selection, and the reconciler applies a
    /// `requireExplicitDeletionEvent` guard so selection changes don't
    /// look like deletions). `.denied`, `.restricted`, and
    /// `.notDetermined` still block — this message is for those.
    nonisolated fileprivate static func photosAuthMessage(for status: PHAuthorizationStatus) -> String {
        return "cairn needs Photos access to find deleted photos. Open Settings \u{2192} cairn \u{2192} Photos and grant access (full or limited)."
    }

    nonisolated fileprivate static func isUsablePhotoAuth(_ status: PHAuthorizationStatus) -> Bool {
        return status == .authorized || status == .limited
    }

    /// UserDefaults key for the one-shot Limited-Photos heads-up
    /// toast. Set on first detection; reset by `signOut` so a user
    /// who re-onboards on a new device or after a wipe sees the
    /// notice once on their fresh setup. Distinct from the
    /// per-account / per-key state — this is a device-level UX hint.
    /// `nonisolated` because the helpers that read/write it are
    /// `nonisolated` (called from sync paths off the main actor) and
    /// a `let` constant string is trivially safe to read concurrently.
    nonisolated private static let limitedPhotosNoticeKey = "cairn.ui.limitedPhotosNoticeShown"

    nonisolated fileprivate static func hasShownLimitedPhotosNotice() -> Bool {
        UserDefaults.standard.bool(forKey: limitedPhotosNoticeKey)
    }

    nonisolated fileprivate static func markLimitedPhotosNoticeShown() {
        UserDefaults.standard.set(true, forKey: limitedPhotosNoticeKey)
    }

    /// UserDefaults key prefix for the per-partition imputation
    /// completion marker. The full key is
    /// `cairn.imputation.completedAt.<partition.directoryName>`.
    /// Stores an ISO-ish timestamp (just for forensics; presence/absence
    /// is the load-bearing signal). Distinct from `tokenStore` because:
    /// the token signals "PhotoKit scan reached a save checkpoint,"
    /// whereas the imputation marker signals "fast-initial-scan
    /// matching pass walked the full library successfully." A cancelled
    /// imputation followed by a successful full enum (which can happen
    /// when the user resumes a sync mid-run) would leave the token set
    /// but the imputation incomplete — under the prior gate
    /// (`isBootstrapScan` alone) that asset cache would never get
    /// another shot at server-side matching without a manual cache
    /// wipe. Tracking imputation completion separately fixes that.
    nonisolated private static let imputationCompletionKeyPrefix = "cairn.imputation.completedAt."

    nonisolated fileprivate static func imputationCompletionKey(for partition: ServerPartitionKey) -> String {
        return "\(imputationCompletionKeyPrefix)\(partition.directoryName)"
    }

    nonisolated fileprivate static func imputationCompletedAt(for partition: ServerPartitionKey) -> Date? {
        let raw = UserDefaults.standard.double(forKey: imputationCompletionKey(for: partition))
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    nonisolated fileprivate static func markImputationCompleted(for partition: ServerPartitionKey, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: imputationCompletionKey(for: partition))
    }

    nonisolated fileprivate static func clearImputationCompletion(for partition: ServerPartitionKey) {
        UserDefaults.standard.removeObject(forKey: imputationCompletionKey(for: partition))
    }

    nonisolated fileprivate static func resetLimitedPhotosNotice() {
        UserDefaults.standard.removeObject(forKey: limitedPhotosNoticeKey)
    }

    /// One-shot migration marker for the build-110 introduction of
    /// `keepScreenAwakeDuringSync`. The setting's factory default is
    /// `true` (calibrated for the first-sync case), and the
    /// `performLiveReconciliation` auto-flip-to-false fires only on
    /// the `hasCompletedInitialScan: false → true` transition.
    ///
    /// Users upgrading from a pre-110 build with a long-completed
    /// initial scan never hit that transition, so without an explicit
    /// migration they'd land on the new toggle defaulted-on
    /// indefinitely — burning battery on every incremental sync that
    /// follows. This flag lets bootstrap detect the upgrade case
    /// once, flip the toggle to off (matching what a same-state
    /// fresh install would land on after first-scan completion), and
    /// then never touch the setting again. Subsequent manual
    /// re-enables persist; the migration only runs on the very first
    /// bootstrap after the build-110 update on a previously-onboarded
    /// install.
    nonisolated private static let keepScreenAwakeUpgradeMigrationKey =
        "cairn.migration.keepScreenAwake.afterFirstScan"

    nonisolated fileprivate static func hasMigratedKeepScreenAwake() -> Bool {
        UserDefaults.standard.bool(forKey: keepScreenAwakeUpgradeMigrationKey)
    }

    nonisolated fileprivate static func markKeepScreenAwakeMigrated() {
        UserDefaults.standard.set(true, forKey: keepScreenAwakeUpgradeMigrationKey)
    }

    /// One-shot per-partition flag tracking the build-121 metadata
    /// backfill of `allResourceFilenames`. Without this migration,
    /// users who completed their initial imputation pass on builds
    /// 112-120 have metadata rows whose `allResourceFilenamesCSV` is
    /// the empty default (the field didn't exist yet). The
    /// alive-on-phone safety check then can't see the non-primary
    /// resource filenames it needs to suppress edited assets (the
    /// last divergence shape covered in 121). Triggering imputation
    /// re-run would also fix this but is heavy; this migration
    /// targets only the missing field, populating it via per-asset
    /// PHAssetResource enumeration on first sync after upgrade.
    nonisolated private static let resourceFilenamesMigrationKeyPrefix =
        "cairn.migration.resourceFilenames."

    nonisolated fileprivate static func resourceFilenamesMigrationKey(for partition: ServerPartitionKey) -> String {
        return "\(resourceFilenamesMigrationKeyPrefix)\(partition.directoryName)"
    }

    nonisolated fileprivate static func hasMigratedResourceFilenames(for partition: ServerPartitionKey) -> Bool {
        UserDefaults.standard.bool(forKey: resourceFilenamesMigrationKey(for: partition))
    }

    nonisolated fileprivate static func markResourceFilenamesMigrated(for partition: ServerPartitionKey) {
        UserDefaults.standard.set(true, forKey: resourceFilenamesMigrationKey(for: partition))
    }

    /// Persisted per-asset hash duration (milliseconds) from the most
    /// recent session that produced a reliable rate. Used by
    /// `InitialScanScreen` as a bootstrap ETA before the live rate
    /// warms up. Persisting across sessions means a relaunched scan
    /// shows a number immediately rather than "estimating…" for the
    /// first 30 assets / 5 seconds. The bootstrap value displays at
    /// the low-confidence (orange) tier until live data takes over,
    /// so a stale persisted rate (e.g., yesterday's wifi vs today's
    /// cell) is signalled as provisional.
    nonisolated private static let persistedSyncRateKey = "cairn.session.perAssetMs"

    // MARK: - App Store review mode

    /// Magic onboarding URL that activates fixture-only review mode.
    /// Documented in `docs/app-store-review-notes.md`. Uses the IETF-
    /// reserved `.invalid` TLD (RFC 6761) so it can never resolve in
    /// production DNS — a normal user typing a real URL has no path
    /// to land here. The reviewer types this URL + any non-empty
    /// API key during onboarding; verifyServer short-circuits to a
    /// fixture-populated app state without hitting any network.
    nonisolated static let reviewModeMagicURL = "https://review.cairn.invalid"

    /// UserDefaults key for the persisted "review mode active" flag.
    /// Set when verifyServer accepts the magic URL; cleared on sign-
    /// out. Bootstrap reads this flag and skips the real activation
    /// path when set, so the reviewer can backgrounded/re-foreground
    /// without losing state.
    nonisolated private static let reviewModeActiveKey = "cairn.review.modeActive"

    nonisolated fileprivate static func isReviewModeActive() -> Bool {
        UserDefaults.standard.bool(forKey: reviewModeActiveKey)
    }

    nonisolated fileprivate static func setReviewModeActive(_ active: Bool) {
        if active {
            UserDefaults.standard.set(true, forKey: reviewModeActiveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: reviewModeActiveKey)
        }
    }

    nonisolated fileprivate static func loadPersistedSyncRate() -> Double? {
        let value = UserDefaults.standard.double(forKey: persistedSyncRateKey)
        return value > 0 ? value : nil
    }

    nonisolated fileprivate static func savePersistedSyncRate(_ perAssetMs: Double) {
        UserDefaults.standard.set(perAssetMs, forKey: persistedSyncRateKey)
    }

    /// Stable, anonymous-ish identifier for an API key. SHA256 of the
    /// raw key bytes, hex-truncated to 16 chars (64 bits → ample
    /// collision resistance among the small number of keys a single
    /// user generates over a device's lifetime). Used as the map key
    /// in `MutableSecretStore.keyActivationMap()` so we can answer
    /// "have I seen this exact key before?" without storing the key
    /// itself in the map. Defense-in-depth — the Keychain is already
    /// encrypted, but a fingerprint-only map limits blast radius if
    /// the json blob is ever logged or exfiltrated.
    nonisolated fileprivate static func apiKeyFingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Read-modify-write the per-key activation map. If `fingerprint`
    /// already has an entry, returns it unchanged (preserves history
    /// when the user rotates back to a previously-used key). Otherwise
    /// inserts `seedAt` and persists. Returns the activation timestamp
    /// the caller should remember for filtering. Failures are logged
    /// and surface as `.distantPast` so a Keychain hiccup never hides
    /// the user's history.
    nonisolated fileprivate static func upsertKeyActivation(
        in store: any MutableSecretStore,
        fingerprint: String,
        seedAt: Date
    ) -> Date {
        var map = (try? store.keyActivationMap()) ?? [:]
        if let existing = map[fingerprint] {
            return existing
        }
        map[fingerprint] = seedAt
        do {
            try store.setKeyActivationMap(map)
        } catch {
            syncLog.error("[cairn.boot] failed to persist key activation map: \(String(describing: error), privacy: .public)")
            return .distantPast
        }
        return seedAt
    }

    /// What the server-side discovery pass actually did this sync.
    /// Returned from the parallel server-fetch task and rendered into
    /// the sync activity feed so the user can confirm the configured
    /// path without grepping OSLog.
    fileprivate enum DiscoveryOutcome: Sendable {
        /// The streaming/CDC path ran. `summary` carries mode (bootstrap
        /// vs. incremental), event counts, and duration.
        case incremental(SyncRunSummary)
        /// The paginated path ran. `fallbackReason` is `nil` when the
        /// feature flag was off (so nothing was even attempted) and a
        /// short prose string when the streaming attempt failed and
        /// fell back ("missing scope sync.stream", "stream HTTP 500").
        case paginated(fallbackReason: String?)
    }

    /// Build the activity-feed row for a discovery outcome. Streaming
    /// success gets a `.note` (success/neutral tone); a paginated
    /// fallback after a streaming attempt gets `.warning` (warn tone)
    /// so a missing-scope or transient failure surfaces visually. A
    /// flag-off paginated run gets `.note` since that's the
    /// configured-by-default behavior, not a regression.
    nonisolated fileprivate static func discoveryActivity(
        for outcome: DiscoveryOutcome
    ) -> CairnAppModel.SyncActivity {
        switch outcome {
        case .incremental(let summary):
            let events = summary.upserted + summary.deleted + summary.ignored
            let modeLabel = summary.mode == .bootstrap ? "streaming (bootstrap)" : "streaming"
            let detail = "Discovery: \(modeLabel) · \(events.formatted(.number)) events · \(summary.durationMs.formatted(.number))ms"
            return .init(kind: .note, detail: detail)
        case .paginated(.none):
            return .init(kind: .note, detail: "Discovery: paginated")
        case .paginated(.some(let reason)):
            return .init(kind: .warning, detail: "Discovery: paginated (fallback: \(reason))")
        }
    }

    nonisolated fileprivate static func degradedState(for error: Swift.Error) -> StatusScreen.Degraded? {
        if let e = error as? ImmichClientError {
            switch e {
            case .httpStatus(let code, _):
                if code == 401 || code == 403 { return .authStale }
                if code >= 500 { return .serverDown }
                return nil
            case .invalidURL:
                return nil
            case .unexpectedResponse:
                return .serverDown
            case .missingScope:
                // Missing-scope means the API key works for some
                // endpoints but not others (specifically the sync.*
                // endpoints). That's a soft degradation — the
                // paginated fallback in performLiveReconciliation
                // keeps things working — so don't escalate to authStale
                // here. A future revision could add a dedicated
                // .missingScope degraded state with a "regenerate your
                // API key" CTA.
                return nil
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .serverDown
        }
        return nil
    }

    /// Run a batch of async-throwing operations, collecting failures
    /// without short-circuiting. Used by destructive paths (sign-out,
    /// reset-index, etc.) where one failed store-clear shouldn't
    /// prevent the rest from being attempted, but the user still
    /// needs to know something went wrong rather than seeing "ok"
    /// after a half-completed reset.
    nonisolated fileprivate static func aggregateClears(
        _ ops: [(label: String, body: @Sendable () async throws -> Void)]
    ) async -> [(label: String, error: Swift.Error)] {
        var failures: [(label: String, error: Swift.Error)] = []
        for op in ops {
            do {
                try await op.body()
            } catch {
                failures.append((op.label, error))
            }
        }
        return failures
    }

    /// Format a failures list for `model.lastError`. Shows a friendly
    /// summary plus the labels of what didn't clear; the full error
    /// detail goes to the syncLog.
    nonisolated fileprivate static func summarizeClearFailures(
        action: String,
        _ failures: [(label: String, error: Swift.Error)]
    ) -> String {
        let labels = failures.map(\.label).joined(separator: ", ")
        if failures.count == 1 {
            return "\(action) didn't fully complete — \(labels) couldn't be cleared. Some data may persist on this device."
        }
        return "\(action) didn't fully complete — \(failures.count) items couldn't be cleared (\(labels)). Some data may persist on this device."
    }

    /// Map a `NetworkDiagnosis` to a user-facing error message. The
    /// `fallback` is the generic URLError-derived copy from
    /// `describeSyncError` — used when the diagnosis adds nothing
    /// novel (e.g. `.serverUnreachable` reuses the underlying
    /// transport error since that already names the specific
    /// failure mode: connection refused, DNS lookup failed, etc.).
    /// `.noConnection` and `.internetDown` ship explicit copy
    /// because they're the cases where the URLError text would
    /// mislead the user about what's actually broken.
    nonisolated fileprivate static func message(
        for diagnosis: NetworkDiagnosis,
        fallback: String
    ) -> String {
        switch diagnosis {
        case .noConnection:
            return "No network connection. Check Wi-Fi or cellular and try again."
        case .internetDown:
            return "Your device is connected, but the network can't reach the public internet right now. Check the Wi-Fi router or upstream connection."
        case .serverUnreachable:
            return fallback
        }
    }

    nonisolated fileprivate static func describeSyncError(_ error: Swift.Error) -> String {
        if let e = error as? ImmichClientError {
            switch e {
            case .httpStatus(let code, let body):
                if code == 401 { return "Immich rejected the API key (HTTP 401). Try re-verifying in Settings." }
                if code == 403 { return "API key is missing scopes. Need asset.read + asset.delete + tag.*." }
                if code >= 500 { return "Immich server error (HTTP \(code)). Try again in a minute." }
                return "Immich returned HTTP \(code): \(body.prefix(200))"
            case .unexpectedResponse(let msg):
                return "Unexpected Immich response: \(msg)"
            case .invalidURL:
                return "The Immich URL looks malformed. Fix it in Settings."
            case .missingScope(let scopes):
                return "API key is missing scopes: \(scopes.joined(separator: ", ")). Regenerate the key in Immich Settings."
            }
        }
        if let e = error as? PhotoKitPhotoEnumerator.Error {
            switch e {
            case .notAuthorized:
                return "cairn needs Full Photos access. Settings → cairn → Photos → All Photos."
            case .resourceReadFailed(_, let msg):
                return "Couldn't read a photo's bytes: \(msg). iCloud offline?"
            case .noHashableResource(let id):
                return "An asset had no readable bytes (\(id.prefix(8))…). Skipped."
            }
        }
        // Map the common URLError codes to plain-language messages.
        // Network-down is the single most likely failure mode here
        // (the Immich server lives on a NAS, home VPS, or Tailscale-
        // exposed home box — any of which can be offline transiently),
        // so the raw URLError(_nsError:...) the default `describing`
        // produces is the worst error message a user is likely to see.
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. cairn will retry when you're back online."
            case .timedOut:
                return "The Immich server took too long to respond. It may be busy or offline."
            case .cannotFindHost, .dnsLookupFailed:
                return "Can't find the Immich server. Check the URL in Settings, or whether your VPN/Tailscale is up."
            case .cannotConnectToHost:
                return "Can't reach the Immich server — connection refused. Is it running?"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "TLS handshake failed. Check the server's certificate."
            default:
                return "Network error: \(e.localizedDescription)"
            }
        }
        return String(describing: error)
    }

    /// Classify an error as "Immich-unreachable-likely-transient" so
    /// the model can dedup the modal alert (one per disconnected
    /// session) versus always-pop errors (auth, permissions, malformed
    /// input — these need user attention each time).
    ///
    /// HTTP-status errors from a reachable server (401/403/5xx) are
    /// NOT counted as network-like, since the server's responding —
    /// just unhappy. Pure transport failures and timeouts ARE.
    nonisolated fileprivate static func isNetworkLikeError(_ error: Swift.Error) -> Bool {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .cannotConnectToHost:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }
        return false
    }

    // MARK: - Action wiring

    private func rewireActions() {
        let secrets = self.secretStore

        let actions = CairnAppActions(
            requestSync: { [weak self] trigger in
                guard let self else { return }
                let resolvedTrigger: JournalEntry.SyncTrigger = trigger ?? .manualForeground
                // Single cleanup point for the keep-screen-awake hold,
                // fires no matter which path the closure exits through
                // (success, cancellation, error, or an early return
                // from one of the dependency guards). Idempotent — the
                // controller no-ops if it wasn't holding the flag.
                defer {
                    Task { @MainActor in
                        IdleTimerController.setEnabled(false)
                    }
                }
                // Reentrancy guard + generation stamp, atomic on the
                // MainActor. Only the foreground scheduler checked
                // `!isSyncing` before; the Shortcut intent, both BG-task
                // handlers, and the debug fire all called requestSync
                // directly. Two overlapping runs interleave at every
                // suspension point — double change-token consumption,
                // cross-reset narration, and whichever finishes first
                // flips isSyncing off so the survivor's progress
                // callbacks are swallowed (minutes of work, idle UI).
                // A paused sync has isSyncing=false (see cancelActiveSync),
                // so a legitimate resume isn't blocked here.
                let myGeneration: Int = await MainActor.run { () -> Int? in
                    if self.model.isSyncing { return nil }
                    self.model.isSyncing = true
                    self.model.syncGeneration &+= 1
                    return self.model.syncGeneration
                } ?? -1
                if myGeneration == -1 {
                    syncLog.notice("[cairn.sync] requestSync skipped: a sync is already in flight (trigger=\(resolvedTrigger.shortToken, privacy: .public))")
                    return
                }

                await MainActor.run {
                    self.model.lastSyncTrigger = resolvedTrigger
                    // Reset the burst count so the failure path can't report
                    // a *prior* pass's offline-detections count. It's set
                    // again only after this pass's scan completes; a failure
                    // before the scan (e.g. imputation's blocking server
                    // prefetch) now correctly shows zero, not a stale number.
                    self.model.lastScanBurstCount = 0
                    // Don't clear `lastError` at sync start. Doing so
                    // caused a "transient popup that auto-dismisses"
                    // bug: a prior session's error would alert on
                    // foreground entry, then PhotoKit's change-observer-
                    // triggered foreground sync (via
                    // `scheduleForegroundSync`'s 1.5s-delayed
                    // requestSync) would clear `lastError` and dismiss
                    // the alert before the user could read it. Now the
                    // alert persists until either the user dismisses
                    // it or a sync genuinely succeeds (see the
                    // `lastError = nil` next to `degraded = .none` in
                    // the success path below).
                    if let paused = self.model.pausedSyncElapsedSeconds {
                        self.model.syncStartedAt = Date().addingTimeInterval(-paused)
                        self.model.pausedSyncElapsedSeconds = nil
                    } else {
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = Date()
                    }
                    // Hold the iOS idle timer for the duration of the
                    // foreground sync when the user has opted in. Auto-
                    // Lock would otherwise pause the sync (cairn gets
                    // ~30s of background grace after lock, then
                    // suspends), so the default-on behavior trades a
                    // bit of battery for a continuous initial-scan run.
                    // The cleanup paths below all clear it; the
                    // scene-phase observer also force-clears on
                    // backgrounding as a belt-and-suspenders.
                    if self.model.settings.keepScreenAwakeDuringSync {
                        IdleTimerController.setEnabled(true)
                    }
                }

                guard let client = await self.immichClient else {
                    // Dependency-not-ready: the common case isn't "user
                    // needs to onboard" (the UI flow blocks Review & sync
                    // before onboarding completes) — it's a launch /
                    // foreground race where bootstrap hasn't finished
                    // wiring up `immichClient` before some auto-trigger
                    // (PhotoKit observer, BG slot, Shortcut) calls
                    // requestSync. Surfacing a user-facing alert here
                    // produced a "Not signed in" popup that transiently
                    // appeared and then auto-dismissed once the next
                    // sync ran with a wired client. Bail silently and
                    // log instead.
                    syncLog.notice("[cairn.sync] requestSync skipped: immichClient not yet available (trigger=\(resolvedTrigger.shortToken, privacy: .public))")
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        // Clear the clock the start block set above; leaking
                        // it leaves InitialScanScreen's ELAPSED ticking while
                        // idle (and wipes a paused scan's frozen elapsed).
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                    }
                    return
                }
                guard let observed = await self.observedStore,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else {
                    // Same rationale as the `immichClient` guard above:
                    // a missing per-server store at this point reflects
                    // a transient bootstrap / partition-activation race,
                    // not a real "user hasn't onboarded" state.
                    syncLog.notice("[cairn.sync] requestSync skipped: per-server stores not yet activated (trigger=\(resolvedTrigger.shortToken, privacy: .public))")
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                    }
                    return
                }

                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                let effectiveStatus: PHAuthorizationStatus
                if photoStatus == .notDetermined {
                    effectiveStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                } else {
                    effectiveStatus = photoStatus
                }
                if Self.isUsablePhotoAuth(effectiveStatus) {
                    // Photos was just (or is now) granted. The bootstrap-
                    // time observer registration silently skipped if auth
                    // wasn't granted yet, so register here to catch the
                    // post-grant case.
                    await MainActor.run { self.registerPhotoLibraryObserver() }
                }
                guard Self.isUsablePhotoAuth(effectiveStatus) else {
                    let message = AppDependencies.photosAuthMessage(for: effectiveStatus)
                    await MainActor.run {
                        self.model.lastError = message
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncStartedAt = nil
                    }
                    return
                }

                // Snapshot the prior sync narration. performLiveReconciliation
                // calls resetSyncNarration() at its start, wiping the
                // timeline + activity feed. If THIS run doesn't complete
                // (cancelled by backgrounding, or the server fetch dies
                // during an app suspension), we restore this snapshot in the
                // catch blocks below — so "last sync details" keeps showing
                // the last run that actually finished, instead of a partial,
                // suspension-inflated timeline. A run that completes keeps
                // its own full narration.
                let priorNarration = await MainActor.run {
                    (timeline: self.model.syncTimeline, activity: self.model.syncActivity)
                }

                do {
                    try await self.performLiveReconciliation(
                        client: client,
                        observed: observed,
                        exclusions: exclusions,
                        confirmed: confirmed
                    )
                    await MainActor.run {
                        // A successor sync can only have started if this
                        // one was cancelled (→ throws, handled below), so
                        // this guard is belt-and-suspenders — but it keeps
                        // the invariant "only the current generation
                        // mutates sync state" uniform across all unwinds.
                        guard self.model.syncGeneration == myGeneration else { return }
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                        self.model.degraded = .none
                        self.model.lastError = nil
                        self.lastSyncEndedAt = Date()
                        // Success-only stamp for the foreground catch-up
                        // sync's stale gate (cancel/error don't advance it).
                        self.model.lastSyncSucceededAt = Date()
                        // Reaching this point means we talked to Immich
                        // successfully — clear any disconnect banner
                        // and reset the alert-dedup flag so the next
                        // disconnect re-pops the modal.
                        self.model.recordSyncSuccess()
                    }
                    // Drain any failed-trash intents queued from
                    // earlier offline sessions. `force: false` honors
                    // the per-intent attempt cap; the manual Retry-now
                    // path overrides that. Runs after the reconciler
                    // has updated server state, so a successful retry
                    // here will already have its trashed assets
                    // reflected in the next sync.
                    await self.drainPendingTrashes(force: false)
                } catch is CancellationError {
                    await MainActor.run {
                        // Idempotent unwind. `CairnAppRoot.cancelActiveSync`
                        // optimistically flips UI state on the user's tap
                        // and nil's `syncStartedAt`; if it already did so,
                        // skip the model update here so we don't re-stomp
                        // pausedSyncElapsedSeconds or transition the phase
                        // a second time. System-initiated cancellations
                        // (BG slot expiry, etc.) hit this with
                        // syncStartedAt still set and run the full update.
                        // The generation check is the load-bearing part:
                        // if a successor sync already started (cancelActiveSync
                        // flipped isSyncing off, letting it in), its
                        // syncStartedAt is non-nil too — without the
                        // generation gate this late CancellationError would
                        // flip isSyncing off under the successor and swallow
                        // all its progress callbacks.
                        if self.model.syncGeneration == myGeneration,
                           self.model.syncStartedAt != nil {
                            let elapsed = self.model.syncStartedAt.map {
                                Date().timeIntervalSince($0)
                            } ?? 0
                            self.model.pausedSyncElapsedSeconds = max(0, elapsed)
                            self.model.syncStartedAt = nil
                            self.model.isSyncing = false
                            self.model.transitionSyncPhase(to: .idle)
                        }
                        // This run was interrupted — restore the prior
                        // (complete) narration rather than leaving its
                        // partial timeline as "last sync". Guard on
                        // generation so we don't stomp a successor's feed.
                        if self.model.syncGeneration == myGeneration {
                            self.model.syncTimeline = priorNarration.timeline
                            self.model.syncActivity = priorNarration.activity
                        }
                        self.lastSyncEndedAt = Date()
                    }
                } catch {
                    let degraded = Self.degradedState(for: error)
                    let baseDesc = Self.describeSyncError(error)
                    let isNetwork = Self.isNetworkLikeError(error)
                    // On a network-class failure, run the reachability
                    // probe to distinguish "no connection at all" from
                    // "internet is down" from "internet works, only
                    // Immich is unreachable." The diagnosis swaps in a
                    // more actionable message than the generic URLError
                    // copy. Adds ~200-500ms of latency on the error
                    // path only — happy-path syncs never run the probe.
                    let desc: String
                    if isNetwork {
                        let diagnosis = await self.reachabilityProbe.classify()
                        desc = Self.message(for: diagnosis, fallback: baseDesc)
                        syncLog.notice("[cairn.sync] requestSync failed (network) — diagnosis=\(String(describing: diagnosis), privacy: .public)")
                    } else {
                        desc = baseDesc
                        syncLog.notice("[cairn.sync] requestSync failed: \(desc)")
                    }
                    await MainActor.run {
                        // Don't stomp a successor sync's state (see the
                        // generation guards above).
                        guard self.model.syncGeneration == myGeneration else { return }
                        self.model.recordSyncError(desc, isNetworkLike: isNetwork)
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                        self.model.pausedSyncElapsedSeconds = nil
                        if let degraded { self.model.degraded = degraded }
                        // Failed run — restore the prior (complete)
                        // narration instead of leaving a partial timeline.
                        self.model.syncTimeline = priorNarration.timeline
                        self.model.syncActivity = priorNarration.activity
                        self.lastSyncEndedAt = Date()
                        // The local PhotoKit scan ran before the
                        // server-touching part failed; any new
                        // deletions detected this pass are already
                        // persisted to ConfirmedDeletedStore. Surface
                        // the count so the user sees their offline
                        // deletions are recorded, not lost.
                        let burst = self.model.lastScanBurstCount
                        if burst > 0 {
                            // Route through showStatusToast so it auto-
                            // dismisses like every other toast — a direct
                            // assignment left it pinned until the next sync.
                            self.showStatusToast(.offlineDetections(count: burst))
                        }
                    }
                }
            },
            confirmTrash: { [weak self] in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal,
                      let live = await self.model.reconciliation,
                      !live.deleteCandidates.isEmpty else { return }
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let assetsInPurview = live.deleteCandidates.count + live.pendingReviewCandidates.count
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    let result = try await orchestrator.run(
                        runId: runId,
                        candidates: live.deleteCandidates,
                        assetsInPurview: assetsInPurview,
                        dryRun: false
                    )
                    let trashedCount = result.trashedAssetIds.count
                    await MainActor.run {
                        // Prune ONLY the trashed candidates from the
                        // reconciliation — not the whole thing. Nil-ing it
                        // (the prior behavior) also dropped the still-valid
                        // held-by-quarantine / pending-review buckets, so
                        // the Status quarantine banner vanished until the
                        // next sync even though those items remained.
                        // Mirrors the prune in `handleTrashFailure`.
                        let trashedIds = Set(result.trashedAssetIds)
                        let trashedChecksums = Set(
                            live.deleteCandidates
                                .filter { trashedIds.contains($0.id) }
                                .map(\.checksum)
                        )
                        if let existing = self.model.reconciliation {
                            self.model.reconciliation = existing.removing(checksums: trashedChecksums)
                        }
                        // Reset acknowledged set: trashed candidates'
                        // checksums are no longer relevant. Pairs with
                        // CairnAppRoot.presentDryRunSheet's subset
                        // suppression — without this, the next sync's
                        // candidate set could still be incorrectly
                        // suppressed by stale acknowledgements.
                        self.model.acknowledgedCandidateChecksums = []
                        if trashedCount > 0 {
                            let current = self.model.library
                            self.model.library = current.with(
                                server: max(0, current.server - trashedCount),
                                matched: max(0, current.matched - trashedCount),
                                candidates: max(0, current.candidates - trashedCount)
                            )
                        }
                        // Trash succeeded → talked to Immich → clear
                        // any disconnect banner and reset the alert
                        // dedup flag.
                        self.model.recordSyncSuccess()
                    }
                    await self.persistSnapshotFromModel()
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    await self.handleTrashFailure(
                        runId: runId,
                        candidates: live.deleteCandidates,
                        assetsInPurview: assetsInPurview,
                        error: error
                    )
                }
            },
            restore: { [weak self] assetIds, runId in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal else { return }
                let orch = RestoreOrchestrator(writer: client, journal: journal)
                let scope: Set<String>? = assetIds.isEmpty ? nil : Set(assetIds)
                do {
                    let summary = try await orch.restore(fromRunId: runId, assetIds: scope)

                    // Local-state cleanup that the orchestrator (which
                    // is platform-agnostic and lives in CairnCore)
                    // can't do: clear ConfirmedDeletedStore for the
                    // restored checksums and add them to ExclusionStore.
                    // Without this, the next sync re-flags these as
                    // deletion candidates because:
                    //   - the photo is still missing locally (restore
                    //     puts it back on Immich, not on the device)
                    //   - ConfirmedDeleted still holds the original
                    //     "deleted at T" stamp → past-quarantine →
                    //     `deleteCandidates` → re-trashed
                    // The user's "restore" intent semantically matches
                    // exclude — "preserve this asset on Immich." Mirrors
                    // the cleanup that `excludePending` does.
                    // `entriesForRun` falls back to the archive, so the
                    // cleanup still finds the planning targets even if the
                    // run has rotated out of the live journal.
                    let entries = (try? await journal.entriesForRun(runId)) ?? []
                    var planningTargets: [JournalEntry.TrashTarget] = []
                    for entry in entries {
                        if case .planningTrash(let targets) = entry.event {
                            planningTargets = targets
                        }
                    }
                    let restoredIdSet = Set(summary.restoredAssetIds)
                    var cks = Set(
                        planningTargets
                            .filter { restoredIdSet.contains($0.assetId) }
                            .map { Checksum(base64: $0.checksum) }
                    )
                    // Live Photo motion videos restore alongside their
                    // still (the orchestrator expands the pair, so
                    // `restoredAssetIds` includes the video ids) — but a
                    // TrashTarget records only the still's checksum, so the
                    // filter above misses the video's. Resolve every
                    // restored id to its server checksum via the last
                    // sync's asset map and fold those in. Without it, the
                    // video's stale ConfirmedDeleted stamp survives and the
                    // next sync re-trashes the video half of a Live Photo
                    // we just restored — a broken Live Photo, exactly what
                    // the pair-expansion exists to prevent. Best-effort:
                    // if the server map is stale/absent the still cleanup
                    // (above, journal-sourced) still happens.
                    let idToChecksum: [String: Checksum] = await MainActor.run {
                        var map: [String: Checksum] = [:]
                        for asset in (self.serverAssetsByChecksum ?? [:]).values {
                            map[asset.id] = asset.checksum
                        }
                        return map
                    }
                    for id in restoredIdSet {
                        if let ck = idToChecksum[id] { cks.insert(ck) }
                    }

                    if !cks.isEmpty {
                        try? await self.confirmedDeletedStore?.remove(cks)
                        try? await self.deletionSourceStore?.remove(cks)
                        if let exclusions = await self.exclusionStore {
                            let now = Date()
                            let exclusionEntries: [Checksum: ExclusionMetadata] = Dictionary(
                                uniqueKeysWithValues: cks.map {
                                    ($0, ExclusionMetadata(addedAt: now, fromRunId: runId, reason: "restored-from-run"))
                                }
                            )
                            try? await exclusions.insert(exclusionEntries)
                            // Forensic symmetry with `excludePending`:
                            // record the implicit exclusion in the
                            // journal so a later reader can see why
                            // these checksums became excluded. Includes
                            // the resolved video checksums.
                            try? await journal.append(.init(
                                timestamp: now,
                                runId: runId,
                                event: .assetsExcluded(
                                    checksums: cks.map(\.base64),
                                    fromRunId: runId
                                )
                            ))
                        }
                        await self.refreshExcludedChecksums()
                        // Prune the in-memory reconciliation so the
                        // restored checksums don't keep showing up as
                        // candidates until the next sync. Also nudge
                        // `model.library.server` and `.matched` upward
                        // by the count Immich actually restored — same
                        // pattern `approvePending` uses to drop server
                        // count on trash. Without this, the Status
                        // page's counters lag a sync behind every
                        // restore (visible in demos).
                        let restoredServerCount = summary.restoredAssetIds.count
                        await MainActor.run {
                            guard let existing = self.model.reconciliation else { return }
                            self.model.reconciliation = existing.removing(checksums: cks)
                            if restoredServerCount > 0 {
                                let current = self.model.library
                                self.model.library = current.with(
                                    server: current.server + restoredServerCount,
                                    matched: current.matched + restoredServerCount
                                )
                            }
                        }
                    }

                    // The restored run is now reverted on Immich; any
                    // pending-trash intent that targeted those same
                    // assets would re-trash them on next drain. Drop
                    // the intent first.
                    try? await self.pendingTrashStore?.remove(matchingRunId: runId)
                    await self.refreshPendingTrashCount()

                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    // Surface the error via model.lastError (the UI alert
                    // binding reads this). We deliberately don't re-throw:
                    // every caller invokes the action via `Task { try? await
                    // ... }`, so a re-throw silently vanishes anyway.
                    // Setting lastError is the single source of truth.
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                }
            },
            exclude: { [weak self] checksums, filenames, runId in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let journal = await self.journal else { return }
                let entries: [Checksum: ExclusionMetadata] = Dictionary(
                    uniqueKeysWithValues: checksums.map {
                        (Checksum(base64: $0), ExclusionMetadata(addedAt: Date(), fromRunId: runId, reason: nil))
                    }
                )
                do {
                    try await exclusions.insert(entries)
                    try await journal.append(.init(
                        runId: runId,
                        event: .assetsExcluded(checksums: checksums, fromRunId: runId)
                    ))
                    // Pending-trash retry queue: drop any queued intent
                    // that contains a checksum the user just excluded.
                    // Real-time pruning so the Status banner ticks down
                    // immediately rather than waiting for the next sync.
                    let cks = Set(entries.keys)
                    try? await self.pendingTrashStore?.removeIntents(containingAnyOf: cks)
                    await self.refreshPendingTrashCount()
                    await self.refreshExcludedChecksums()
                    await self.refreshJournalTail()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
                _ = filenames
            },
            unexclude: { [weak self] checksums in
                guard let self,
                      let exclusions = await self.exclusionStore else { return }
                let cks = Set(checksums.map { Checksum(base64: $0) })
                do {
                    try await exclusions.remove(cks)
                    await self.refreshExcludedChecksums()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
            },
            approvePending: { [weak self] checksums in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal,
                      let live = await self.model.reconciliation else { return }
                let wanted = Set(checksums)
                // Recycled-exclusion candidates flow through the same
                // approve path so the user can trash them inline; the
                // exclusion is cleared post-trash below. heldBy- is
                // already a subset of pendingReview, but recycled is
                // a disjoint bucket — include it explicitly.
                let candidatePool = live.pendingReviewCandidates
                    + live.heldByQuarantineCandidates
                    + live.recycledExclusionCandidates
                var seen = Set<String>()
                let candidates = candidatePool.filter { asset in
                    guard wanted.contains(asset.checksum.base64) else { return false }
                    return seen.insert(asset.id).inserted
                }
                guard !candidates.isEmpty else { return }
                // Capture the orphan→localId mapping for the candidates
                // we're about to trash. After a successful trash the
                // metadata rows are no longer useful (the asset's gone
                // both locally and on the server) and would keep
                // re-matching on subsequent syncs.
                let orphanMetadataLocalIds: Set<String> = Set(candidates.compactMap {
                    live.inferredOrphanLocalIdentifiers[$0.checksum]
                })
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    let result = try await orchestrator.run(
                        runId: runId,
                        candidates: candidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        dryRun: false
                    )
                    let trashedCount = result.trashedAssetIds.count
                    if !orphanMetadataLocalIds.isEmpty {
                        try? await self.localAssetMetadataStore.remove(orphanMetadataLocalIds)
                    }
                    let cks = Set(wanted.map { Checksum(base64: $0) })
                    try? await self.deletionSourceStore?.remove(cks)
                    // Idempotent exclusion cleanup. Approving a recycled-
                    // exclusion candidate (excluded earlier — typically
                    // via restore-via-cairn — and re-deleted on the
                    // phone) needs its exclusion entry removed so the
                    // checksum can flow through future syncs as a normal
                    // candidate. For non-excluded approved checksums
                    // this is a no-op. Mirrors `restore`'s symmetric
                    // exclusion *insert* in spirit: actions that contradict
                    // a prior exclusion clear it here.
                    if let exclusions = await self.exclusionStore {
                        let preExclusionSet = (try? await exclusions.snapshot()) ?? [:]
                        let cleared = cks.intersection(preExclusionSet.keys)
                        if !cleared.isEmpty {
                            try? await exclusions.remove(cleared)
                            await self.refreshExcludedChecksums()
                            // Forensic trail so the journal records why
                            // the exclusions were cleared. Reuses the
                            // approve run's runId for grouping.
                            try? await journal.append(.init(
                                timestamp: Date(),
                                runId: runId,
                                event: .assetsExcluded(
                                    checksums: cleared.map(\.base64),
                                    fromRunId: runId
                                )
                            ))
                        }
                    }
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let pruned = existing.removing(checksums: cks)
                        self.model.reconciliation = pruned
                        self.model.inferredOrphanCount = pruned.inferredOrphanLocalIdentifiers.count
                        if trashedCount > 0 {
                            let current = self.model.library
                            self.model.library = current.with(
                                server: max(0, current.server - trashedCount),
                                matched: max(0, current.matched - trashedCount)
                            )
                        }
                    }
                    await self.persistSnapshotFromModel()
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    await self.handleTrashFailure(
                        runId: runId,
                        candidates: candidates,
                        assetsInPurview: live.deleteCandidates.count + live.pendingReviewCandidates.count,
                        error: error
                    )
                }
            },
            excludePending: { [weak self] checksums in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else { return }
                let now = Date()
                var entries: [Checksum: ExclusionMetadata] = [:]
                let cks = Set(checksums.map { Checksum(base64: $0) })
                for checksum in cks {
                    entries[checksum] = ExclusionMetadata(addedAt: now, fromRunId: nil, reason: "pending-review")
                }
                do {
                    try await exclusions.insert(entries)
                    try await confirmed.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    // Audit symmetry with the regular `exclude` path —
                    // the pending-review bulk-exclude was previously
                    // silent in the journal, so excluded-via-review
                    // items had no forensic trail. Use a synthetic
                    // runId so the row groups with whatever previous
                    // run flagged the items, but `fromRunId: nil`
                    // matches the actual semantics (this isn't tied
                    // to a specific run; the user picked them off
                    // pending review).
                    if let journal = await self.journal {
                        let pendingExcludeRunId = "pending-review-\(ISO8601DateFormatter().string(from: now))"
                        try? await journal.append(.init(
                            timestamp: now,
                            runId: pendingExcludeRunId,
                            event: .assetsExcluded(checksums: checksums, fromRunId: nil)
                        ))
                    }
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let pruned = existing.removing(checksums: cks)
                        self.model.reconciliation = pruned
                        self.model.inferredOrphanCount = pruned.inferredOrphanLocalIdentifiers.count
                    }
                    // Pending-trash retry queue: drop any queued
                    // intent that contains one of the just-excluded
                    // checksums. Real-time pruning so the Status
                    // banner reflects the user's intent immediately.
                    try? await self.pendingTrashStore?.removeIntents(containingAnyOf: cks)
                    await self.refreshPendingTrashCount()
                    await self.persistSnapshotFromModel()
                    await self.refreshJournalTail()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
            },
            dismissPending: { [weak self] checksums in
                guard let self,
                      let confirmed = await self.confirmedDeletedStore,
                      let observed = await self.observedStore else { return }
                let cks = Set(checksums.map { Checksum(base64: $0) })
                // Resolve source localIdentifiers BEFORE we mutate
                // anything — both maps live on the in-memory
                // reconciliation snapshot, which we'll prune below.
                // Need them to wipe `LocalAssetMetadataStore` rows so
                // the orphan reconciler can't re-surface these assets
                // on the next sync via filename + creationDate match.
                let sourceLocalIds: Set<String> = await MainActor.run {
                    guard let existing = self.model.reconciliation else { return [] }
                    var ids: Set<String> = []
                    for c in cks {
                        if let id = existing.sourceLocalIdentifiersByChecksum[c] {
                            ids.insert(id)
                        }
                        if let id = existing.inferredOrphanLocalIdentifiers[c] {
                            ids.insert(id)
                        }
                    }
                    return ids
                }
                let metadataStore = await MainActor.run { self.localAssetMetadataStore }
                do {
                    try await confirmed.remove(cks)
                    try await observed.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    // Without this, the orphan reconciler at
                    // `OrphanReconciler.match` finds the asset on the
                    // next sync — `observed` no longer contains the
                    // checksum (we just removed), but the metadata row
                    // still satisfies the filename + creationDate +
                    // absent-localId filters → it reappears as an
                    // "unconfirmed" entry in PendingReview, contradicting
                    // dismiss's "removes from the pending list" copy.
                    if !sourceLocalIds.isEmpty {
                        try? await metadataStore.remove(sourceLocalIds)
                    }
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let pruned = existing.removing(checksums: cks)
                        self.model.reconciliation = pruned
                        self.model.inferredOrphanCount = pruned.inferredOrphanLocalIdentifiers.count
                    }
                    await self.refreshQuarantineCount()
                    await self.persistSnapshotFromModel()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
            },
            loadDeferredEntries: { [weak self] in
                guard let self else { return [] }
                let store = await MainActor.run { self.deferredHashStore }
                return (try? await store.snapshot()) ?? []
            },
            exportData: { [weak self] scope in
                guard let self else { throw CancellationError() }
                let (partitionKey, observed, exclusions, journal, settings) = await MainActor.run {
                    (self.currentPartitionKey, self.observedStore, self.exclusionStore, self.journal, self.model.settings)
                }

                var serverPayloads: [CairnExportPayload.ServerPayload] = []

                switch scope {
                case .currentServer:
                    guard let partitionKey, let observed, let exclusions, let journal else {
                        throw CancellationError()
                    }
                    let payload = try await Self.buildServerPayload(
                        key: partitionKey, observed: observed, exclusions: exclusions, journal: journal
                    )
                    serverPayloads.append(payload)

                case .allServers:
                    if let partitionKey, let observed, let exclusions, let journal {
                        let payload = try await Self.buildServerPayload(
                            key: partitionKey, observed: observed, exclusions: exclusions, journal: journal
                        )
                        serverPayloads.append(payload)
                    }

                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let serversDir = appSupport.appending(path: "servers")
                    if let entries = try? FileManager.default.contentsOfDirectory(
                        at: serversDir, includingPropertiesForKeys: nil
                    ) {
                        let currentDirName = partitionKey?.directoryName
                        for entry in entries {
                            let dirName = entry.deletingPathExtension().lastPathComponent
                            guard dirName != currentDirName else { continue }
                            guard entry.pathExtension == "store" else { continue }

                            guard let container = try? CairnSwiftDataContainer.makePerServer(url: entry) else { continue }
                            let otherObserved = SwiftDataObservedStore(container: container)
                            let otherExclusions = SwiftDataExclusionStore(container: container)

                            let normalizedURL = dirName.replacingOccurrences(of: "_", with: "://", range: dirName.range(of: "_"))
                            let otherKey = ServerPartitionKey(from: URL(string: normalizedURL) ?? URL(string: "https://\(dirName)")!)

                            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                .appending(path: "servers").appending(path: dirName)
                            let journalURL = docs.appending(path: "deletion-journal.jsonl")
                            let otherJournal = DeletionJournal(path: journalURL)

                            let payload = try await Self.buildServerPayload(
                                key: otherKey, observed: otherObserved, exclusions: otherExclusions, journal: otherJournal
                            )
                            serverPayloads.append(payload)
                        }
                    }
                }

                let (deviceName, deviceVendorId) = await MainActor.run {
                    (UIDevice.current.name, UIDevice.current.identifierForVendor?.uuidString)
                }

                // Snapshot the local hash cache into export rows. This
                // is the expensive cache (hours to compute on large
                // iCloud-Optimized libraries), so backing it up means
                // a future Reset / Clear / device migration doesn't
                // throw the work away.
                let hashStore = await MainActor.run { self.localHashStore }
                let hashRows = (try? await hashStore.exportableRows()) ?? []
                let payloadHashRows: [CairnExportPayload.HashCacheRow] = hashRows.map { row in
                    CairnExportPayload.HashCacheRow(
                        localId: row.localId,
                        checksumBase64: row.checksum.base64,
                        modificationDate: row.modificationDate,
                        imputed: row.imputed
                    )
                }

                let export = CairnExportPayload(
                    exportedFrom: deviceName,
                    servers: serverPayloads,
                    settings: settings,
                    deviceVendorId: deviceVendorId,
                    localHashCache: payloadHashRows.isEmpty ? nil : payloadHashRows
                )

                let data = try CairnExportPayload.encode(export)
                let dateStr = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let fileName = "cairn-export-\(dateStr).json"
                let tempURL = FileManager.default.temporaryDirectory.appending(path: fileName)
                try data.write(to: tempURL, options: .atomic)
                return tempURL
            },
            importData: { [weak self] fileURL, applySettings in
                guard let self else { throw CancellationError() }
                let accessed = fileURL.startAccessingSecurityScopedResource()
                defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

                let data = try Data(contentsOf: fileURL)
                let payload = try CairnExportPayload.decode(from: data)

                let (partitionKey, observed, exclusions, journal, settingsStore) = await MainActor.run {
                    (self.currentPartitionKey, self.observedStore, self.exclusionStore, self.journal, self.settingsStore)
                }

                var totalObservedAdded = 0
                var totalExclusionsAdded = 0
                var totalJournalLines = 0
                var processedServers = 0

                for serverPayload in payload.servers {
                    guard let partitionKey,
                          serverPayload.partitionKey == partitionKey.directoryName,
                          let observed, let exclusions, let journal else {
                        continue
                    }
                    processedServers += 1

                    let newChecksums = Set(serverPayload.observed.map { Checksum(base64: $0) })
                    let existing = try await observed.snapshot()
                    let actuallyNew = newChecksums.subtracting(existing)
                    if !actuallyNew.isEmpty {
                        try await observed.union(actuallyNew)
                    }
                    totalObservedAdded += actuallyNew.count

                    let existingExclusions = try await exclusions.snapshot()
                    var newExclusions: [Checksum: ExclusionMetadata] = [:]
                    for record in serverPayload.exclusions {
                        let ck = Checksum(base64: record.checksum)
                        if existingExclusions[ck] == nil {
                            newExclusions[ck] = ExclusionMetadata(
                                addedAt: record.addedAt,
                                fromRunId: record.fromRunId,
                                reason: record.reason
                            )
                        }
                    }
                    if !newExclusions.isEmpty {
                        try await exclusions.insert(newExclusions)
                        totalExclusionsAdded += newExclusions.count
                    }

                    if !serverPayload.journal.isEmpty {
                        try await journal.appendRawLines(serverPayload.journal)
                        totalJournalLines += serverPayload.journal.count
                    }
                }

                var didApplySettings = false
                if applySettings, let importedSettings = payload.settings {
                    try await settingsStore.save(importedSettings)
                    await MainActor.run { self.model.settings = importedSettings }
                    didApplySettings = true
                }

                // Hash cache restore — only when the payload's IDFV
                // matches this device's. PHAsset.localIdentifier and
                // IDFV rotate on the same triggers (device restore
                // from backup, full vendor-app uninstall), so a
                // matching IDFV is the strongest signal we have that
                // every cached localId still points at the same
                // PhotoKit asset. Mismatch or missing IDFV → skip
                // and surface the reason in the result so the UI can
                // explain it to the user.
                var hashCacheImported = 0
                var hashCacheSkipped: CairnImportResult.HashCacheSkipReason? = nil
                if let payloadRows = payload.localHashCache, !payloadRows.isEmpty {
                    let currentIDFV = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString }
                    if let payloadIDFV = payload.deviceVendorId,
                       let currentIDFV,
                       payloadIDFV == currentIDFV {
                        let hashStore = await MainActor.run { self.localHashStore }
                        let restoreRows: [(localId: String, checksum: Checksum, modificationDate: Date?, imputed: Bool)] =
                            payloadRows.map { row in
                                (
                                    localId: row.localId,
                                    checksum: Checksum(base64: row.checksumBase64),
                                    modificationDate: row.modificationDate,
                                    imputed: row.imputed
                                )
                            }
                        try await hashStore.restoreFromExport(restoreRows)
                        hashCacheImported = payloadRows.count
                    } else if payload.deviceVendorId == nil {
                        hashCacheSkipped = .missingIDFV
                    } else {
                        hashCacheSkipped = .deviceMismatch
                    }
                }

                await self.refreshExcludedChecksums()
                await self.refreshRunsList()
                await self.refreshJournalTail()

                return CairnImportResult(
                    observedAdded: totalObservedAdded,
                    exclusionsAdded: totalExclusionsAdded,
                    journalLinesAppended: totalJournalLines,
                    settingsApplied: didApplySettings,
                    serverCount: processedServers,
                    hashCacheImported: hashCacheImported,
                    hashCacheSkippedReason: hashCacheSkipped
                )
            },
            bulkExcludeRecentOffload: { [weak self] in
                guard let self,
                      let exclusions = await self.exclusionStore,
                      let confirmed = await self.confirmedDeletedStore else { return }
                let cutoff = Date().addingTimeInterval(-Self.massOffloadRecentWindow)
                do {
                    let snapshot = try await confirmed.snapshot()
                    let recent = snapshot.filter { $0.value >= cutoff }.keys
                    let cks = Set(recent)
                    guard !cks.isEmpty else { return }
                    let now = Date()
                    let entries: [Checksum: ExclusionMetadata] = Dictionary(
                        uniqueKeysWithValues: cks.map { ($0, ExclusionMetadata(addedAt: now, fromRunId: nil, reason: "mass-offload")) }
                    )
                    try await exclusions.insert(entries)
                    try await confirmed.remove(cks)
                    try? await self.deletionSourceStore?.remove(cks)
                    await MainActor.run {
                        guard let existing = self.model.reconciliation else { return }
                        let pruned = existing.removing(checksums: cks)
                        self.model.reconciliation = pruned
                        self.model.inferredOrphanCount = pruned.inferredOrphanLocalIdentifiers.count
                        self.model.lastScanBurstCount = 0
                        self.model.lastScanWasTokenExpiryFullEnum = false
                        self.model.restoredAfterCairnTrash = [:]
                    }
                    await self.persistSnapshotFromModel()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
            },
            verifyServer: { [weak self] urlString, key in
                // App Store review mode. The reviewer types this URL +
                // any non-empty API key during onboarding (documented in
                // `docs/app-store-review-notes.md`). Skip the real
                // network probe, persist the flag, and seed fixtures
                // into the model. The .invalid TLD never resolves in
                // production DNS, so a normal user typing a real URL
                // can never accidentally land here.
                //
                // Match via parseServerURL so the same bare-hostname
                // forgiveness applied to real URLs ("immich.local"
                // → "https://immich.local") works for the magic URL
                // too. Reviewers shouldn't have to remember the
                // scheme.
                let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedReviewURL: String? = ImmichClient.parseServerURL(trimmed)?.absoluteString
                if (trimmed == AppDependencies.reviewModeMagicURL || normalizedReviewURL == AppDependencies.reviewModeMagicURL) && !key.isEmpty {
                    AppDependencies.setReviewModeActive(true)
                    if let self {
                        await MainActor.run {
                            AppDependencies.seedReviewMode(into: self.model)
                        }
                    }
                    return SetupScreen.ServerVerifyResult(
                        success: true,
                        assetCount: CairnFixtures.medium.server,
                        errorMessage: nil
                    )
                }

                guard let url = ImmichClient.parseServerURL(urlString) else {
                    return SetupScreen.ServerVerifyResult(
                        success: false,
                        assetCount: nil,
                        errorMessage: "That doesn't look like a valid URL. Try the full hostname, like immich.example.com."
                    )
                }
                let probe = ImmichClient(baseURL: url, apiKey: key, session: ImmichClient.makeAppURLSession(timeoutSeconds: 10))
                do {
                    let assets = try await probe.listAllAssets()
                    // Fetch the Immich user identity so we can partition
                    // per-server state by (URL, userId). Best-effort: an
                    // older Immich version that lacks /users/me, or a
                    // transient API hiccup, leaves us in URL-only-
                    // partition mode (graceful degradation — bootstrap
                    // will retry on next successful sync).
                    let identity: ImmichClient.UserIdentity? = try? await probe.usersMe()
                    if let self {
                        try? secrets.setServerURL(url)
                        try? secrets.setAPIKey(key)
                        if let identity {
                            try? secrets.setUserIdentity(id: identity.id, email: identity.email)
                        }
                        // Record the verified URL in the recent-servers
                        // list. Only on success, so typos and broken
                        // hostnames don't pollute autocomplete. URL
                        // alone — see `RecentServerEntry`'s doc on why
                        // identity isn't stored here.
                        try? secrets.recordRecentServer(.init(
                            url: url.absoluteString,
                            lastUsedAt: Date()
                        ))
                        let priorPartitionKey = await MainActor.run { self.currentPartitionKey }
                        try? await MainActor.run {
                            try self.activateServer(url: url, apiKey: key, userId: identity?.id)
                        }
                        let newPartitionKey = await MainActor.run { self.currentPartitionKey }
                        let partitionChanged = priorPartitionKey != newPartitionKey

                        // Per-key activation timestamp. New keys (never
                        // seen before) seed `now` so their runs/journal-
                        // tail UI starts fresh. Returning to a previously-
                        // used key preserves that key's prior activation
                        // → its history is restored. Same for partition
                        // changes (the key is logically new for the new
                        // user too) — handled by the same upsert call
                        // because fingerprint is per-key, not per-user.
                        let fingerprint = AppDependencies.apiKeyFingerprint(key)
                        let activatedAt = AppDependencies.upsertKeyActivation(
                            in: secrets,
                            fingerprint: fingerprint,
                            seedAt: Date()
                        )
                        await MainActor.run { self.currentKeyActivatedAt = activatedAt }

                        let serverCount = assets.filter { !$0.isTrashed }.count
                        await MainActor.run {
                            self.model.serverHost = url.host() ?? url.absoluteString
                            self.model.serverURL = url
                            self.model.apiKey = key
                            self.model.apiKeyMasked = AppDependencies.mask(key)
                            self.model.library = self.model.library.with(server: serverCount)

                            // When the user verifies into a *different*
                            // partition (typically: same URL, different
                            // user account on a re-onboard or replay-
                            // onboarding flow), the model still holds the
                            // prior partition's runs / journal / indexed
                            // / reconciliation / etc. Clear the transient
                            // bits that don't have a refresh helper so
                            // the post-onboarding UI doesn't render
                            // Account A's data while standing on Account
                            // B's stores. Refresh helpers below repopulate
                            // the rest from the newly-activated partition.
                            if partitionChanged {
                                self.model.reconciliation = nil
                                self.model.lastScanBurstCount = 0
                                self.model.inferredOrphanCount = 0
                                self.model.lastScanWasTokenExpiryFullEnum = false
                                self.model.restoredAfterCairnTrash = [:]
                                self.model.lastCheckedAt = nil
                                self.model.lastError = nil
                                self.serverChecksumSet = nil
                            }
                        }

                        if let tokenStore = await self.tokenStore {
                            let tokenExists = (try? await tokenStore.load()) != nil
                            await MainActor.run { self.model.hasCompletedInitialScan = tokenExists }
                        }
                        await self.refreshExcludedChecksums()
                        if partitionChanged {
                            await self.refreshQuarantineCount()
                            await self.refreshJournalTail()
                            await self.refreshRunsList()
                            await self.refreshLibrarySizeStats()
                        }

                        await MainActor.run {
                            self.rewireActions()
                            self.registerPhotoLibraryObserver()
                        }
                    }
                    return SetupScreen.ServerVerifyResult(success: true, assetCount: assets.count, errorMessage: nil)
                } catch {
                    return SetupScreen.ServerVerifyResult(success: false, assetCount: nil, errorMessage: String(describing: error))
                }
            },
            retryConnection: { [weak self] in
                // Re-ping the configured server and refresh
                // connectionStatus + degraded. Wired to the "Retry"
                // button on the server-unreachable banner so a
                // transient blip can be cleared without running a
                // full sync.
                await self?.checkServerHealth()
            },
            requestPhotosAccess: {
                // PhotoKit's `requestAuthorization` only shows the
                // system prompt for `.notDetermined`. Once the user
                // has denied, it returns `.denied` immediately — the
                // user has to change the setting in iOS Settings.
                // Pre-check status and deep-link there so the
                // onboarding button does something useful.
                let prior = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if prior == .denied || prior == .restricted {
                    await MainActor.run {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    return .denied
                }
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                switch status {
                case .authorized: return .full
                case .limited:    return .limited
                default:          return .denied
                }
            },
            currentPhotoAuthStatus: {
                // No prompt — pure read. SetupScreen calls this on
                // step appear and on app foreground to reflect the
                // user's actual decision (or lack of one).
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                switch status {
                case .notDetermined: return nil
                case .authorized:    return .full
                case .limited:       return .limited
                default:             return .denied
                }
            },
            requestBackgroundRefresh: {
                await MainActor.run { UIApplication.shared.backgroundRefreshStatus == .available }
            },
            resetIndex: { [weak self] in
                guard let self else { return }
                let failures = await self.clearCurrentPartitionStores()
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.reset] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.resetModelAfterIndexClear()
                    if failures.isEmpty {
                        self.showStatusToast(.indexReset)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Reset index", failures)
                    }
                }
            },
            resetIndexAllAccounts: { [weak self] in
                guard let self else { return }
                // Step 1: clear the current partition's stores + global
                // caches via the same path `resetIndex` uses.
                let failures = await self.clearCurrentPartitionStores()
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.reset.all] partial failure: \(detail, privacy: .public)")
                }

                // Step 2: rm -rf every per-(URL, userId) partition dir
                // on disk EXCEPT the current one (its container is
                // open against those files; deleting underneath an
                // open SwiftData container is unsafe). The current
                // partition was already emptied via .clear() in
                // step 1.
                let currentKey = await MainActor.run { self.currentPartitionKey }
                Self.removeOtherPartitionsOnDisk(except: currentKey)

                // Step 3: reset the per-key activation map. After
                // nuking everything cairn knew, the only meaningful
                // entry is the current key starting now.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                let now = Date()
                try? secrets.setKeyActivationMap([fp: now])
                await MainActor.run { self.currentKeyActivatedAt = now }

                // Step 4: wipe the recent-servers + recent-email
                // autocomplete lists. Pointing at accounts that were just
                // removed is at best stale and at worst confusing — the
                // user explicitly asked to clear everything cairn knew.
                // (Plain sign-out preserves the lists; this is the
                // hard-nuclear path.)
                try? secrets.clearRecentServers()
                try? secrets.clearRecentSessionEmails()

                // Step 5: wipe the active partition's exclusions and
                // reset the one-shot Limited-Photos heads-up. Both
                // are user-explicit state that the "rebuild a corrupt
                // index" use case wants preserved (so they're NOT
                // touched by `resetIndex`/clearCurrentPartitionStores)
                // — but this is the all-accounts nuclear, whose copy
                // already promises to wipe everything cairn knew.
                // Mid-flight: clearCurrentPartitionStores already ran
                // in step 1, so it's safe to mutate ExclusionStore
                // here without races against engine input reads.
                if let exclusions = await self.exclusionStore {
                    let snapshot = (try? await exclusions.snapshot()) ?? [:]
                    if !snapshot.isEmpty {
                        try? await exclusions.remove(Set(snapshot.keys))
                    }
                }
                await self.refreshExcludedChecksums()
                Self.resetLimitedPhotosNotice()

                await MainActor.run {
                    self.resetModelAfterIndexClear()
                    if failures.isEmpty {
                        self.showStatusToast(.indexReset)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Reset all accounts", failures)
                    }
                }
            },
            clearJournal: { [weak self] in
                guard let self else { return }
                // Per-key: bump the current key's `activatedAt` to
                // now in the keychain map. Existing journal entries
                // are filtered out of this key's runs/journal-tail
                // UI on next refresh; the on-disk journal file and
                // other keys' activation timestamps are preserved.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                var map = (try? secrets.keyActivationMap()) ?? [:]
                let now = Date()
                map[fp] = now
                try? secrets.setKeyActivationMap(map)
                await MainActor.run { self.currentKeyActivatedAt = now }
                await self.refreshRunsList()
                await self.refreshJournalTail()
                await MainActor.run { self.showStatusToast(.journalCleared) }
            },
            clearJournalAllKeys: { [weak self] in
                guard let self else { return }
                let journal = await MainActor.run { self.journal }
                var deleteError: Swift.Error?
                if let journal {
                    // Wipe both the live journal and its rotated-out
                    // archive — "clear all" means the whole history.
                    let paths = [await journal.path, await journal.archivePath]
                    for path in paths {
                        do {
                            try FileManager.default.removeItem(at: path)
                        } catch {
                            // ENOENT is fine — file simply wasn't there
                            // (cairn never wrote a journal, or never
                            // rotated). Anything else is real and the
                            // user should see it.
                            let nsError = error as NSError
                            if !(nsError.domain == NSCocoaErrorDomain
                                 && nsError.code == NSFileNoSuchFileError) {
                                deleteError = error
                                syncLog.error("[cairn.journal.all] clear failed: \(Self.describeSyncError(error), privacy: .public)")
                            }
                        }
                    }
                }
                // Reset the activation map: the journal file is gone,
                // so there are no per-key views worth preserving.
                // Seed the current key with `now` so the next entries
                // fall under this key's view.
                let key = await MainActor.run { self.model.apiKey }
                let fp = AppDependencies.apiKeyFingerprint(key)
                let now = Date()
                try? secrets.setKeyActivationMap([fp: now])
                await MainActor.run { self.currentKeyActivatedAt = now }

                await MainActor.run {
                    if let deleteError {
                        self.model.lastError = "Couldn't delete the local journal file. (\(Self.describeSyncError(deleteError)))"
                    } else {
                        self.model.journalTail = []
                        self.model.runs = []
                        self.model.runAssets = [:]
                        self.showStatusToast(.journalCleared)
                    }
                }
            },
            clearExclusions: { [weak self] in
                guard let self,
                      let exclusions = await self.exclusionStore else { return }
                do {
                    let snapshot = try await exclusions.snapshot()
                    syncLog.notice("[cairn.exclusions] clear: pre=\(snapshot.count, privacy: .public)")
                    if !snapshot.isEmpty {
                        try await exclusions.remove(Set(snapshot.keys))
                    }
                    let postSnapshot = (try? await exclusions.snapshot()) ?? [:]
                    syncLog.notice("[cairn.exclusions] clear: post=\(postSnapshot.count, privacy: .public)")
                    await self.refreshExcludedChecksums()
                    // Forensic note. Reuses the journal-event shape for
                    // consistency, but with a synthetic runId so the
                    // entry isn't grouped with a real trash/restore run.
                    if let journal = await self.journal, !snapshot.isEmpty {
                        let now = Date()
                        let runId = "exclusions-cleared-\(ISO8601DateFormatter().string(from: now))"
                        try? await journal.append(.init(
                            timestamp: now,
                            runId: runId,
                            event: .assetsExcluded(
                                checksums: snapshot.keys.map(\.base64),
                                fromRunId: nil
                            )
                        ))
                        await self.refreshJournalTail()
                    }
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                    }
                }
            },
            signOut: { [weak self] in
                var keychainError: Swift.Error?
                do {
                    try secrets.clear()
                } catch {
                    keychainError = error
                    syncLog.error("[cairn.signout] keychain clear failed: \(Self.describeSyncError(error), privacy: .public)")
                }
                // Reset the one-shot Limited-Photos notice so a user
                // who signs back in on this device (or a different
                // user on a shared device) sees the heads-up again
                // on their first .limited sync.
                AppDependencies.resetLimitedPhotosNotice()
                // Clear App Store review-mode flag if it was set —
                // sign-out is the documented exit path back to real
                // onboarding.
                AppDependencies.setReviewModeActive(false)
                // Drop the imputation-completion marker for the
                // partition we're signing out of, so the next user
                // (or this user re-signing-in) starts with a clean
                // bootstrap signal even if they hit the same partition
                // key. Per-partition state cleanup; doesn't touch
                // other partitions' markers.
                if let partition = await MainActor.run(body: { self?.currentPartitionKey }) {
                    AppDependencies.clearImputationCompletion(for: partition)
                }
                await self?.thumbnailLoader?.clearCache()
                await MainActor.run {
                    guard let self else { return }
                    self.unregisterPhotoLibraryObserver()
                    self.immichClient = nil
                    self.thumbnailLoader = nil
                    self.currentPartitionKey = nil
                    self.serverContainer = nil
                    self.observedStore = nil
                    self.exclusionStore = nil
                    self.confirmedDeletedStore = nil
                    self.quarantinedAssetStore = nil
                    self.deletionSourceStore = nil
                    self.tokenStore = nil
                    self.editRetirementStore = nil
                    self.statusSnapshotStore = nil
                    self.pendingTrashStore = nil
                    self.thumbnailStore = nil
                    self.journal = nil
                    self.serverChecksumSet = nil
                    self.model.needsOnboarding = true
                    self.model.apiKey = ""
                    self.model.apiKeyMasked = ""
                    self.model.serverHost = ""
                    self.model.serverURL = nil
                    self.model.hasDismissedInitialScan = false
                    self.model.journalTail = []
                    self.model.runs = []
                    self.model.runAssets = [:]
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.inferredOrphanCount = 0
                    self.model.lastScanWasTokenExpiryFullEnum = false
                    self.model.restoredAfterCairnTrash = [:]
                    self.model.hasCompletedInitialScan = false
                    self.model.excludedChecksums = []
                    self.model.lastCheckedAt = nil
                    if let keychainError {
                        // Sign-out cleared in-memory state successfully,
                        // but the credential delete from Keychain failed.
                        // Surface so the user knows their key may still
                        // be on this device.
                        self.model.lastError = "Sign-out couldn't fully clear the saved credentials. (\(Self.describeSyncError(keychainError)))"
                    }
                }
            },
            rescanLibrary: { [weak self] in
                guard let self else { return }
                let (dh, tk) = await MainActor.run { (self.deferredHashStore, self.tokenStore) }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("deferred queue", { @Sendable in try await dh.clear() }),
                ]
                if let tk {
                    ops.append(("change-token store", { @Sendable in try await tk.clear() }))
                }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.rescan] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.model.hasCompletedInitialScan = false
                    self.model.reconciliation = nil
                    self.model.syncProgress = nil
                    self.model.deferredQueue = .empty
                    if failures.isEmpty {
                        self.showStatusToast(.rescanQueued)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Rescan setup", failures)
                    }
                }
            },
            clearHashCache: { [weak self] in
                guard let self else { return }
                // Targeted reset for fast-initial-scan testing: clear
                // the localId→SHA1 cache + change token + deferred
                // queue so the next sync re-enumerates from scratch
                // (no token → runFullEnumeration) and the imputation
                // pass has gaps to seed. Preserves ObservedStore,
                // ConfirmedDeletedStore, Exclusions, EditRetirement,
                // DeletionSource, metadata, and status snapshots —
                // so witness history, active quarantine, and user
                // intent survive intact.
                let (lh, dh, tk) = await MainActor.run {
                    (self.localHashStore, self.deferredHashStore, self.tokenStore)
                }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("local hash cache", { @Sendable in try await lh.clear() }),
                    ("deferred queue", { @Sendable in try await dh.clear() }),
                ]
                if let tk {
                    ops.append(("change-token store", { @Sendable in try await tk.clear() }))
                }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.clearhash] partial failure: \(detail, privacy: .public)")
                }
                // Reset the imputation-completion marker for the
                // active partition so the next sync re-runs fast-
                // initial-scan from scratch. The hash cache is empty
                // again — every server match is a fresh seed.
                if let partition = await MainActor.run(body: { self.currentPartitionKey }) {
                    Self.clearImputationCompletion(for: partition)
                }
                await MainActor.run {
                    self.model.hasCompletedInitialScan = false
                    self.model.reconciliation = nil
                    self.model.syncProgress = nil
                    self.model.deferredQueue = .empty
                    self.model.library = self.model.library.with(indexed: 0)
                    if failures.isEmpty {
                        self.showStatusToast(.rescanQueued)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Clear hash cache", failures)
                    }
                }
            },
            verifyImputedChecksums: { [weak self] in
                guard let self else { return }
                // Drop every imputed row from the local hash cache so
                // the next sync re-hashes them locally. Verified rows
                // are preserved by the modDate-skip path in the
                // existing hashing loop. Clearing the change token
                // forces a full enumeration so the dropped rows get
                // picked up — runIncremental wouldn't see them as
                // changes.
                let (lh, tk) = await MainActor.run {
                    (self.localHashStore, self.tokenStore)
                }
                let imputedIds: Set<String>
                do {
                    imputedIds = try await lh.imputedIdentifiers()
                } catch {
                    syncLog.error("[cairn.verify] couldn't list imputed rows: \(Self.describeSyncError(error), privacy: .public)")
                    await MainActor.run {
                        self.model.lastError = "Couldn't list imputed entries — try again. (\(Self.describeSyncError(error)))"
                    }
                    return
                }
                if imputedIds.isEmpty {
                    syncLog.notice("[cairn.verify] no imputed rows to verify")
                    await MainActor.run { self.showStatusToast(.nothingToVerify) }
                    return
                }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("imputed rows", { @Sendable in try await lh.removeAll(for: imputedIds) }),
                ]
                if let tk {
                    ops.append(("change-token store", { @Sendable in try await tk.clear() }))
                }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.verify] partial failure: \(detail, privacy: .public)")
                }
                // Reset imputation completion so the next sync
                // re-runs the matching pass on the now-empty imputed
                // set; otherwise the dropped rows would just fall to
                // local hashing without another shot at server-side
                // matching.
                if let partition = await MainActor.run(body: { self.currentPartitionKey }) {
                    Self.clearImputationCompletion(for: partition)
                }
                syncLog.notice("[cairn.verify] dropped \(imputedIds.count) imputed row(s) — next sync will re-hash")
                await MainActor.run {
                    self.model.hasCompletedInitialScan = false
                    self.model.reconciliation = nil
                    self.model.syncProgress = nil
                    if failures.isEmpty {
                        self.showStatusToast(.rescanQueued)
                    } else {
                        self.model.lastError = Self.summarizeClearFailures(action: "Re-hash imputed entries", failures)
                    }
                }
                await self.refreshLibrarySizeStats()
            },
            inspectAssetByFilename: { [weak self] filename in
                await self?.inspectAssetByFilenameImpl(filename: filename)
            },
            persistSettings: { [weak self] settings in
                guard let self else { return }
                do {
                    try await self.settingsStore.save(settings)
                } catch {
                    syncLog.error("[cairn.settings] save failed: \(Self.describeSyncError(error), privacy: .public)")
                    await MainActor.run {
                        self.model.lastError = "Couldn't save your settings — they'll revert on next launch. (\(Self.describeSyncError(error)))"
                    }
                }
                await self.refreshDeferredQueueSummary()
            },
            dismissInitialScan: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.model.hasDismissedInitialScan = true
                }
            },
            startOverInitialScan: { [weak self] in
                guard let self else { return }
                let (lh, dh, tk, eh, cd, er, ds, mdStore, ss, qa) = await MainActor.run {
                    (self.localHashStore, self.deferredHashStore, self.tokenStore, self.observedStore, self.confirmedDeletedStore, self.editRetirementStore, self.deletionSourceStore, self.localAssetMetadataStore, self.statusSnapshotStore, self.quarantinedAssetStore)
                }
                var ops: [(label: String, body: @Sendable () async throws -> Void)] = [
                    ("local hash cache", { try await lh.clear() }),
                    ("deferred queue", { try await dh.clear() }),
                    ("metadata store", { try await mdStore.clear() }),
                ]
                if let tk { ops.append(("change-token store", { try await tk.clear() })) }
                if let eh { ops.append(("observed store", { try await eh.clear() })) }
                if let cd { ops.append(("confirmed-deleted store", { try await cd.clear() })) }
                if let er { ops.append(("edit-retirement store", { try await er.clear() })) }
                if let ds { ops.append(("deletion-source store", { try await ds.clear() })) }
                if let ss { ops.append(("status snapshot store", { try await ss.clear() })) }
                if let qa { ops.append(("quarantined-asset store", { try await qa.clear() })) }
                let failures = await Self.aggregateClears(ops)
                if !failures.isEmpty {
                    let detail = failures.map { "\($0.label): \(Self.describeSyncError($0.error))" }.joined(separator: "; ")
                    syncLog.error("[cairn.startover] partial failure: \(detail, privacy: .public)")
                }
                await MainActor.run {
                    self.model.reconciliation = nil
                    self.model.library = .empty
                    self.model.lastScanBurstCount = 0
                    self.model.inferredOrphanCount = 0
                    self.model.lastScanWasTokenExpiryFullEnum = false
                    self.model.restoredAfterCairnTrash = [:]
                    self.model.syncProgress = nil
                    self.model.pausedSyncElapsedSeconds = nil
                    self.model.syncStartedAt = nil
                    self.model.hasCompletedInitialScan = false
                    self.model.lastCheckedAt = nil
                    if !failures.isEmpty {
                        self.model.lastError = Self.summarizeClearFailures(action: "Start-over reset", failures)
                    }
                }
                await self.refreshDeferredQueueSummary()
            },
            forceDrainDeferred: { [weak self] in
                guard let self else { return }
                let photoStatus = await MainActor.run { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                guard Self.isUsablePhotoAuth(photoStatus) else {
                    let message = AppDependencies.photosAuthMessage(for: photoStatus)
                    await MainActor.run {
                        self.model.lastError = message
                    }
                    return
                }
                await MainActor.run {
                    self.model.isSyncing = true
                    self.model.resetSyncNarration()
                    self.model.transitionSyncPhase(to: .hashing)
                    self.model.lastError = nil
                    self.model.syncProgress = nil
                    self.model.syncStartedAt = Date()
                    self.model.pausedSyncElapsedSeconds = nil
                }
                await self.refreshLibrarySizeStats()
                guard let reconciler = await MainActor.run(body: { self.persistentChangeReconciler }) else {
                    await MainActor.run {
                        self.model.lastError = "No server activated."
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncStartedAt = nil
                    }
                    return
                }
                do {
                    _ = try await reconciler.drainDeferred()
                    await MainActor.run {
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                    }
                    await self.refreshDeferredQueueSummary()
                } catch is CancellationError {
                    await MainActor.run {
                        // Same idempotency contract as `requestSync` —
                        // see comment there. The optimistic UI path in
                        // `CairnAppRoot.cancelActiveSync` may already
                        // have applied the stop state.
                        if self.model.syncStartedAt != nil {
                            let elapsed = self.model.syncStartedAt.map {
                                Date().timeIntervalSince($0)
                            } ?? 0
                            self.model.pausedSyncElapsedSeconds = max(0, elapsed)
                            self.model.syncStartedAt = nil
                            self.model.isSyncing = false
                            self.model.transitionSyncPhase(to: .idle)
                        }
                    }
                    await self.refreshDeferredQueueSummary()
                } catch {
                    await MainActor.run {
                        self.model.recordSyncError(Self.describeSyncError(error), isNetworkLike: Self.isNetworkLikeError(error))
                        self.model.isSyncing = false
                        self.model.transitionSyncPhase(to: .idle)
                        self.model.syncProgress = nil
                        self.model.syncStartedAt = nil
                    }
                    await self.refreshDeferredQueueSummary()
                }
            },
            replayOnboarding: { [weak self] in
                guard let self else { return }
                let url = try? self.secretStore.serverURL()
                let apiKey = try? self.secretStore.apiKey()
                await MainActor.run {
                    if let url {
                        self.model.serverHost = url.absoluteString
                    }
                    if let apiKey {
                        self.model.apiKey = apiKey
                    }
                    self.model.needsOnboarding = true
                }
            },
            recomputeScopeTags: { [weak self] in
                guard let self else { return }
                await self.recomputeScopeTagsImpl()
            },
            refreshJournalTail: { [weak self] in
                guard let self else { return }
                await self.refreshJournalTail()
            },
            loadArchivedHistory: { [weak self] in
                guard let self else { return [] }
                return await self.loadArchivedHistoryImpl()
            },
            recentServers: { [weak self] in
                guard let self else { return [] }
                let store = self.secretStore
                return await Task.detached(priority: .userInitiated) {
                    (try? store.recentServers()) ?? []
                }.value
            },
            clearRecentServers: { [weak self] in
                guard let self else { return }
                let store = self.secretStore
                await Task.detached(priority: .userInitiated) {
                    // Same user intent — "forget what I've typed into the
                    // connection fields" — clears both the URL and email
                    // autocomplete lists.
                    try? store.clearRecentServers()
                    try? store.clearRecentSessionEmails()
                }.value
            },
            recentSessionEmails: { [weak self] in
                guard let self else { return [] }
                let store = self.secretStore
                return await Task.detached(priority: .userInitiated) {
                    ((try? store.recentSessionEmails()) ?? []).map(\.email)
                }.value
            },
            retryPendingTrashes: { [weak self] in
                // `force: true` so the manual Retry-now path also
                // re-attempts intents that have hit `maxRetryAttempts`.
                // The auto-drain in `requestSync` passes `force: false`.
                await self?.drainPendingTrashes(force: true)
            },
            loadPendingTrashes: { [weak self] in
                guard let self else { return [] }
                return (try? await self.pendingTrashStore?.snapshot()) ?? []
            },
            discardPendingTrash: { [weak self] id in
                guard let self else { return }
                try? await self.pendingTrashStore?.remove(id)
                await self.refreshPendingTrashCount()
            },
            findMissedDeletions: { [weak self] minCreatedAt, maxCreatedAt, strictHistorical in
                guard let self,
                      let client = await self.immichClient,
                      let observed = await self.observedStore,
                      let exclusions = await self.exclusionStore else { return [] }
                let serverAssets = try await client.listAllAssets(includeTrashed: false, visibility: .timeline)
                let observedChecksums = try await observed.snapshot()
                let excludedChecksums = Set((try await exclusions.snapshot()).keys)
                // Snapshot the metadata cache + currently-alive PHAsset
                // ids. The intersection gives live local filenames
                // (suppression). The difference (cached IDs not alive)
                // gives historical filenames (positive evidence for
                // strict mode).
                let metadataSnapshot = (try? await self.localAssetMetadataStore.snapshot()) ?? []
                let liveIds = PhotoKitPersistentChangeReconciler.enumerateLiveLocalIdentifiers(
                    includeHiddenAssets: true,
                    sourceTypes: [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                )
                let liveFilenames: Set<String> = Set(
                    metadataSnapshot
                        .filter { liveIds.contains($0.localIdentifier) }
                        .compactMap { $0.originalFileName }
                )
                let strictFilenames: Set<String>? = {
                    guard strictHistorical else { return nil }
                    return Set(
                        metadataSnapshot
                            .filter { !liveIds.contains($0.localIdentifier) }
                            .compactMap { $0.originalFileName }
                    )
                }()
                return MissedDeletionFinder.find(
                    serverAssets: serverAssets,
                    observed: observedChecksums,
                    excluded: excludedChecksums,
                    liveLocalFilenames: liveFilenames,
                    minCreatedAt: minCreatedAt,
                    maxCreatedAt: maxCreatedAt,
                    confirmedDeletedFilenames: strictFilenames
                )
            },
            trashMissedDeletions: { [weak self] assets in
                guard let self,
                      let client = await self.immichClient,
                      let journal = await self.journal,
                      !assets.isEmpty else { return }
                let runId = "\(ISO8601DateFormatter().string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let orchestrator = TrashOrchestrator(writer: client, journal: journal)
                do {
                    _ = try await orchestrator.run(
                        runId: runId,
                        candidates: assets,
                        assetsInPurview: assets.count,
                        dryRun: false
                    )
                    await self.refreshRunsList()
                    await self.refreshJournalTail()
                } catch {
                    await self.handleTrashFailure(
                        runId: runId,
                        candidates: assets,
                        assetsInPurview: assets.count,
                        error: error
                    )
                    throw error
                }
            },
            simulateBackgroundRefresh: { [weak self] in
                guard let self else { return }
                // Same code path as BGAppRefreshTask's handler, minus
                // the BGTask object lifecycle (no setTaskCompleted/
                // expirationHandler). Use this when iOS scheduling
                // can't be trusted to fire in a useful timeframe (a
                // fresh install, the simulator, or an iOS version
                // where `_simulateLaunchForTaskWithIdentifier:` traps
                // on dispatch queue assertions from lldb).
                bgLog.notice("[cairn.bgtask] manual fire from Settings → Advanced")
                do {
                    try await self.model.actions.requestSync(.debugManualFire)
                    bgLog.notice("[cairn.bgtask] manual fire completed successfully")
                } catch {
                    bgLog.error("[cairn.bgtask] manual fire failed: \(String(describing: error), privacy: .public)")
                }
            },
            signInForSession: { [weak self] email, password in
                guard let self else { return .networkError(message: "app not ready") }
                guard let client = await self.immichClient else {
                    return .networkError(message: "Sign in to your Immich server first.")
                }
                do {
                    let resp = try await client.login(email: email, password: password)
                    try await MainActor.run {
                        // Persist the access token and rebuild the
                        // ImmichClient + coordinator so subsequent
                        // /sync/* calls authenticate via Bearer.
                        try self.secretStore.setSessionToken(resp.accessToken)
                        let updatedClient = client.withSessionToken(resp.accessToken)
                        self.immichClient = updatedClient
                        if let cache = self.serverAssetCacheStore,
                           let acks = self.syncAckStore {
                            self.serverAssetSyncCoordinator = ServerAssetSyncCoordinator(
                                client: updatedClient,
                                cache: cache,
                                ackStore: acks
                            )
                        }
                        self.model.hasSessionToken = true
                        // Clear the .sessionExpired banner if it was
                        // showing — fresh sign-in resolves the
                        // condition. Leaving the banner up after a
                        // successful re-sign-in would be misleading.
                        if self.model.degraded == .sessionExpired {
                            self.model.degraded = .none
                        }
                    }
                    syncLog.notice("[cairn.session] signed in as \(resp.userEmail, privacy: .public)")
                    // Remember the address for the sign-in field's
                    // autocomplete. Only on success — a failed attempt's
                    // typo'd address shouldn't pollute the list. Records
                    // the server-confirmed email (canonical casing), not
                    // the raw input. Survives sign-out; cleared by "Clear
                    // saved servers" / full reset.
                    try? self.secretStore.recordRecentSessionEmail(.init(email: resp.userEmail))
                    return .success
                } catch let err as ImmichClientError {
                    if case .httpStatus(let code, let body) = err {
                        if code == 401 {
                            return .invalidCredentials
                        }
                        return .serverError(code: code, message: String(body.prefix(200)))
                    }
                    return .networkError(message: Self.describeSyncError(err))
                } catch {
                    return .networkError(message: Self.describeSyncError(error))
                }
            },
            signOutSession: { [weak self] in
                guard let self else { return }
                let existingClient = await self.immichClient
                // Best-effort server-side logout — failures are fine,
                // the local-side cleanup happens regardless.
                if let existingClient {
                    try? await existingClient.logout()
                }
                await MainActor.run {
                    try? self.secretStore.setSessionToken(nil)
                    if let client = existingClient {
                        let updatedClient = client.withSessionToken(nil)
                        self.immichClient = updatedClient
                        if let cache = self.serverAssetCacheStore,
                           let acks = self.syncAckStore {
                            self.serverAssetSyncCoordinator = ServerAssetSyncCoordinator(
                                client: updatedClient,
                                cache: cache,
                                ackStore: acks
                            )
                        }
                    }
                    self.model.hasSessionToken = false
                    // If the user manually signed out from the banner,
                    // they've acted on the .sessionExpired notice —
                    // clear it. (If sign-out came from the Settings
                    // row while the banner wasn't up, this is a
                    // harmless no-op.)
                    if self.model.degraded == .sessionExpired {
                        self.model.degraded = .none
                    }
                }
                syncLog.notice("[cairn.session] signed out")
            },
            replaceAPIKey: { [weak self] newKey in
                guard let self else { return .networkError(message: "app not ready") }
                let trimmedKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty else { return .invalidKey }

                // Rotation only makes sense against the currently-
                // connected server + account.
                let modelURL = await MainActor.run { self.model.serverURL }
                guard let url = modelURL ?? (try? secrets.serverURL()) else {
                    return .networkError(message: "No server connected.")
                }
                let partitionUserId = await MainActor.run { self.currentPartitionKey?.userId }
                let currentUserId = partitionUserId ?? (try? secrets.userId())

                // Verify the new key against the same server.
                let probe = ImmichClient(baseURL: url, apiKey: trimmedKey, session: ImmichClient.makeAppURLSession(timeoutSeconds: 10))
                let assets: [ServerAsset]
                do {
                    assets = try await probe.listAllAssets()
                } catch let err as ImmichClientError {
                    if case .httpStatus(let code, _) = err, code == 401 || code == 403 {
                        return .invalidKey
                    }
                    return .networkError(message: Self.describeSyncError(err))
                } catch {
                    return .networkError(message: Self.describeSyncError(error))
                }

                // Identity guard: rotation must be POSITIVELY confirmed to
                // be the same Immich account, not merely "not proven
                // different." The index is partitioned per (URL, userId);
                // accepting a different account's key would point the
                // existing index at the wrong account (and, if we cached
                // the new identity, silently relabel the partition on next
                // launch). So resolve both identities and require a match:
                //   - new key's identity via the probe;
                //   - current account's identity from the cached userId,
                //     or fetched live via the existing client if the
                //     partition is URL-only (legacy installs).
                // If either side can't be resolved, or they differ, refuse
                // and route the user to Disconnect.
                let newIdentity = try? await probe.usersMe()
                // Resolve the current account's id: from the cached userId
                // when known, otherwise fetched live off the existing
                // client (URL-only legacy partitions).
                let resolvedCurrentId: String?
                if let currentUserId {
                    resolvedCurrentId = currentUserId
                } else if let existing = await MainActor.run(body: { self.immichClient }) {
                    resolvedCurrentId = (try? await existing.usersMe())?.id
                } else {
                    resolvedCurrentId = nil
                }
                guard let newId = newIdentity?.id, let curId = resolvedCurrentId else {
                    return .cannotConfirmAccount
                }
                guard newId == curId else {
                    return .wrongAccount(email: newIdentity?.email ?? "a different account")
                }

                // Preserve the run-history window: the per-key filter
                // keys on an API key's first-seen timestamp, so a
                // brand-new fingerprint would otherwise hide every prior
                // run. Seed the new key's activation with the OLD key's
                // timestamp instead of `now`.
                let oldActivatedAt = await MainActor.run { self.currentKeyActivatedAt } ?? .distantPast

                // Persist the new key with a checked write — if the
                // Keychain write fails, bail before swapping the live
                // client so we don't end up "rotated" in memory but
                // booting the old (likely-revoked) key next launch.
                do {
                    try secrets.setAPIKey(trimmedKey)
                } catch {
                    return .networkError(message: "Couldn't save the new key to the Keychain. \(Self.describeSyncError(error))")
                }
                // Deliberately NOT calling setUserIdentity here: rotation
                // doesn't change the account (we just confirmed it's the
                // same), and writing identity into a previously URL-only
                // partition would move it on next launch. The normal
                // bootstrap identity refresh handles any legacy migration.
                //
                // Re-activate against the SAME partition (unchanged
                // userId): re-opens the existing on-disk stores and
                // rebuilds the ImmichClient with the new key — no index,
                // journal, or run-history loss.
                try? await MainActor.run {
                    try self.activateServer(url: url, apiKey: trimmedKey, userId: currentUserId)
                }
                let fingerprint = AppDependencies.apiKeyFingerprint(trimmedKey)
                let activatedAt = AppDependencies.upsertKeyActivation(in: secrets, fingerprint: fingerprint, seedAt: oldActivatedAt)
                let serverCount = assets.filter { !$0.isTrashed }.count
                await MainActor.run {
                    self.currentKeyActivatedAt = activatedAt
                    self.model.apiKey = trimmedKey
                    self.model.apiKeyMasked = AppDependencies.mask(trimmedKey)
                    self.model.library = self.model.library.with(server: serverCount)
                    self.rewireActions()
                    self.registerPhotoLibraryObserver()
                }
                syncLog.notice("[cairn.apikey] rotated in place (same account, history preserved)")
                return .success
            }
        )

        self.model.actions = actions
    }

    // MARK: - Helpers

    nonisolated private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// `nil` (settings field unset) or `0` (settings field zero) →
    /// `nil` (no limit). Otherwise returns megabytes × 1024 × 1024.
    /// Centralizes the megabytes-to-bytes conversion that appears
    /// for the iCloud hard ceiling and friends; the previous
    /// `(mb.map { $0 > 0 } ?? false) ? Int64(mb!) * ...` form had a
    /// force-unwrap right next to the safety check that justifies it.
    nonisolated fileprivate static func megabytesToBytes(_ mb: Int?) -> Int64? {
        mb.flatMap { $0 > 0 ? Int64($0) * 1024 * 1024 : nil }
    }


    private static func serverContainerURL(for key: ServerPartitionKey) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "servers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(key.directoryName).store")
    }

    private static func serverJournalURL(for key: ServerPartitionKey) -> URL {
        let docs = documentsDirectory().appending(path: "servers").appending(path: key.directoryName)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs.appending(path: "deletion-journal.jsonl")
    }

    /// One-time rename: pre-userId-partitioning installs have a per-
    /// server directory at `<sanitizedURL>` (no user suffix). After
    /// per-user partitioning lands, the same data should live at
    /// `<sanitizedURL>__<userId>`. This helper detects that situation
    /// at activation time and renames in place — so the user's existing
    /// Observed, journal, runs, etc. carry forward without reset.
    ///
    /// Best-effort. If the rename fails (rare: file open by another
    /// process, permissions), we log but continue — `activateServer`
    /// will then create a fresh empty partition at the new path. State
    /// loss in that pathological case but no hard failure.
    private static func migrateLegacyServerPartitionIfNeeded(url: URL, userId: String?) {
        guard let userId, !userId.isEmpty else { return }
        let legacyKey = ServerPartitionKey(from: url, userId: nil)
        let newKey = ServerPartitionKey(from: url, userId: userId)
        guard legacyKey.directoryName != newKey.directoryName else { return }

        let fm = FileManager.default
        let legacyContainer = serverContainerURL(for: legacyKey)
        let newContainer = serverContainerURL(for: newKey)
        // SwiftData stores spawn `-shm` / `-wal` sibling files alongside
        // the main `.store`. Move all three for a clean migration.
        //
        // When BOTH src and dst exist we delete src instead. Earlier
        // we left it alone, but that produces a phantom-partition bug:
        // bootstrap routes to the URL-only partition when no userId is
        // cached (e.g. right after sign-out), then `verifyServer`
        // switches to URL+userId. User-driven actions taken in the
        // first state (clear-exclusions etc.) hit the legacy partition
        // — which is then irrelevant once the user re-verifies. Net
        // effect: stuff the user thought they wiped reappears the
        // moment a userId lands. Deleting the orphan legacy partition
        // is safe: dst is the canonical newer state by construction
        // (it's what the user has been writing to since per-(URL,
        // userId) partitioning landed), and a userId is cached only
        // after a successful `usersMe()` against the same URL.
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: legacyContainer.path + suffix)
            let dst = URL(fileURLWithPath: newContainer.path + suffix)
            let srcExists = fm.fileExists(atPath: src.path)
            let dstExists = fm.fileExists(atPath: dst.path)
            if srcExists && !dstExists {
                do {
                    try fm.moveItem(at: src, to: dst)
                } catch {
                    syncLog.error("[cairn.migrate] couldn't move \(src.lastPathComponent, privacy: .public) → \(dst.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            } else if srcExists && dstExists {
                do {
                    try fm.removeItem(at: src)
                    syncLog.notice("[cairn.migrate] removed orphan legacy file \(src.lastPathComponent, privacy: .public) (dst already populated)")
                } catch {
                    syncLog.error("[cairn.migrate] couldn't remove orphan legacy file \(src.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Journal directory rename. Same orphan-cleanup logic as the
        // store files above: if the destination already exists, the
        // legacy directory is the phantom and gets removed.
        let docs = documentsDirectory().appending(path: "servers")
        let legacyJournalDir = docs.appending(path: legacyKey.directoryName)
        let newJournalDir = docs.appending(path: newKey.directoryName)
        let legacyJournalExists = fm.fileExists(atPath: legacyJournalDir.path)
        let newJournalExists = fm.fileExists(atPath: newJournalDir.path)
        if legacyJournalExists && !newJournalExists {
            do {
                try fm.moveItem(at: legacyJournalDir, to: newJournalDir)
            } catch {
                syncLog.error("[cairn.migrate] couldn't move journal dir \(legacyJournalDir.lastPathComponent, privacy: .public) → \(newJournalDir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        } else if legacyJournalExists && newJournalExists {
            do {
                try fm.removeItem(at: legacyJournalDir)
                syncLog.notice("[cairn.migrate] removed orphan legacy journal dir \(legacyJournalDir.lastPathComponent, privacy: .public) (dst already populated)")
            } catch {
                syncLog.error("[cairn.migrate] couldn't remove orphan legacy journal dir \(legacyJournalDir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        syncLog.notice("[cairn.migrate] partition rename: \(legacyKey.directoryName, privacy: .public) → \(newKey.directoryName, privacy: .public)")
    }

    private static func migrateFromLegacyIfNeeded(serverURL: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "app.cairn.partitioned-v1") else { return }
        let key = ServerPartitionKey(from: serverURL)
        let fm = FileManager.default

        let docs = documentsDirectory()
        let legacyJournal = docs.appending(path: "deletion-journal.jsonl")
        if fm.fileExists(atPath: legacyJournal.path) {
            let dest = serverJournalURL(for: key)
            try? fm.moveItem(at: legacyJournal, to: dest)
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyStore = appSupport.appending(path: "default.store")
        let serverStore = serverContainerURL(for: key)
        if fm.fileExists(atPath: legacyStore.path) && !fm.fileExists(atPath: serverStore.path) {
            for suffix in ["", "-shm", "-wal"] {
                let src = URL(fileURLWithPath: legacyStore.path + suffix)
                let dst = URL(fileURLWithPath: serverStore.path + suffix)
                if fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }

        defaults.set(true, forKey: "app.cairn.partitioned-v1")
    }

    private static func buildServerPayload(
        key: ServerPartitionKey,
        observed: SwiftDataObservedStore,
        exclusions: SwiftDataExclusionStore,
        journal: DeletionJournal
    ) async throws -> CairnExportPayload.ServerPayload {
        let observedSet = try await observed.snapshot()
        let sortedObserved = observedSet.map(\.base64).sorted()

        let exclusionMap = try await exclusions.snapshot()
        let exclusionRecords = exclusionMap
            .sorted { $0.key.base64 < $1.key.base64 }
            .map { ck, meta in
                CairnExportPayload.ServerPayload.ExclusionRecord(
                    checksum: ck.base64,
                    addedAt: meta.addedAt,
                    fromRunId: meta.fromRunId,
                    reason: meta.reason
                )
            }

        // Live journal + archived history, so the full forensic record
        // survives an export round-trip. Archived rows are appended after
        // the live ones; on re-import they all land back in the live file
        // (a one-time un-rotation that the next sync re-rotates).
        let journalLines = ((try? await journal.readRawLines()) ?? [])
            + ((try? await journal.readArchiveRawLines()) ?? [])

        return CairnExportPayload.ServerPayload(
            partitionKey: key.directoryName,
            normalizedURL: key.normalizedURL,
            observed: sortedObserved,
            exclusions: exclusionRecords,
            journal: journalLines
        )
    }

    private static func mask(_ key: String) -> String {
        let tail = key.suffix(4)
        return String(repeating: "•", count: 10) + tail
    }

    private static func makePreviewActions() -> CairnAppActions {
        CairnAppActions()
    }

    /// Populate the model with a representative fixture state for App
    /// Store review. Production-safe (not gated `#if DEBUG`) because
    /// the reviewer runs the release binary. Activated via the magic
    /// URL in `verifyServer`; persisted across launches via
    /// `reviewModeActiveKey`.
    ///
    /// What the reviewer sees after seeding:
    ///   - Onboarding skipped, main tabs visible
    ///   - Status: realistic library counts + recent runs + journal
    ///     tail
    ///   - Pending Review: a few candidates so the reviewer can tap
    ///     through approve/exclude flows without needing real photos
    ///   - Settings: connection status healthy, all controls live
    ///
    /// All actions remain wired — but read-only against the fixture
    /// state. A real sync against `review.cairn.invalid` would
    /// produce a network error (the URL doesn't resolve), so the
    /// reviewer's tap on "Sync" silently no-ops without false
    /// promises.
    @MainActor
    static func seedReviewMode(into model: CairnAppModel) {
        model.didAutoSyncThisSession = true
        model.isBootstrapping = false
        model.needsOnboarding = false
        model.hasCompletedInitialScan = true

        model.serverHost = "review.cairn.invalid"
        model.serverURL = URL(string: reviewModeMagicURL)
        model.apiKey = "(review mode)"
        model.apiKeyMasked = "(review mode)"
        model.connectionStatus = .healthy(latencyMs: 12)

        // Library counts deliberately constructed so the surfaces are
        // mutually consistent: 50 photos on iPhone, 55 on Immich, 5 of
        // those don't match anything on iPhone (the deletion
        // candidates). Using the much-larger CairnFixtures.medium
        // here would put `candidates: 14` in the library while
        // reconciliation only has 5 — Status would then read "14
        // ready to trash" big with a 5-candidate dry-run sheet,
        // which is the inconsistency that prompted this rework.
        model.library = CairnFixtures.LibrarySize(
            local: 50,
            indexed: 55,
            server: 55,
            matched: 55,
            candidates: 5
        )
        model.runs = CairnFixtures.runs
        model.journalTail = CairnFixtures.journalTail

        Self.applyReviewReconciliation(to: model)

        // Wire actions that mutate the local model only — no network,
        // no Immich client, no SwiftData. Gives the reviewer a working
        // flow they can tap through (trash, exclude, restore, etc.)
        // even though nothing leaves the device.
        model.actions = makeReviewModeActions(model: model)
    }

    /// Build the review-mode reconciliation fixture and stamp it onto
    /// the model. Extracted so both initial seed and Sync re-seed use
    /// the same shape, avoiding duplicate construction.
    ///
    /// Buckets are disjoint, matching production semantics: an item is
    /// either eligible for trash now (past quarantine) OR held for
    /// review, never both. An earlier seed had the same 5 fixture rows
    /// in both `deleteCandidates` and `pendingReviewCandidates`; that
    /// produced a confusing dual display where DryRunSheet showed all
    /// 5 as "to trash" and PendingReview showed the same 5 split as
    /// "3 held · 2 unconfirmed" — the same items wearing two
    /// different state labels.
    ///
    /// Now: 5 items in delete (confirmed > quarantine ago) + 3
    /// different items in held (confirmed within quarantine window).
    /// Status reads "5 ready to trash · 3 in quarantine"; DryRunSheet
    /// and PendingReview show distinct, non-overlapping populations.
    @MainActor
    private static func applyReviewReconciliation(to model: CairnAppModel) {
        let trashFixtures = Array(CairnFixtures.candidates.prefix(5))
        let heldFixtures = Array(CairnFixtures.candidates.dropFirst(5).prefix(3))
        var confirmedAt: [Checksum: Date] = [:]
        // Trash bucket: confirmed-deleted 30 days ago — well past the
        // 14-day quarantine, so they're eligible to trash now.
        for fixture in trashFixtures {
            if let cs = fixture.checksum {
                confirmedAt[Checksum(base64: cs)] = Date(timeIntervalSinceNow: -30 * 86_400)
            }
        }
        // Held bucket: confirmed 0/1/2 days ago — still inside the
        // quarantine window. The staggered timestamps let the UI
        // render distinct "expires in N days" countdowns.
        for (idx, fixture) in heldFixtures.enumerated() {
            if let cs = fixture.checksum {
                confirmedAt[Checksum(base64: cs)] = Date(timeIntervalSinceNow: -TimeInterval(idx) * 86_400)
            }
        }
        model.reconciliation = .init(
            deleteCandidates: trashFixtures.map { $0.asServerAsset },
            pendingReviewCandidates: heldFixtures.map { $0.asServerAsset },
            heldByQuarantineCandidates: heldFixtures.map { $0.asServerAsset },
            confirmedDeletedAt: confirmedAt,
            quarantineDays: 14
        )
        // Status's "ready to trash" hero number reads `library.candidates`
        // (production sets this to `deleteCandidates.count`). Keep them
        // in sync so the hero number matches the dry-run list.
        model.library = model.library.with(candidates: trashFixtures.count)
    }

    /// Action bundle for App Store review mode. Each closure simulates
    /// its production effect by mutating the local model directly —
    /// no orchestrators, no network, no stores. Lets the reviewer
    /// exercise the full UI flow against fixture state.
    @MainActor
    private static func makeReviewModeActions(model: CairnAppModel) -> CairnAppActions {
        CairnAppActions(
            requestSync: { [weak model] _ in
                // Two paths depending on whether candidates are
                // currently visible:
                //   1. Reconciliation is nil/empty (post-trash, or
                //      after the user dismissed everything) → re-seed
                //      5 candidates. Mimics "you deleted more photos
                //      and cairn found them on the next sync." Lets
                //      the reviewer (and anyone testing review mode)
                //      run the trash flow repeatedly without
                //      rebuilding — without re-seeding here, Sync
                //      becomes a dead button after the first trash.
                //   2. Candidates already present → leave them alone
                //      and report "up to date." Re-seeding while the
                //      bucket is full would resurrect items the user
                //      just decided to keep, which reads as a bug.
                // Either way, set lastCheckedAt + the toast so the
                // tap registers visually.
                await MainActor.run {
                    guard let model else { return }
                    let bucketIsEmpty = (model.reconciliation?.deleteCandidates.isEmpty ?? true)
                        && (model.reconciliation?.pendingReviewCandidates.isEmpty ?? true)
                    if bucketIsEmpty {
                        Self.applyReviewReconciliation(to: model)
                    }
                    model.lastCheckedAt = Date()
                    model.syncToast = .upToDate(
                        indexed: model.library.indexed,
                        total: model.library.local
                    )
                }
            },
            confirmTrash: { [weak model] in
                await MainActor.run {
                    guard let model, let live = model.reconciliation else { return }
                    let trashedCount = live.deleteCandidates.count
                    guard trashedCount > 0 else { return }
                    Self.simulateTrashRun(
                        in: model,
                        trashedCount: trashedCount,
                        clearReconciliation: true
                    )
                    // Reset acknowledged set: the items the user just
                    // trashed are no longer relevant to acknowledge.
                    // Without this, review mode's same-checksum re-seed
                    // on the next Sync would be wrongly suppressed by
                    // the stale acknowledged set.
                    model.acknowledgedCandidateChecksums = []
                }
            },
            restore: { [weak model] _, runId in
                // Mark the named run as restored — visible feedback in
                // the Runs tab without modifying server state. Rebuild
                // the fixture with the new status (RunFixture has no
                // `.with(...)` mutator, so this is a re-construction).
                await MainActor.run {
                    guard let model, !model.runs.isEmpty else { return }
                    if let idx = model.runs.firstIndex(where: { $0.id == runId }) {
                        let r = model.runs[idx]
                        model.runs[idx] = CairnFixtures.RunFixture(
                            id: r.id,
                            startedAt: r.startedAt,
                            durationMs: r.durationMs,
                            trashed: r.trashed,
                            restored: r.trashed,
                            dryRun: r.dryRun,
                            status: .restored,
                            tag: r.tag,
                            notes: r.notes
                        )
                    }
                }
            },
            exclude: { [weak model] checksums, filenames, runId in
                await MainActor.run {
                    guard let model else { return }
                    let entries = zip(filenames, checksums).map { name, ck in
                        ExcludedScreenEntry(
                            filename: name,
                            bytes: 2_400_000,
                            kind: .photo,
                            isLivePair: false,
                            metadata: ExclusionMetadata(
                                addedAt: Date(),
                                fromRunId: runId
                            )
                        )
                    }
                    model.excludedEntries.append(contentsOf: entries)
                    model.excludedChecksums.formUnion(checksums)
                }
            },
            unexclude: { [weak model] checksums in
                await MainActor.run {
                    guard let model else { return }
                    let drop = Set(checksums)
                    // ExcludedScreenEntry has no checksum field — match
                    // by the displayed filename. Review mode pairs them
                    // 1:1 in `exclude`, so this round-trips cleanly.
                    let removedFilenames = model.excludedEntries
                        .filter { drop.contains($0.filename) }
                        .map(\.filename)
                    model.excludedEntries.removeAll { removedFilenames.contains($0.filename) }
                    model.excludedChecksums.subtract(drop)
                }
            },
            approvePending: { [weak model] checksums in
                await MainActor.run {
                    guard let model, let live = model.reconciliation else { return }
                    let drop = Set(checksums)
                    // Same shape as dismissPending: drop from all three
                    // buckets, not just pending/held. Without filtering
                    // `deleteCandidates`, partial trashes through the
                    // PendingReview "Trash N" path leave stale entries
                    // there; the next Sync's `bucketIsEmpty` gate stays
                    // false → no re-seed → button reads as dead after
                    // a few rounds.
                    let cks = Set(drop.map { Checksum(base64: $0) })
                    let pruned = live.removing(checksums: cks)
                    model.reconciliation = pruned
                    Self.simulateTrashRun(
                        in: model,
                        trashedCount: drop.count,
                        clearReconciliation: false
                    )
                    // simulateTrashRun forces library.candidates to 0
                    // (assumes the caller is trashing the whole bucket).
                    // For partial trashes, override with the actual
                    // remaining count so Status's hero number matches
                    // the live reconciliation.
                    model.library = model.library.with(candidates: pruned.deleteCandidates.count)
                    // Subtract approved checksums from the acknowledged
                    // set; remaining acknowledgements still apply to
                    // items the user hasn't acted on yet.
                    model.acknowledgedCandidateChecksums.subtract(drop)
                }
            },
            excludePending: { [weak model] checksums in
                await MainActor.run {
                    guard let model, let live = model.reconciliation else { return }
                    let drop = Set(checksums)
                    let cks = Set(drop.map { Checksum(base64: $0) })
                    let added: [ExcludedScreenEntry] = live.pendingReviewCandidates
                        .filter { drop.contains($0.checksum.base64) }
                        .map { asset in
                            ExcludedScreenEntry(
                                filename: asset.originalFileName ?? "asset",
                                bytes: 2_400_000,
                                kind: .photo,
                                isLivePair: false,
                                metadata: ExclusionMetadata(addedAt: Date())
                            )
                        }
                    model.excludedEntries.append(contentsOf: added)
                    model.excludedChecksums.formUnion(drop)
                    let pruned = live.removing(checksums: cks)
                    model.reconciliation = pruned
                    // Keep Status's "ready to trash" chip aligned with
                    // the live reconciliation — same reason as the
                    // dismiss/approve paths above.
                    model.library = model.library.with(candidates: pruned.deleteCandidates.count)
                    model.acknowledgedCandidateChecksums.subtract(drop)
                }
            },
            dismissPending: { [weak model] checksums in
                await MainActor.run {
                    guard let model, let live = model.reconciliation else { return }
                    let drop = Set(checksums)
                    // Drop from all three buckets — the review-mode seed
                    // puts the same fixture rows in `deleteCandidates` and
                    // `pendingReviewCandidates` simultaneously (production
                    // keeps them mutually exclusive but the demo wants
                    // both surfaces populated at once). Without dropping
                    // from `deleteCandidates` too, dismissing the
                    // pending list leaves a phantom "N ready to trash"
                    // chip on Status with nothing to back it up, and
                    // Sync's `bucketIsEmpty` re-seed gate stays false
                    // forever → button reads as dead.
                    let cks = Set(drop.map { Checksum(base64: $0) })
                    let pruned = live.removing(checksums: cks)
                    model.reconciliation = pruned
                    // Status's "N ready to trash" hero number reads
                    // `library.candidates`, not `reconciliation.deleteCandidates.count`.
                    // Keep them in sync so Status visibly clears.
                    model.library = model.library.with(candidates: pruned.deleteCandidates.count)
                    // Subtract dismissed checksums from the acknowledged
                    // set so the next Sync's re-seed (same fixture, same
                    // checksums) is treated as a fresh discovery and
                    // auto-pops the dialog. Symmetry with `confirmTrash`,
                    // which also clears acknowledgements after acting.
                    model.acknowledgedCandidateChecksums.subtract(drop)
                }
            }
        )
    }

    /// Simulate the visible effects of a successful trash run: insert
    /// a fake completed run, append a journal entry, and (optionally)
    /// drop the active reconciliation. Used by review-mode actions.
    @MainActor
    private static func simulateTrashRun(
        in model: CairnAppModel,
        trashedCount: Int,
        clearReconciliation: Bool
    ) {
        let runId = "review-\(UUID().uuidString.prefix(8))"
        let fixture = CairnFixtures.RunFixture(
            id: runId,
            startedAt: Date(),
            durationMs: 6_000,
            trashed: trashedCount,
            restored: 0,
            dryRun: false,
            status: .complete,
            tag: "cairn/v1/run/\(runId)",
            notes: "review-mode simulation"
        )
        model.runs.insert(fixture, at: 0)

        let lib = model.library
        model.library = lib.with(
            server: max(0, lib.server - trashedCount),
            matched: max(0, lib.matched - trashedCount),
            candidates: 0
        )

        if clearReconciliation {
            model.reconciliation = nil
        }
    }

    #if DEBUG
    @MainActor
    static func seedFromFixtures(into model: CairnAppModel) {
        let args = ProcessInfo.processInfo.arguments
        let wantsOnboarding = args.contains("-CAIRN_SCREENSHOT_ONBOARDING")
        let wantsDark = args.contains("-CAIRN_SCREENSHOT_DARK")
        // Demo-stage selector: 0..5 produce stages of the trash/restore
        // walkthrough on a 25-photo limited-scope album. Used to record
        // a workflow screencast/screenshots without touching a real
        // Immich. Falls through to the App-Store-marketing fixtures
        // when the arg is absent.
        let demoStage: Int? = {
            guard let idx = args.firstIndex(of: "-CAIRN_DEMO_STAGE"),
                  idx + 1 < args.count,
                  let n = Int(args[idx + 1]) else { return nil }
            return n
        }()

        model.actions = CairnAppActions()
        model.didAutoSyncThisSession = true

        model.serverHost = "photos.home.arpa"
        model.apiKey = "sk_cairn_screenshot_fixture"
        model.apiKeyMasked = "••••••••••xture"
        model.connectionStatus = .healthy(latencyMs: 42)

        model.settings.appearance = wantsDark ? .dark : .light

        if wantsOnboarding {
            model.needsOnboarding = true
            return
        }

        model.needsOnboarding = false
        model.hasCompletedInitialScan = true

        if let stage = demoStage {
            seedDemoStage(stage, into: model)
            return
        }

        model.library = CairnFixtures.medium
        model.runs = CairnFixtures.runs
        model.journalTail = CairnFixtures.journalTail

        let heldFixtures = Array(CairnFixtures.candidates.prefix(3))
        let pendingFixtures = Array(CairnFixtures.candidates.prefix(5))
        let confirmedAt: [Checksum: Date] = Dictionary(
            uniqueKeysWithValues: heldFixtures.enumerated().compactMap { idx, c in
                c.checksum.map {
                    (Checksum(base64: $0), Date(timeIntervalSinceNow: -TimeInterval(idx) * 86_400))
                }
            }
        )
        model.reconciliation = .init(
            deleteCandidates: pendingFixtures.map { $0.asServerAsset },
            pendingReviewCandidates: pendingFixtures.map { $0.asServerAsset },
            heldByQuarantineCandidates: heldFixtures.map { $0.asServerAsset },
            confirmedDeletedAt: confirmedAt,
            quarantineDays: 14
        )
    }

    /// Pose model state for one of the six trash/restore walkthrough
    /// stages used to record the demo. Each stage is a snapshot — the
    /// UI test that captures it lands on the right tab and snapshots.
    /// No real backend; no real PhotoKit.
    ///
    /// Reference numbers throughout: 25-photo album, 5 deleted from
    /// device, 2 of those restored on Immich. Library counts trace:
    ///
    ///   Stage 0 (initial)            — 25 / 25 / 25 / 25
    ///   Stage 1 (post-device-delete) — 20 / 20 / 25 / 25  · 5 quarantined
    ///   Stage 2 (PendingReview)      — same model, navigated
    ///   Stage 3 (post-approve trash) — 20 / 20 / 20 / 20
    ///   Stage 4 (Runs)               — same model, navigated
    ///   Stage 5 (post-restore 2)     — 20 / 20 / 22 / 22
    private static func seedDemoStage(_ stage: Int, into model: CairnAppModel) {
        let demoCandidates = Array(CairnFixtures.candidates.prefix(5))
        let trashRunId = "2026-04-29T10:00:00Z-DEMO0429"
        let restoreRunStartedAt = ISO8601DateFormatter().date(from: "2026-04-29T10:00:00Z") ?? Date()

        switch stage {
        case 0:
            // Fresh post-onboarding sync. 25 photos in the album,
            // 25 on Immich, all match. Nothing pending.
            model.library = CairnFixtures.LibrarySize(
                local: 25, indexed: 25, server: 25, matched: 25, candidates: 0
            )
            model.runs = []
            model.journalTail = []
            model.reconciliation = nil

        case 1, 2:
            // After deleting 5 from the iPhone. cairn detected via
            // PhotoKit, stamped ConfirmedDeleted, sync surfaced them
            // as held-by-quarantine. With quarantineDays: 0 (or via
            // approve-from-pending-review) they'd promote; we pose
            // them in the held bucket so the demo can also show the
            // bypass-via-approve flow on the next stage.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 25, matched: 25, candidates: 5
            )
            // `heldByQuarantineCandidates` is a subset of
            // `pendingReviewCandidates` (the engine always populates both
            // — see `LiveReconciliation`). Pose them as the same set here:
            // the Status quarantine line (and its `status.openPendingReview`
            // entry button the demo taps) gates on `pendingReviewCount`,
            // so leaving the superset empty hid the line and broke the
            // demo's Pending Review navigation.
            let demoHeld = demoCandidates.map(\.asServerAsset)
            // Key confirmed-deleted stamps off the held assets' own
            // checksums (not the fixtures' optional `checksum`, which is
            // nil for synthetic candidates and so never matched) — so the
            // per-item countdown and same-day batch stacking actually
            // resolve. Stamps a few minutes apart on the same day.
            let confirmedAt: [Checksum: Date] = Dictionary(
                uniqueKeysWithValues: demoHeld.enumerated().map { idx, asset in
                    (asset.checksum, Date(timeIntervalSinceNow: -TimeInterval(idx) * 60))
                }
            )
            model.reconciliation = .init(
                deleteCandidates: [],
                pendingReviewCandidates: demoHeld,
                heldByQuarantineCandidates: demoHeld,
                confirmedDeletedAt: confirmedAt,
                quarantineDays: 14
            )
            model.quarantineCount = demoCandidates.count
            model.runs = []
            model.journalTail = []

        case 3, 4:
            // Right after the user tapped "Move to Trash" on the 5
            // quarantined items. Server count dropped, candidates
            // cleared, the trash run is now in `model.runs`.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 20, matched: 20, candidates: 0
            )
            model.reconciliation = nil
            let trashRun = CairnFixtures.RunFixture(
                id: trashRunId,
                startedAt: restoreRunStartedAt,
                durationMs: 4_120,
                trashed: 5,
                restored: 0,
                dryRun: false,
                status: .complete,
                tag: "cairn/v1/run/\(trashRunId)",
                notes: "5 trashed"
            )
            model.runs = [trashRun]
            model.runAssets = [trashRunId: demoCandidates]

        case 5:
            // After restoring 2 of the 5 via Runs → tap-run → restore.
            // Immich un-trashed those 2 → server bumped 20→22. The
            // approvePending / restore commits keep matched in
            // lockstep with server. Run shows `2 restored`.
            model.library = CairnFixtures.LibrarySize(
                local: 20, indexed: 20, server: 22, matched: 22, candidates: 0
            )
            model.reconciliation = nil
            let trashRun = CairnFixtures.RunFixture(
                id: trashRunId,
                startedAt: restoreRunStartedAt,
                durationMs: 4_120,
                trashed: 5,
                restored: 2,
                dryRun: false,
                status: .complete,
                tag: "cairn/v1/run/\(trashRunId)",
                notes: "5 trashed · 2 restored from this run"
            )
            model.runs = [trashRun]
            model.runAssets = [trashRunId: demoCandidates]

        default:
            // Out-of-range stage — fall through to the App-Store
            // fixture set so the test still produces a screenshot.
            model.library = CairnFixtures.medium
            model.runs = CairnFixtures.runs
            model.journalTail = CairnFixtures.journalTail
        }
    }
    #endif
}

// Pure data conversion used by `seedFromFixtures` (DEBUG screenshot
// pipeline) and `seedReviewMode` (App Store review mode, production).
// Not DEBUG-gated because review mode runs in release builds.
private extension CairnFixtures.CandidateFixture {
    var asServerAsset: ServerAsset {
        ServerAsset(
            id: assetId ?? "fixture-\(name)",
            checksum: Checksum(base64: checksum ?? "fixture-\(name)"),
            livePhotoVideoId: isLivePair ? "livepair-\(name)" : nil,
            isTrashed: false,
            originalFileName: name,
            fileCreatedAt: nil
        )
    }
}

import UIKit
