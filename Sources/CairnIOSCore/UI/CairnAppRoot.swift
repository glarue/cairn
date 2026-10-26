import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import CairnCore

/// The assembled cairn iOS app — top-level navigation, sheet presentation,
/// theme application, setup-vs-main routing.
///
/// Designed so the Xcode project's `@main App` is essentially a 20-line
/// shim that:
///   1. Instantiates concrete iOS-side store impls (Keychain, SwiftData,
///      PhotoKit, ImmichClient).
///   2. Bridges them into a `CairnAppModel` + `CairnAppActions` bundle.
///   3. Returns `CairnAppRoot(model:)` from its scene body.
///
/// Everything that can be tested or previewed without an iOS app target
/// lives here. Code-signing, Info.plist entitlements, BGTaskScheduler
/// registration, and PhotoKit permission prompts stay in the app target —
/// they fundamentally need the app context.
public struct CairnAppRoot: View {

    @Bindable public var model: CairnAppModel
    public let palette: CairnPalette

    /// Tracks the in-flight sync `Task` so the UI can cancel it. The
    /// reconciler's hashing loop checks `Task.isCancelled` between
    /// assets; hashes already computed are persisted to `LocalHashStore`
    /// inline, so the next sync resumes rather than restarts. `nil` when
    /// no sync is running.
    @State private var activeSyncTask: Task<Void, Never>?
    @State private var exportedFileURL: URL?
    @State private var importResult: CairnImportResult?

    /// Per-tab "scroll to top" token. Incremented when the user taps
    /// the active tab in the bottom nav (the standard iOS re-tap
    /// idiom). Each screen observes its slot via `.onChange` and
    /// drives a `ScrollViewReader.scrollTo(...)`.
    @State private var scrollResetTokens: [String: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed directly (not via a model token) so the background-cancel
    /// fires AT the `.background` transition rather than being deferred to
    /// the next foreground render — where it would race the foreground
    /// catch-up sync and occasionally cancel it the instant it started.
    @Environment(\.scenePhase) private var scenePhase
    /// True once we've seen a real `.background` transition, so a return to
    /// `.active` only triggers a catch-up sync when coming back from
    /// background — not from a transient `.inactive` (Control Center,
    /// notification shade, the app switcher peek).
    @State private var wasBackgrounded = false

    #if canImport(UIKit)
    private struct ShareSheet: UIViewControllerRepresentable {
        let url: URL
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }
    #endif

    public init(model: CairnAppModel, palette: CairnPalette = .defaults) {
        self.model = model
        self.palette = palette
    }

    public var body: some View {
        let _ = { CairnL10n.currentLanguage = model.settings.appLanguage }()
        bodyContent
            #if canImport(UIKit)
            .sheet(isPresented: Binding(
                get: { exportedFileURL != nil },
                set: { if !$0 { exportedFileURL = nil } }
            )) {
                if let url = exportedFileURL {
                    ShareSheet(url: url)
                        .presentationDetents([.medium])
                }
            }
            #endif
            .alert(
                "Import complete".loc,
                isPresented: Binding(
                    get: { importResult != nil },
                    set: { if !$0 { importResult = nil } }
                ),
                presenting: importResult
            ) { _ in
                Button("OK".loc, role: .cancel) { importResult = nil }
            } message: { result in
                Text(importResultMessage(for: result).loc)
            }
            // Persist every settings mutation. No explicit save UI — each
            // slider / toggle commit flows straight to disk. Debouncing
            // happens naturally because the store is atomic-write-per-save
            // and SwiftUI coalesces binding updates to one per frame.
            .onChange(of: model.settings) { _, newValue in
                Task { await model.actions.persistSettings(newValue) }
            }
            // Scope changes need to refresh `ObservedStore` album tags
            // — without this, toggling to a restricted scope leaves
            // every existing entry untagged, which the engine filter
            // treats as out-of-scope, which surfaces "0 candidates" no
            // matter what you do. Triggering on the scope value (not
            // the whole settings struct) avoids re-running on unrelated
            // settings changes.
            .onChange(of: model.settings.indexingScope) { _, _ in
                Task { await model.actions.recomputeScopeTags() }
            }
            // Journal-tail rows are pre-formatted strings cached on
            // the model (built in `refreshJournalTail` from the active
            // setting). Toggling the format picker doesn't change
            // those existing strings until the next refresh — so
            // trigger one explicitly here. RunsScreen reads its time
            // from the environment at render time and doesn't need a
            // refresh; same for sheet titles that recompute from
            // entry timestamps.
            .onChange(of: model.settings.timeDisplayFormat) { _, _ in
                Task { await model.actions.refreshJournalTail() }
            }
            // Start/stop the persistent diagnostic-log flusher the moment
            // the toggle flips, so the user doesn't have to relaunch for
            // it to take effect (or stop running).
            .onChange(of: model.settings.persistentDiagnosticLogging) { _, on in
                #if canImport(OSLog) && canImport(UIKit)
                Task {
                    if on {
                        await DiagnosticLogFlusher.shared.start()
                    } else {
                        await DiagnosticLogFlusher.shared.stop()
                    }
                }
                #endif
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        Group {
            if model.isBootstrapping {
                Color.clear
            } else if model.needsOnboarding {
                onboarding
            } else if !model.hasCompletedInitialScan && !model.hasDismissedInitialScan {
                // First-run path: hashing the whole library is substantial
                // work and the main tabs would show misleading zeroes
                // until it finishes. A dedicated screen makes the state
                // visible, explains the foreground-only constraint, and
                // gives the user cancel/resume controls. The screen is
                // dismissible ("Skip for now") — users who dismiss land
                // on the main tabs and get a persistent Status banner
                // pointing back here until the scan actually runs.
                initialScanRoute
            } else if model.settingsRoute == .excluded {
                excludedSubRoute
            } else {
                mainTabs
            }
        }
        // Apply the user's appearance override first so `cairnTheme`
        // below resolves tokens against the overridden scheme (not the
        // system one). `nil` passes through to SwiftUI's default
        // (follow system).
        .preferredColorScheme(appearanceOverrideScheme(model.settings.appearance))
        .cairnTheme(palette)
        // Flow the user's clock-format pick into the environment so
        // any view that renders a time (RunsScreen rows, journal tail
        // — via refresh — etc.) reads from a single source.
        .environment(\.cairnTimeFormat, model.settings.timeDisplayFormat)
        .environment(\.locale, CairnL10n.currentLocale)
        .id("cairn-root-\(model.settings.appLanguage.rawValue)")
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.needsOnboarding)
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.hasCompletedInitialScan)
        .animation(reduceMotion ? .none : .snappy(duration: 0.18), value: model.settingsRoute)
        .sheet(item: Binding(
            get: { model.presentedSheet },
            set: { model.presentedSheet = $0 }
        )) { sheet in
            sheetContent(for: sheet)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Error surface: anything written to `model.lastError` pops here.
        // Without this, failed syncs would silently eat themselves (Photos
        // permission denied, API key rejected, network down) and the user
        // would see a "tap does nothing" interaction with no feedback.
        .alert(
            "Couldn't finish".loc,
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            presenting: model.lastError
        ) { _ in
            Button("OK".loc, role: .cancel) { model.lastError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Appearance override

    /// Translate `AppearanceOverride` into the `ColorScheme?` SwiftUI's
    /// `.preferredColorScheme` wants. `.system` → `nil` (follow OS).
    /// Renders the post-import alert text. Surfaces hash-cache restore
    /// status alongside the existing observed/exclusions/journal/
    /// settings tally so the user sees whether their (often expensive)
    /// SHA1 cache came back or was skipped — and if skipped, why.
    /// Tester-facing log export entry point. Gated to UIKit because
    /// `LogExporter` depends on `UIDevice` + `OSLogStore`; in the
    /// macOS-only build context the helper compiles down to a no-op
    /// so `SettingsScreen`'s closure-typed parameter still has
    /// something to bind to.
    private var exportDiagnosticLogsAction: () -> Void {
        {
            #if canImport(UIKit) && canImport(OSLog)
            Task { @MainActor in
                do {
                    let url = try await LogExporter.export()
                    exportedFileURL = url
                } catch {
                    model.lastError = CairnL10n.isChinese
                        ? "无法导出日志：\(error.localizedDescription)"
                        : "Couldn't export logs: \(error.localizedDescription)"
                }
            }
            #endif
        }
    }

    private func importResultMessage(for result: CairnImportResult) -> String {
        if CairnL10n.isChinese {
            var parts: [String] = []
            parts.append("已处理 \(result.serverCount) 个服务器的数据。")
            parts.append("新增 \(result.observedAdded) 个校验值、\(result.exclusionsAdded) 项排除、\(result.journalLinesAppended) 行日志。")
            if result.settingsApplied {
                parts.append("已应用设置。")
            }
            switch result.hashCacheSkippedReason {
            case .deviceMismatch:
                parts.append("哈希缓存已跳过 — 备份来自其他设备（或导出后本 iPhone 曾从备份恢复）。照片将在下次同步时重新计算哈希。")
            case .missingIDFV:
                parts.append("哈希缓存已跳过 — 备份未包含设备指纹，cairn 无法确认恢复是否安全。照片将在下次同步时重新计算哈希。")
            case nil:
                if result.hashCacheImported > 0 {
                    parts.append("哈希缓存已恢复 — 导入了 \(result.hashCacheImported.formatted(.number)) 行，无需重新计算。")
                }
            }
            return parts.joined()
        }
        var parts: [String] = []
        parts.append("\(result.serverCount) server\(result.serverCount == 1 ? "" : "s") processed.")
        parts.append("\(result.observedAdded) checksums added, \(result.exclusionsAdded) exclusions added, \(result.journalLinesAppended) journal lines appended.")
        if result.settingsApplied {
            parts.append("Settings applied.")
        }
        switch result.hashCacheSkippedReason {
        case .deviceMismatch:
            parts.append("Hash cache skipped — backup came from a different device (or this iPhone was restored from backup since the export). Photos will re-hash on the next sync.")
        case .missingIDFV:
            parts.append("Hash cache skipped — backup didn't include a device fingerprint, so cairn can't tell if it's safe to restore. Photos will re-hash on the next sync.")
        case nil:
            if result.hashCacheImported > 0 {
                parts.append("Hash cache restored — \(result.hashCacheImported.formatted(.number)) rows imported, no re-hashing needed.")
            }
        }
        return parts.joined(separator: " ")
    }

    private func appearanceOverrideScheme(_ override: AppearanceOverride) -> ColorScheme? {
        switch override {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Total "user action required" count: eligible-to-trash plus
    /// pending-review. `heldByQuarantineCandidates` is already a
    /// subset of `pendingReviewCandidates`, so adding it again
    /// would double-count held items. Used to gate the Status
    /// backlog-alert banner.
    private var backlogCount: Int {
        guard let r = model.reconciliation else { return 0 }
        return r.deleteCandidates.count + r.pendingReviewCandidates.count
    }

    private var quarantineCountForStatus: Int {
        // Use only the reconciliation result here — `model.quarantineCount`
        // counts raw ConfirmedDeletedStore entries (including orphan
        // sweep finds that may not be on the server), so falling back
        // to it produces a misleading number that flickers down once
        // reconciliation completes. 0-as-fallback means "no badge"
        // until we have a server-matched count, which is honest.
        model.reconciliation?.heldByQuarantineCandidates.count ?? 0
    }

    private var earliestQuarantineEligible: Date? {
        guard let live = model.reconciliation else { return nil }
        let window = TimeInterval(live.quarantineDays * 86_400)
        return live.heldByQuarantineCandidates.compactMap { asset -> Date? in
            guard let confirmed = live.confirmedDeletedAt[asset.checksum] else { return nil }
            return confirmed.addingTimeInterval(window)
        }.min()
    }


    // MARK: - Onboarding

    private var onboarding: some View {
        SetupScreen(
            serverUrl: $model.serverHost,
            apiKey: $model.apiKey,
            settings: $model.settings,
            onVerifyServer: { url, key in
                await model.actions.verifyServer(url, key)
            },
            onRequestPhotosAccess: {
                await model.actions.requestPhotosAccess()
            },
            onPollPhotoAuthStatus: {
                await model.actions.currentPhotoAuthStatus()
            },
            onRequestBackgroundRefresh: {
                await model.actions.requestBackgroundRefresh()
            },
            onLoadRecentServers: {
                await model.actions.recentServers()
            },
            onComplete: {
                model.activeTab = .status
                model.needsOnboarding = false
            }
        )
    }

    // MARK: - Settings sub-route

    private var excludedSubRoute: some View {
        ExcludedScreen(
            entries: model.excludedEntries,
            onBack: { model.settingsRoute = .root },
            onUnexclude: { filenames in
                Task { @MainActor in
                    try? await model.actions.unexclude(filenames)
                    // Optimistically remove from the local list — the host
                    // will reconcile on next refresh.
                    model.excludedEntries.removeAll { filenames.contains($0.filename) }
                }
            }
        )
    }

    // MARK: - Initial scan route

    private var initialScanRoute: some View {
        InitialScanScreen(
            total: model.syncProgress?.total ?? model.library.local,
            hashed: model.syncProgress?.hashed ?? model.library.indexed,
            indexed: model.library.indexed,
            imputed: model.syncProgress?.imputed ?? 0,
            deferredQueueCount: model.deferredQueue.count,
            isActive: model.isSyncing,
            startedAt: model.syncStartedAt,
            pausedElapsed: model.pausedSyncElapsedSeconds,
            initialHashed: model.syncProgress?.initialHashed ?? 0,
            persistedRate: model.persistedSyncRate,
            phase: model.syncPhase,
            serverAssetsFetched: model.serverAssetsFetched,
            serverAssetsExpected: model.serverAssetsExpected,
            scanned: model.syncProgress?.scanned,
            settings: $model.settings,
            onStart: { startTrackedSync() },
            onCancel: { cancelActiveSync() },
            onStartOver: {
                Task {
                    await model.actions.startOverInitialScan()
                }
            },
            onDismiss: {
                Task {
                    await model.actions.dismissInitialScan()
                }
            }
        )
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["CAIRN_AUTO_SCAN"] == "1"
                || UserDefaults.standard.bool(forKey: "CAIRN_AUTO_SCAN") {
                startTrackedSync()
            }
        }
        #endif
    }

    // MARK: - Main tabs

    /// Native page-style TabView wrapping each tab as a page. Picks up
    /// horizontal swipe-to-paginate at the system level (UIPageViewController
    /// under the hood), which means inner horizontal scrollables — runs
    /// row, journal strip — keep their own pan gesture and only hand off
    /// to the page-flip when they hit their edge. The previous DragGesture
    /// overlay on the tab bar was undiscoverable; this matches Photos.app's
    /// timeline ↔ detail viewer convention.
    @ViewBuilder
    private var paginatedTabView: some View {
        // `.page` style is iOS-only (UIPageViewController-backed). On
        // macOS the same TabView falls back to the default segmented
        // chrome — fine for previews; the live macOS path is unused.
        let tabs = TabView(selection: Binding(
            get: { model.activeTab },
            set: { model.activeTab = $0 }
        )) {
            ForEach(CairnTab.all, id: \.self) { tab in
                pageContent(for: tab).tag(tab)
            }
        }
        #if canImport(UIKit)
        tabs.tabViewStyle(.page(indexDisplayMode: .never))
        #else
        tabs
        #endif
    }

    private var mainTabs: some View {
        VStack(spacing: 0) {
            paginatedTabView
                .ignoresSafeArea(.keyboard, edges: .bottom)

            CairnTabBar(
                active: Binding(
                    get: { model.activeTab },
                    set: { model.activeTab = $0 }
                ),
                onReselect: { tab in
                    scrollResetTokens[tab.id, default: 0] += 1
                }
            )
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .task {
            // Cold-launch catch-up sync when main tabs first appear, so
            // library/run data replaces the empty defaults. Routed through
            // the same stale-gated path as warm foreground re-entry, so the
            // two are consistent. Only fires when the initial scan is
            // complete (a user who hit "Skip for now" lands on main tabs
            // without silently starting the scan they declined).
            maybeForegroundAutoSync()
        }
        // Scene-phase driven, in ONE observer so the cancel and the
        // catch-up sync are ordered, not two separate onChange callbacks
        // racing on the same render:
        //   - entering .background  → cleanly abandon any in-flight sync
        //     (it can't progress while suspended; suspend→resume produced
        //     the "20-minute" zombie). Fires at background time.
        //   - returning to .active from background → stale-gated catch-up,
        //     same path as a cold launch, so warm/cold reopens match.
        // `.inactive` (Control Center, app switcher) is ignored, so a peek
        // that never reached background doesn't sync or cancel anything.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                wasBackgrounded = true
                cleanCancelSyncForBackground()
            case .active:
                if wasBackgrounded {
                    wasBackgrounded = false
                    maybeForegroundAutoSync()
                }
            default:
                break
            }
        }
    }

    /// Foreground catch-up sync, shared by cold launch and warm reopen.
    /// Stale-gated so reopening within `foregroundAutoSyncStaleSeconds` of
    /// a *successful* sync doesn't re-sync, and guarded so it never stacks
    /// on an in-flight run.
    private static let foregroundAutoSyncStaleSeconds: TimeInterval = 300

    private func maybeForegroundAutoSync() {
        guard model.hasCompletedInitialScan, !model.isSyncing else { return }
        if let last = model.lastSyncSucceededAt,
           Date().timeIntervalSince(last) < Self.foregroundAutoSyncStaleSeconds {
            return
        }
        startTrackedSync(suppressErrors: true)
    }

    /// Clean-abandon an in-flight foreground sync on backgrounding. NOT a
    /// pause: a foreground sync can't progress while iOS suspends the
    /// process, and the suspend→resume of one is what produced the
    /// "20-minute" zombie runs. No `pausedSyncElapsedSeconds`, and
    /// `lastSyncSucceededAt` isn't advanced, so the next foreground
    /// catch-up still fires; requestSync's cancel handler restores the
    /// prior "last sync" narration.
    private func cleanCancelSyncForBackground() {
        guard model.isSyncing else { return }
        model.isSyncing = false
        model.syncStartedAt = nil
        model.pausedSyncElapsedSeconds = nil
        model.transitionSyncPhase(to: .idle)
        activeSyncTask?.cancel()
    }

    /// Spawn `requestSync` as a tracked Task so the UI can cancel it.
    /// Any prior in-flight sync is cancelled first — the Review & sync
    /// button is disabled while syncing, so in practice this just
    /// guards the auto-sync vs manual-sync race. `onComplete` fires
    /// after the sync finishes (success, error, or cancel) on MainActor.
    private func startTrackedSync(suppressErrors: Bool = false, onComplete: @escaping @MainActor () -> Void = {}) {
        activeSyncTask?.cancel()
        let task = Task { @MainActor in
            let errorBefore = model.lastError
            try? await model.actions.requestSync(nil)
            // Suppress an error THIS auto-sync newly surfaced, but only
            // then. The old unconditional `lastError = errorBefore`
            // resurrected an alert the user dismissed mid-sync (dismissal
            // sets lastError = nil, which this restored), and it also
            // blocked a successful sync from clearing a now-stale error.
            // Reverting only a new, non-nil error fixes both.
            if suppressErrors, model.lastError != nil, model.lastError != errorBefore {
                model.lastError = errorBefore
            }
            onComplete()
        }
        activeSyncTask = task
    }

    private func cancelActiveSync() {
        // Optimistic UI: flip the visible scan state to stopped/paused
        // *immediately* on tap, then send the cancellation signal.
        // The actual reconciler unwind is asynchronous and best-effort
        // — PhotoKit's `cancelDataRequest` waits for the in-flight
        // network buffer to drain on large iCloud transfers, and the
        // metadata loop checks cancellation every 50 iterations. None
        // of that should keep the user waiting.
        //
        // Any per-asset hashes that complete during the unwind window
        // still persist to LocalHashStore — the cache continues to
        // accrete, the resume picks up from a slightly-better baseline,
        // no work is lost. The `onHashProgress` callback in
        // `AppDependencies` guards on `isSyncing` so the visible
        // counter doesn't keep ticking after the user thinks they
        // stopped.
        //
        // Idempotency: the AppDependencies catch handler checks
        // `syncStartedAt` before updating state — if we've already
        // nil'd it here, the catch handler skips its update. So the
        // "user-tapped-cancel" and "BG-expired-cancel" paths don't
        // step on each other.
        if let started = model.syncStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            model.pausedSyncElapsedSeconds = max(0, elapsed)
        }
        model.syncStartedAt = nil
        model.isSyncing = false
        model.transitionSyncPhase(to: .idle)
        // Drop any in-flight hash rows now rather than leaving them to
        // linger (hidden, but stale) until the next sync's narration
        // reset. With isSyncing now false, applyHashEvent won't re-add.
        model.inFlightHashes.removeAll(keepingCapacity: true)
        activeSyncTask?.cancel()
    }

    @ViewBuilder
    private func pageContent(for tab: CairnTab) -> some View {
        switch tab.id {
        case "status":
            StatusScreen(
                appState: model.appState,
                degraded: model.degraded,
                library: model.library,
                runs: model.runs,
                journalTail: model.journalTail,
                serverHost: model.serverHost,
                maxDeletePercent: model.settings.maxDeletePercent,
                minDeleteFloor: model.settings.minDeleteFloor,
                // `pendingReviewCandidates` already *includes*
                // `heldByQuarantineCandidates` — the engine
                // populates the held array as a subset (see the
                // doc comment on `ReconciliationOutput`). Summing
                // them here double-counts every held item, which
                // surfaced as "Pending review: 2" on Status while
                // the screen itself shows 1. Use the superset
                // alone, plus recycled-exclusion candidates which
                // are routed into pending review separately (see
                // `case .pendingReview` below).
                pendingReviewCount: {
                    let r = model.reconciliation
                    let pending = r?.pendingReviewCandidates ?? []
                    let pendingChecksums = Set(pending.map(\.checksum))
                    let recycledExtra = (r?.recycledExclusionCandidates ?? [])
                        .filter { !pendingChecksums.contains($0.checksum) }
                    return pending.count + recycledExtra.count
                }(),
                quarantineCount: quarantineCountForStatus,
                earliestQuarantineEligible: earliestQuarantineEligible,
                deletionBacklog: backlogCount,
                backlogAlertThreshold: model.settings.deletionBacklogAlertThreshold,
                syncToast: model.syncToast,
                restoredAfterCairnTrashCount: model.restoredAfterCairnTrash.count,
                onDismissRestoredAfterCairnTrash: {
                    model.restoredAfterCairnTrash = [:]
                },
                inferredOrphanCount: model.inferredOrphanCount,
                onOpenInferredOrphans: {
                    model.presentedSheet = .pendingReview
                },
                initialScanPending: !model.hasCompletedInitialScan && !model.isSyncing,
                isSyncing: model.isSyncing,
                syncProgress: model.syncProgress.map { (hashed: $0.hashed, total: $0.total) },
                lastCheckedAt: model.reconciliation?.computedAt ?? model.lastCheckedAt,
                missingPermissions: model.missingPermissions,
                indexed: model.library.indexed,
                syncPhase: model.syncPhase,
                serverAssetsFetched: model.serverAssetsFetched,
                serverAssetsExpected: model.serverAssetsExpected,
                onStartSync: {
                    presentDryRunSheet(forceTripped: model.appState == .thresholdTripped)
                },
                onRefreshSync: {
                    // Pull-to-refresh: kick the tracked sync, then
                    // wait just long enough for the sync card to
                    // expand and assume the "we're working" visual
                    // role. Returning early dismisses SwiftUI's
                    // refresh-control spinner so we don't have two
                    // spinners (system + sync card's PlayfulSyncIcon)
                    // running concurrently. `suppressErrors: true`
                    // keeps a refresh-initiated failure from popping
                    // a dialog — the Status screen's degraded banner
                    // is the right surface for any error state.
                    startTrackedSync(suppressErrors: true)
                    try? await Task.sleep(for: .milliseconds(400))
                },
                onCancelSync: {
                    cancelActiveSync()
                },
                onOpenRun: { run in
                    presentRunDetail(for: run)
                },
                onJournalRowTap: { runId in
                    // Map the journal-row's runId back to the
                    // matching RunFixture. Rows with no match are
                    // already non-tappable upstream, but guard anyway
                    // in case the runs list is mid-refresh.
                    if let run = model.runs.first(where: { $0.id == runId }) {
                        presentRunDetail(for: run)
                    }
                },
                onSeeAllRuns: {
                    model.activeTab = .runs
                },
                onOpenPendingReview: {
                    acknowledgeCurrentCandidates()
                    model.presentedSheet = .pendingReview
                },
                onOpenDeleteQueue: {
                    acknowledgeCurrentCandidates()
                    model.presentedSheet = .dryRun(forceTripped: model.appState == .thresholdTripped)
                },
                onOpenDeferredQueue: {
                    Task { @MainActor in
                        let entries = (try? await model.actions.loadDeferredEntries()) ?? []
                        model.deferredQueueEntries = entries
                        model.presentedSheet = .deferredQueue
                    }
                },
                onResumeInitialScan: {
                    // Route back to the initial-scan screen. The
                    // screen's CTA will be "Start indexing" or
                    // "Resume indexing" depending on whether any
                    // progress is already cached.
                    model.hasDismissedInitialScan = false
                },
                deferredQueue: model.deferredQueue,
                onForceDrainDeferred: {
                    activeSyncTask?.cancel()
                    activeSyncTask = Task { @MainActor in
                        await model.actions.forceDrainDeferred()
                    }
                },
                pendingTrashCount: model.pendingTrashCount,
                pendingTrashStuckCount: model.pendingTrashStuckCount,
                onRetryPendingTrashes: {
                    Task { @MainActor in
                        model.isRetryingPendingTrashes = true
                        defer { model.isRetryingPendingTrashes = false }
                        await model.actions.retryPendingTrashes()
                    }
                },
                isRetryingPendingTrashes: model.isRetryingPendingTrashes,
                onOpenPendingTrashes: {
                    Task { @MainActor in
                        let intents = await model.actions.loadPendingTrashes()
                        model.pendingTrashIntents = intents
                        model.presentedSheet = .pendingTrashes
                    }
                },
                onRetryConnection: {
                    Task { @MainActor in await model.actions.retryConnection() }
                },
                onOpenSyncDetail: {
                    model.presentedSheet = .syncDetail
                },
                hasLastSyncDetails: !model.syncTimeline.isEmpty,
                onResumeSession: {
                    model.presentedSheet = .sessionSignIn
                },
                scrollResetToken: scrollResetTokens["status"] ?? 0
            )
        case "runs":
            RunsScreen(
                runs: model.runs,
                now: Date(),
                onOpenRun: { run in
                    presentRunDetail(for: run)
                },
                onStartSync: { model.activeTab = .status },
                scrollResetToken: scrollResetTokens["runs"] ?? 0
            )
        case "settings":
            SettingsScreen(
                settings: $model.settings,
                serverUrl: model.serverHost,
                apiKey: model.apiKey,
                apiKeyMasked: model.apiKeyMasked,
                excludedCount: model.excludedEntries.count,
                connectionStatus: model.connectionStatus,
                serverVersion: model.serverVersion,
                serverVersionAdvisory: model.serverVersionAdvisory,
                onRefreshConnection: { Task { @MainActor in await model.actions.retryConnection() } },
                onOpenExcluded: { model.settingsRoute = .excluded },
                onResetIndex: { Task { await model.actions.resetIndex() } },
                onResetIndexAllAccounts: { Task { await model.actions.resetIndexAllAccounts() } },
                onClearJournal: { Task { await model.actions.clearJournal() } },
                onClearJournalAllKeys: { Task { await model.actions.clearJournalAllKeys() } },
                onClearExclusions: { Task { await model.actions.clearExclusions() } },
                onClearRecentServers: { Task { await model.actions.clearRecentServers() } },
                onSignOut: { Task { await model.actions.signOut() } },
                onReplaceAPIKey: { newKey in await model.actions.replaceAPIKey(newKey) },
                onRescanLibrary: { Task { await model.actions.rescanLibrary() } },
                onClearHashCache: { Task { await model.actions.clearHashCache() } },
                onVerifyImputedChecksums: { Task { await model.actions.verifyImputedChecksums() } },
                library: model.library,
                deferredQueue: model.deferredQueue,
                onForceDrainDeferred: {
                    // Track the drain as the active sync task — same as the
                    // Status-screen force-drain — so the Cancel control
                    // (cancelActiveSync) actually stops it. Untracked, a
                    // Settings-launched drain kept doing unlimited-mode
                    // iCloud downloads after the user tapped Cancel, with
                    // every progress update suppressed (the isSyncing guard
                    // in onHashProgress), so the UI read "stopped" while the
                    // work ground on invisibly.
                    activeSyncTask?.cancel()
                    activeSyncTask = Task { @MainActor in
                        await model.actions.forceDrainDeferred()
                    }
                },
                isSyncing: model.isSyncing,
                syncProgress: model.syncProgress.map { (hashed: $0.hashed, total: $0.total) },
                onReplayOnboarding: { Task { await model.actions.replayOnboarding() } },
                onExportData: { scope in
                    Task { @MainActor in
                        model.isTransferringData = true
                        defer { model.isTransferringData = false }
                        do {
                            let url = try await model.actions.exportData(scope)
                            exportedFileURL = url
                        } catch {
                            model.lastError = "Export failed: \(error.localizedDescription)"
                        }
                    }
                },
                onImportData: { url, applySettings in
                    Task { @MainActor in
                        model.isTransferringData = true
                        defer { model.isTransferringData = false }
                        do {
                            let result = try await model.actions.importData(url, applySettings)
                            importResult = result
                        } catch {
                            model.lastError = "Import failed: \(error.localizedDescription)"
                        }
                    }
                },
                onOpenAlbumPicker: { model.presentedSheet = .albumPicker },
                onOpenMissedDeletions: {
                    // Open the sheet idle — the user picks a date range
                    // and taps Start scan. Avoids an immediate full-
                    // library scan with default bounds the user may not
                    // want.
                    model.missedDeletionsState = .idle
                    model.presentedSheet = .missedDeletions
                },
                onFireBackgroundRefresh: {
                    Task { await model.actions.simulateBackgroundRefresh() }
                },
                onOpenSessionSignIn: { model.presentedSheet = .sessionSignIn },
                onSignOutSession: {
                    Task { await model.actions.signOutSession() }
                },
                onExportDiagnosticLogs: exportDiagnosticLogsAction,
                onInspectAssetByFilename: { filename in
                    Task { await model.actions.inspectAssetByFilename(filename) }
                },
                loadArchivedHistory: model.actions.loadArchivedHistory,
                hasSessionToken: model.hasSessionToken,
                credentialsTravelInBackups: model.credentialsTravelInBackups,
                onSetCredentialsTravelInBackups: { enabled in
                    Task { @MainActor in
                        await model.actions.setCredentialsTravelInBackups(enabled)
                    }
                },
                isTransferringData: model.isTransferringData,
                scrollResetToken: scrollResetTokens["settings"] ?? 0,
                photoAuthStatus: model.photoAuthStatus
            )
        default:
            EmptyView()
        }
    }

    // MARK: - Sheet content

    @ViewBuilder
    private func sheetContent(for sheet: CairnAppModel.PresentedSheet) -> some View {
        switch sheet {
        case .dryRun(let forceTripped):
            // Bind against live reconciliation when present. Previews get a
            // fixture fallback only when running under Xcode's preview
            // runtime (checked via the canonical env var); production runs
            // show whatever the host actually computed — even if that's an
            // empty list. This kills the "15 fake candidates on first sync"
            // bug where a nil fallback leaked fixture data into a real
            // install.
            let candidates: [CairnFixtures.CandidateFixture] = {
                if let live = model.reconciliation {
                    return live.deleteCandidates.map(CairnFixtures.CandidateFixture.from)
                }
                if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                    return CairnFixtures.candidates
                }
                return []
            }()
            DryRunSheet(
                candidates: candidates,
                library: model.library,
                maxDeletePercent: model.settings.maxDeletePercent,
                minDeleteFloor: model.settings.minDeleteFloor,
                forceTripped: forceTripped,
                photoAccessIsFull: model.photoAuthStatus == .full,
                onClose: { model.presentedSheet = nil },
                onConfirm: {
                    try? await model.actions.confirmTrash()
                }
            )
            .cairnTheme(palette)
        case .runDetail(let run, let assets):
            RunDetailSheet(
                run: run,
                assets: assets,
                excludedChecksums: model.excludedChecksums,
                onClose: { model.presentedSheet = nil },
                onExclude: { picks in
                    // Split the selection into the parallel arrays the
                    // action expects: checksums for the store, filenames
                    // for the journal event. Candidates without a
                    // checksum (synthetic preview fixtures, or journal
                    // rows that predate checksum capture) are dropped
                    // from the store write — silently skipping is
                    // preferable to inserting a garbage key that never
                    // matches on future reconciles.
                    let checksums = picks.compactMap(\.checksum)
                    let names = picks.map(\.name)
                    Task { @MainActor in
                        try? await model.actions.exclude(checksums, names, run.id)
                    }
                },
                onUnexclude: { picks in
                    let checksums = picks.compactMap(\.checksum)
                    Task { @MainActor in
                        try? await model.actions.unexclude(checksums)
                    }
                },
                onRestore: { picks in
                    let assetIds = picks.compactMap(\.assetId)
                    Task { @MainActor in
                        try? await model.actions.restore(assetIds, run.id)
                    }
                },
                serverURL: model.serverURL
            )
            .cairnTheme(palette)
        case .pendingReview:
            let heldAssets = model.reconciliation?.heldByQuarantineCandidates ?? []
            let heldChecksumSet = Set(heldAssets.map(\.checksum))
            // Recycled-exclusion candidates fold into the unconfirmed
            // bucket: the user previously excluded these (typically via
            // restore-via-cairn auto-exclude) but a fresh confirmed-
            // delete signal post-dates the exclusion. Surfacing them in
            // the standard review flow lets the user trash (which
            // clears the exclusion automatically — see
            // AppDependencies.approvePending) or re-exclude (which
            // bumps `addedAt`, breaking the cycle-detection condition).
            let recycled = model.reconciliation?.recycledExclusionCandidates ?? []
            let unconfirmedFromEngine = (model.reconciliation?.pendingReviewCandidates ?? [])
                .filter { !heldChecksumSet.contains($0.checksum) }
            let unconfirmedSet = Set(unconfirmedFromEngine.map(\.checksum))
            let unconfirmedAssets = unconfirmedFromEngine
                + recycled.filter { !heldChecksumSet.contains($0.checksum) && !unconfirmedSet.contains($0.checksum) }
            PendingReviewScreen(
                heldAssets: heldAssets,
                unconfirmedAssets: unconfirmedAssets,
                firstObservedAnchors: model.reconciliation?.firstObservedAnchors ?? [],
                confirmedDeletedAt: model.reconciliation?.confirmedDeletedAt ?? [:],
                sourceLocalIdentifiersByChecksum: model.reconciliation?.sourceLocalIdentifiersByChecksum ?? [:],
                quarantineDays: model.reconciliation?.quarantineDays ?? model.settings.quarantineDays,
                massOffloadCount: model.lastScanBurstCount,
                showsMassOffloadBanner: model.lastScanLooksLikeMassOffload,
                showsTokenExpiryBanner: model.lastScanWasTokenExpiryFullEnum,
                recycledExclusionCount: recycled.count,
                onBack: { model.presentedSheet = nil },
                onApprove: { checksums in
                    Task { @MainActor in
                        try? await model.actions.approvePending(checksums)
                    }
                },
                onExclude: { checksums in
                    Task { @MainActor in
                        try? await model.actions.excludePending(checksums)
                    }
                },
                onDismiss: { checksums in
                    Task { @MainActor in
                        try? await model.actions.dismissPending(checksums)
                    }
                },
                onBulkExcludeOffload: {
                    Task { @MainActor in
                        try? await model.actions.bulkExcludeRecentOffload()
                    }
                }
            )
            .cairnTheme(palette)
        case .deferredQueue:
            let ceilingMB = model.settings.iCloudMaxEverBytesMB
            let ceilingBytes: Int64? = ceilingMB.flatMap { $0 > 0 ? Int64($0) * 1024 * 1024 : nil }
            DeferredQueueSheet(
                entries: model.deferredQueueEntries,
                ceilingBytes: ceilingBytes,
                onClose: { model.presentedSheet = nil }
            )
            .cairnTheme(palette)
        case .albumPicker:
            AlbumPickerSheet(
                initialSelection: model.settings.indexingScope.albumLocalIdentifiers,
                onClose: { model.presentedSheet = nil },
                onSave: { selection in
                    // Persist the picker's resulting selection back into
                    // settings. Even an empty set is a valid (degraded)
                    // state — the IndexingScope row's helper text guides
                    // the user to pick at least one album.
                    model.settings.indexingScope = .selectedAlbums(selection)
                }
            )
            .cairnTheme(palette)
        case .syncDetail:
            SyncDetailSheet(
                phase: model.syncPhase,
                syncStartedAt: model.syncStartedAt,
                isSyncing: model.isSyncing,
                progress: model.syncProgress.map { (hashed: $0.hashed, total: $0.total) },
                timeline: model.syncTimeline,
                activity: model.syncActivity,
                spotlightedHash: model.spotlightedHash,
                timeFormat: model.settings.timeDisplayFormat,
                onCancel: {
                    cancelActiveSync()
                    model.presentedSheet = nil
                },
                onClose: { model.presentedSheet = nil }
            )
            .cairnTheme(palette)
        case .pendingTrashes:
            PendingTrashesSheet(
                intents: model.pendingTrashIntents,
                maxRetryAttempts: model.settings.maxRetryAttempts,
                onClose: { model.presentedSheet = nil },
                onRetryAll: {
                    Task { @MainActor in
                        await model.actions.retryPendingTrashes()
                        // Refresh in place so the sheet reflects the
                        // post-drain state without forcing a close.
                        model.pendingTrashIntents = await model.actions.loadPendingTrashes()
                    }
                },
                onDiscard: { id in
                    Task { @MainActor in
                        await model.actions.discardPendingTrash(id)
                        // Refresh in place so the row disappears
                        // without forcing a sheet close.
                        model.pendingTrashIntents = await model.actions.loadPendingTrashes()
                    }
                }
            )
            .cairnTheme(palette)
        case .missedDeletions:
            MissedDeletionsSheet(
                state: model.missedDeletionsState,
                onClose: {
                    model.presentedSheet = nil
                    model.missedDeletionsState = .idle
                },
                onScan: { minCreatedAt, maxCreatedAt, strictHistorical in
                    model.missedDeletionsState = .scanning
                    Task { @MainActor in
                        do {
                            let assets = try await model.actions.findMissedDeletions(minCreatedAt, maxCreatedAt, strictHistorical)
                            model.missedDeletionsState = .loaded(assets)
                        } catch {
                            model.missedDeletionsState = .error(error.localizedDescription)
                        }
                    }
                },
                onTrash: { assets in
                    Task { @MainActor in
                        do {
                            try await model.actions.trashMissedDeletions(assets)
                            // Drop the trashed ones from the list rather
                            // than re-scanning — re-scan would touch the
                            // network again and could race the server's
                            // trash propagation.
                            let trashedIds = Set(assets.map(\.id))
                            if case .loaded(let current) = model.missedDeletionsState {
                                let remaining = current.filter { !trashedIds.contains($0.id) }
                                model.missedDeletionsState = .loaded(remaining)
                            }
                        } catch {
                            model.missedDeletionsState = .error(error.localizedDescription)
                        }
                    }
                },
                onKeep: { assets in
                    Task { @MainActor in
                        let checksums = assets.map { $0.checksum.base64 }
                        let filenames = assets.compactMap(\.originalFileName)
                        let recoveryRunId = "recovery-\(ISO8601DateFormatter().string(from: Date()))"
                        try? await model.actions.exclude(checksums, filenames, recoveryRunId)
                        let keptIds = Set(assets.map(\.id))
                        if case .loaded(let current) = model.missedDeletionsState {
                            let remaining = current.filter { !keptIds.contains($0.id) }
                            model.missedDeletionsState = .loaded(remaining)
                        }
                    }
                },
                onDismissOne: { _ in }
            )
            .cairnTheme(palette)
        case .sessionSignIn:
            SessionSignInSheet(
                signIn: { email, password in
                    await model.actions.signInForSession(email, password)
                },
                loadRecentEmails: { await model.actions.recentSessionEmails() },
                onDismiss: { model.presentedSheet = nil }
            )
            .cairnTheme(palette)
            // Sheet auto-dismisses when the host flips
            // hasSessionToken (signed in OR signed out from another
            // surface). Keeps the form state from getting stale.
            .onChange(of: model.hasSessionToken) { _, newValue in
                if newValue {
                    model.presentedSheet = nil
                }
            }
        }
    }

    // MARK: - Sheet helpers

    /// Stamp `model.acknowledgedCandidateChecksums` with whatever's
    /// currently in the candidate buckets. Called from both the
    /// auto-present path and the manual-navigation paths
    /// (`onOpenPendingReview`, `onOpenDeleteQueue`) so a user who
    /// drills in manually is treated identically to one whose Sync
    /// auto-popped the same dialog: subsequent Sync taps don't
    /// re-pop unless something genuinely new comes in.
    private func acknowledgeCurrentCandidates() {
        guard let live = model.reconciliation else { return }
        let checksums = Set(
            live.deleteCandidates.map(\.checksum.base64)
                + live.pendingReviewCandidates.map(\.checksum.base64)
        )
        model.acknowledgedCandidateChecksums = checksums
    }

    private func presentDryRunSheet(forceTripped: Bool) {
        // Run reconciliation first, then route based on what
        // came back. Post-sync outcomes:
        //
        //   1. `deleteCandidates` non-empty AND set has new items
        //      since the last auto-present → present DryRunSheet.
        //   2. Unconfirmed pending items (strict mode) AND new since
        //      last auto-present → PendingReview.
        //   3. Set is unchanged from what the user already saw → no
        //      auto-present (the user already decided once; tapping
        //      Sync to "check for new" shouldn't re-pop the same
        //      dialog they just dismissed). They can still navigate
        //      manually via the quarantine badge / "ready to trash"
        //      tap on Status.
        //   4. Only quarantine items → no auto-present; the quarantine
        //      badge in the sync card updates and the user taps in if
        //      they want to act.
        //   5. Both empty → no-op (Status toast handles feedback).
        startTrackedSync {
            let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            if isPreview {
                model.presentedSheet = .dryRun(forceTripped: forceTripped)
                return
            }
            guard let live = model.reconciliation else { return }

            // Decide whether the current candidate set has anything
            // the user hasn't been auto-shown yet. Subset-of-acknowledged
            // means "no new info" — skip the auto-pop. The Status
            // surfaces (ready-to-trash chip, quarantine line) update
            // their counts independently.
            let currentChecksums = Set(
                live.deleteCandidates.map(\.checksum.base64)
                    + live.pendingReviewCandidates.map(\.checksum.base64)
            )
            let hasNewSinceLastAutoPresent = !currentChecksums.isSubset(of: model.acknowledgedCandidateChecksums)

            if !live.deleteCandidates.isEmpty, hasNewSinceLastAutoPresent {
                model.presentedSheet = .dryRun(forceTripped: forceTripped)
                model.acknowledgedCandidateChecksums = currentChecksums
            } else if live.pendingReviewCandidates.count > live.heldByQuarantineCandidates.count, hasNewSinceLastAutoPresent {
                model.presentedSheet = .pendingReview
                model.acknowledgedCandidateChecksums = currentChecksums
            }
        }
    }

    private func presentRunDetail(for run: CairnFixtures.RunFixture) {
        // Real per-run asset list sourced from the journal's
        // `planningTrash` events, keyed by runId on `model.runAssets`
        // (populated at sync/trash time). Each fixture carries the
        // server-side asset UUID so `ImmichAssetThumb` fetches real
        // thumbnails rather than rendering placeholders.
        //
        // Fallback to `CairnFixtures.candidates` only for the
        // preview environment (no real journal) or for runs whose
        // journal entries predate this plumbing — e.g. aborted
        // runs never emit `planningTrash`, so they have no real
        // asset list to show.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let assets: [CairnFixtures.CandidateFixture] = {
            if let real = model.runAssets[run.id], !real.isEmpty {
                return real
            }
            guard isPreview else { return [] }
            if run.status == .aborted {
                return Array(CairnFixtures.candidates.prefix(14))
            }
            return Array(CairnFixtures.candidates.prefix(max(1, run.trashed)))
        }()
        model.presentedSheet = .runDetail(run, assets: assets)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("App — main (steady)") {
    CairnAppRoot(model: .preview())
}

#Preview("App — onboarding") {
    CairnAppRoot(model: .preview(needsOnboarding: true))
}

#Preview("App — threshold tripped") {
    CairnAppRoot(model: .preview(appState: .thresholdTripped))
}

#Preview("App — server down") {
    CairnAppRoot(model: .preview(degraded: .serverDown))
}

#Preview("App — dark") {
    CairnAppRoot(model: .preview())
        .preferredColorScheme(.dark)
}
#endif
