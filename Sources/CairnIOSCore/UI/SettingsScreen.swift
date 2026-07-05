import SwiftUI
import UniformTypeIdentifiers
import CairnCore

/// The settings root screen. Mirrors the prototype's `screens/settings.jsx`.
///
/// Section list (top-to-bottom):
///   1. Immich server — URL, API key (with Reveal/Hide + Copy + auto-hide),
///      connection status, session sign-in, and full disconnect.
///   2. Safety rails — percent threshold slider, count floor, dry-run toggle,
///      deletion-strictness picker, excluded-assets row.
///   3. Notifications — abort alerts, verbose journal.
///   4. Permissions — Photos access, background refresh.
///   5. Appearance — palette editor entry point.
///   6. Danger zone — reset index, clear journal, clear servers/exclusions.
///
/// Microcopy is verbatim from the prototype. The "Don't screenshot." warning
/// on API-key reveal is explicitly called out in HANDOFF.md as load-bearing —
/// don't paraphrase. See HANDOFF.md "Keep these copies verbatim."
///
/// The screen owns *no* persistent state of its own — it edits a `Binding` to
/// `CairnSettings` (so the iOS app layer can persist via `SettingsStore`) and
/// surfaces button taps as closures. Local UI state (Reveal toggle, "Copied"
/// flash) lives inside child views since it's strictly ephemeral.
public struct SettingsScreen: View {

    /// The connection-status pill the URL section terminates with. Mirrors
    /// the prototype's healthy/offline/auth-stale variants.
    public enum ConnectionStatus: Sendable, Equatable {
        case healthy(latencyMs: Int, checkedAt: Date = Date())
        case offline
        case authStale
    }

    @Binding public var settings: CairnSettings
    public let serverUrl: String
    public let apiKey: String
    public let apiKeyMasked: String
    public let excludedCount: Int
    public let connectionStatus: ConnectionStatus
    /// Immich server version + soft advisory (set when newer than the
    /// version cairn was verified against). Both nil until the bootstrap
    /// probe reads them, or on a server without /server/version.
    public let serverVersion: ServerVersion?
    public let serverVersionAdvisory: String?
    /// Triggers a re-ping of the configured server. Wired to a
    /// `.task` on the Connection sub-page so opening it always
    /// shows a fresh latency reading, and to other manual refresh
    /// affordances. No-op when no server is configured.
    public let onRefreshConnection: () -> Void
    public let onOpenExcluded: () -> Void
    public let onResetIndex: () -> Void
    public let onResetIndexAllAccounts: () -> Void
    public let onClearJournal: () -> Void
    public let onClearJournalAllKeys: () -> Void
    /// Wipe every entry in the active partition's `ExclusionStore`.
    /// Surgical — doesn't touch the index, journal, or credentials.
    /// Distinct from per-row unexclude on the Excluded screen.
    public let onClearExclusions: () -> Void
    /// Count of exclusions for the active partition, surfaced in the
    /// Settings row as the value label so the user can see what's
    /// about to be wiped before confirming. Same source as
    /// `excludedCount` above; kept as a separate prop for clarity.
    /// (Reuses `excludedCount` at render time.)
    /// Wipe the keychain-backed recent-servers autocomplete list.
    /// Doesn't touch credentials, journal, or index — surgical.
    public let onClearRecentServers: () -> Void
    public let onSignOut: () -> Void
    /// Rotate the API key in place (verify + swap, preserving index +
    /// history). Surfaced from the API-key sheet's "Replace key".
    public let onReplaceAPIKey: @Sendable (String) async -> CairnAppActions.ReplaceKeyResult
    public let onRescanLibrary: () -> Void
    public let onClearHashCache: () -> Void
    public let onVerifyImputedChecksums: () -> Void
    /// Library stats — used by the Initial scan section to surface
    /// the diagnostic counter (verified vs trust-seeded rows) and
    /// gate the "Re-hash imputed entries" action.
    public let library: CairnFixtures.LibrarySize
    public let deferredQueue: CairnAppModel.DeferredQueueSummary
    public let onForceDrainDeferred: () -> Void
    /// True while a sync or drain is mid-flight. Used to disable the
    /// "Hash now" button in the deferred-queue row so the user
    /// doesn't double-invoke, and to swap its label for a
    /// "Hashing…" hint since Settings has no other progress surface.
    public let isSyncing: Bool
    /// Optional live progress for the "Hash now" label — "Hashing 3 / 12"
    /// when a drain is running. `nil` outside an active drain.
    public let syncProgress: (hashed: Int, total: Int)?
    /// Dev-only hook: re-enters the SetupScreen flow without clearing
    /// credentials, so the onboarding screens can be reviewed without
    /// re-typing URL + API key. Surfaced under a DEBUG-gated Advanced row.
    public let onReplayOnboarding: () -> Void
    public let onExportData: (CairnExportScope) -> Void
    public let onImportData: (URL, Bool) -> Void
    /// Opens the album-picker sheet for `IndexingScope.selectedAlbums`.
    /// Host (CairnAppRoot) wires this to mutate `model.presentedSheet`
    /// and persist the picker's resulting selection back into settings.
    public let onOpenAlbumPicker: () -> Void
    /// Opens the Recovery sheet ("Find missed deletions"). Host
    /// (CairnAppRoot) sets `model.presentedSheet = .missedDeletions`
    /// and kicks off the scan.
    public let onOpenMissedDeletions: () -> Void
    /// DEBUG-only: trigger the BG refresh handler path without iOS
    /// scheduling. Surfaced as a row under Settings → Advanced when
    /// the build is Debug. In Release the closure is no-op + the row
    /// is `#if DEBUG`-gated.
    public let onFireBackgroundRefresh: () -> Void
    /// Opens the session sign-in sheet. Surfaced under Advanced when
    /// the user wants to enable `/sync/*` (which Immich rejects for
    /// API-key auth) — paired with `hasSessionToken` to choose
    /// "Sign in" vs "Sign out".
    public let onOpenSessionSignIn: () -> Void
    /// Drops the persisted session token. Wired to the "Sign out"
    /// row that appears when `hasSessionToken == true`.
    public let onSignOutSession: () -> Void
    /// Triggers a fresh on-device extraction of cairn's recent log
    /// lines into a `.txt` file and presents the system share sheet
    /// so the tester can email or AirDrop the file to support. The
    /// host (CairnAppRoot) drives the actual `LogExporter.export()`
    /// call + share sheet — this row just fires the closure.
    public let onExportDiagnosticLogs: () -> Void
    /// Triggers the "Inspect asset by filename" debug action. Host
    /// (CairnAppRoot) wires this to call
    /// `model.actions.inspectAssetByFilename(filename)` which dumps
    /// a side-by-side phone-vs-server view for the given filename
    /// into the persistent log, so the next diagnostic export shows
    /// which divergence axis is in play.
    public let onInspectAssetByFilename: (String) -> Void
    /// Loads the rotated-out journal history for the "View archived
    /// history" viewer. Host wires this to
    /// `model.actions.loadArchivedHistory`. Defaults to returning empty
    /// so previews / tests don't need to supply it.
    public let loadArchivedHistory: @Sendable () async -> [CairnFixtures.JournalTailEntry]
    /// `true` when a session-auth token is persisted in Keychain.
    /// Switches the row label between "Sign in" and "Signed in ·
    /// Sign out".
    public let hasSessionToken: Bool
    /// True while an export/import is in flight — drives a spinner on the
    /// Data rows and disables re-tapping.
    public let isTransferringData: Bool
    /// Token incremented by the host when the user re-taps the active
    /// tab — see `CairnTabBar.onReselect`. Each increment scrolls the
    /// screen back to the top.
    public let scrollResetToken: Int
    /// Live PhotoKit auth state. Drives the Permissions row's value
    /// label ("Full library" / "Selected photos" / "Denied") and a
    /// follow-up explanation when `.limited`. `nil` falls back to the
    /// legacy hardcoded "Full library" copy for previews and any host
    /// that doesn't supply a status.
    public let photoAuthStatus: SetupScreen.PhotoAuthOutcome?

    @Environment(\.cairnTokens) private var t
    @State private var pendingResetIndex: Bool = false
    @State private var pendingRescanLibrary: Bool = false
    @State private var pendingClearHashCache: Bool = false
    @State private var pendingVerifyImputed: Bool = false
    @State private var pendingClearJournal: Bool = false
    @State private var pendingClearRecentServers: Bool = false
    @State private var pendingClearExclusions: Bool = false
    @State private var howItWorksExpanded: Bool = false
    /// Search query bound to the NavigationStack's `.searchable`
    /// modifier. Empty string = show the regular root list; non-empty
    /// = render filtered search results in place.
    @State private var searchText: String = ""
    @State private var showExportPicker = false
    @State private var showImportPicker = false
    @State private var showAbout = false
    @State private var showInspectAssetAlert = false
    @State private var showArchivedHistory = false
    @State private var showApiKeyDetail = false
    @State private var inspectAssetFilename: String = ""

    /// Extracted from the alert closure to relieve type-checker
    /// pressure — the SettingsScreen body has a long stack of
    /// `.alert` modifiers and inlining one more pushes the implicit
    /// `some View` resolution past Swift's reasonable-time budget.
    @ViewBuilder
    private var inspectAssetAlertActions: some View {
        TextField("e.g. IMG_1234.MOV", text: $inspectAssetFilename)
            .autocorrectionDisabled()
        Button("Inspect") {
            let trimmed = inspectAssetFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onInspectAssetByFilename(trimmed)
            inspectAssetFilename = ""
        }
        Button("Cancel", role: .cancel) { inspectAssetFilename = "" }
    }

    @ViewBuilder
    private var inspectAssetAlertMessage: some View {
        Text("Dumps every phone-side PHAsset and Immich server entry matching this filename to the diagnostic log. Then export logs (above) to share for triage. Case-insensitive match against PHAsset's internal filename + every PHAssetResource originalFilename.")
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        settings: Binding<CairnSettings>,
        serverUrl: String,
        apiKey: String,
        apiKeyMasked: String,
        excludedCount: Int,
        connectionStatus: ConnectionStatus,
        serverVersion: ServerVersion? = nil,
        serverVersionAdvisory: String? = nil,
        onRefreshConnection: @escaping () -> Void = {},
        onOpenExcluded: @escaping () -> Void = {},
        onResetIndex: @escaping () -> Void = {},
        onResetIndexAllAccounts: @escaping () -> Void = {},
        onClearJournal: @escaping () -> Void = {},
        onClearJournalAllKeys: @escaping () -> Void = {},
        onClearExclusions: @escaping () -> Void = {},
        onClearRecentServers: @escaping () -> Void = {},
        onSignOut: @escaping () -> Void = {},
        onReplaceAPIKey: @escaping @Sendable (String) async -> CairnAppActions.ReplaceKeyResult = { _ in .success },
        onRescanLibrary: @escaping () -> Void = {},
        onClearHashCache: @escaping () -> Void = {},
        onVerifyImputedChecksums: @escaping () -> Void = {},
        library: CairnFixtures.LibrarySize = .empty,
        deferredQueue: CairnAppModel.DeferredQueueSummary = .empty,
        onForceDrainDeferred: @escaping () -> Void = {},
        isSyncing: Bool = false,
        syncProgress: (hashed: Int, total: Int)? = nil,
        onReplayOnboarding: @escaping () -> Void = {},
        onExportData: @escaping (CairnExportScope) -> Void = { _ in },
        onImportData: @escaping (URL, Bool) -> Void = { _, _ in },
        onOpenAlbumPicker: @escaping () -> Void = {},
        onOpenMissedDeletions: @escaping () -> Void = {},
        onFireBackgroundRefresh: @escaping () -> Void = {},
        onOpenSessionSignIn: @escaping () -> Void = {},
        onSignOutSession: @escaping () -> Void = {},
        onExportDiagnosticLogs: @escaping () -> Void = {},
        onInspectAssetByFilename: @escaping (String) -> Void = { _ in },
        loadArchivedHistory: @escaping @Sendable () async -> [CairnFixtures.JournalTailEntry] = { [] },
        hasSessionToken: Bool = false,
        isTransferringData: Bool = false,
        scrollResetToken: Int = 0,
        photoAuthStatus: SetupScreen.PhotoAuthOutcome? = nil
    ) {
        self._settings = settings
        self.serverUrl = serverUrl
        self.apiKey = apiKey
        self.apiKeyMasked = apiKeyMasked
        self.excludedCount = excludedCount
        self.connectionStatus = connectionStatus
        self.serverVersion = serverVersion
        self.serverVersionAdvisory = serverVersionAdvisory
        self.onRefreshConnection = onRefreshConnection
        self.onOpenExcluded = onOpenExcluded
        self.onResetIndex = onResetIndex
        self.onResetIndexAllAccounts = onResetIndexAllAccounts
        self.onClearJournal = onClearJournal
        self.onClearJournalAllKeys = onClearJournalAllKeys
        self.onClearExclusions = onClearExclusions
        self.onClearRecentServers = onClearRecentServers
        self.onSignOut = onSignOut
        self.onReplaceAPIKey = onReplaceAPIKey
        self.onRescanLibrary = onRescanLibrary
        self.onClearHashCache = onClearHashCache
        self.onVerifyImputedChecksums = onVerifyImputedChecksums
        self.library = library
        self.deferredQueue = deferredQueue
        self.onForceDrainDeferred = onForceDrainDeferred
        self.isSyncing = isSyncing
        self.syncProgress = syncProgress
        self.onReplayOnboarding = onReplayOnboarding
        self.onExportData = onExportData
        self.onImportData = onImportData
        self.onOpenAlbumPicker = onOpenAlbumPicker
        self.onOpenMissedDeletions = onOpenMissedDeletions
        self.onFireBackgroundRefresh = onFireBackgroundRefresh
        self.onOpenSessionSignIn = onOpenSessionSignIn
        self.onSignOutSession = onSignOutSession
        self.onExportDiagnosticLogs = onExportDiagnosticLogs
        self.onInspectAssetByFilename = onInspectAssetByFilename
        self.loadArchivedHistory = loadArchivedHistory
        self.hasSessionToken = hasSessionToken
        self.isTransferringData = isTransferringData
        self.scrollResetToken = scrollResetToken
        self.photoAuthStatus = photoAuthStatus
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.scrollTopAnchor)
                        if searchText.isEmpty {
                            quickSettingsCard
                            rootList
                            footer
                        } else {
                            searchResults
                        }
                    }
                }
                .onChange(of: scrollResetToken) { _, _ in
                    withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                    }
                }
            }
            .navigationTitle("Settings")
            .cairnNavigationTitleDisplayMode(.large)
            .background(t.bg)
            // Value-based navigation destination for search results.
            // Closure-form NavigationLinks (used by SettingsCategoryRow
            // on the root list) interleave destination body computation
            // with the push animation, which on a page with several
            // sections produces a visible "partial render → brief lag
            // → full populate" stagger when tapped from a .searchable
            // result (where the search-dismiss animation runs at the
            // same time). Registering `.navigationDestination(for:)`
            // lets SwiftUI build the destination off the animation
            // critical path so the push reads as smooth.
            .navigationDestination(for: SettingsPage.self) { page(for: $0) }
            // Search bar at the navigation stack root. Default
            // placement = `.automatic` resolves to the search drawer
            // under the large title on iOS. Skipping the iOS-only
            // `.navigationBarDrawer` placement so the same source
            // compiles for macOS tooling / preview builds too.
            .searchable(text: $searchText, prompt: "Search settings")
            // Keyboard dismissal: drag down on the list to interactively
            // drag the keyboard away, or tap any empty chrome outside
            // the focused field. Together these replace the explicit
            // keyboard-toolbar Done button, which rendered awkwardly
            // on iOS 26.
            .scrollDismissesKeyboard(.interactively)
            .cairnDismissKeyboardOnBackgroundTap()
        }
        // Alerts / sheets / fileImporters are attached to the
        // NavigationStack itself rather than to the root content,
        // so they present from a layer that's above the navigation
        // push. Previously, attaching them to the inner ScrollView
        // meant their triggers from inside a pushed sub-page (e.g.
        // tapping "Export data" on Data & recovery) silently queued
        // until the user popped back to the root — visible bug.
        // Destructive confirmations use `.alert` (centered modal) not
        // `.confirmationDialog` — on iOS 26 / Liquid Glass, the latter
        // adapts to a popover with an arrow that anchors to a near-
        // arbitrary source view, which reads as visual chaos. Alerts
        // are always centered, no anchor, unambiguous.
        .alert(
            "Reset index?",
            isPresented: $pendingResetIndex,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("This account", role: .destructive) { onResetIndex() }
                Button("All accounts on this device", role: .destructive) { onResetIndexAllAccounts() }
            },
            message: {
                Text("This account: clears the SHA1 cache, change-tracking baseline, observed set, and quarantine state for the active Immich account. Exclusions, credentials, and saved servers are kept; the next sync re-hashes your library.\n\nAll accounts: also wipes every other (URL, user) partition cairn has cached on this device, plus the active account's exclusions and the saved-servers list. Use after a shared/dev-device cleanup.")
            }
        )
        .alert(
            "Rescan library?",
            isPresented: $pendingRescanLibrary,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Rescan") { onRescanLibrary() }
            },
            message: {
                Text("Clears the change-tracking baseline and deferred-hash queue. The next sync re-enumerates every photo against your current size limits. Use this after raising the iCloud limits to apply them immediately; otherwise background scans catch up on their own.")
            }
        )
        .alert(
            "Clear hash cache?",
            isPresented: $pendingClearHashCache,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearHashCache() }
            },
            message: {
                Text("Drops every cached SHA1 and the change-tracking baseline. The next sync re-hashes every photo (or imputes from server checksums if fast initial scan is on). Observed history, active quarantine, exclusions, and credentials are all kept. Useful for testing fast initial scan on an already-indexed library; otherwise rarely needed.")
            }
        )
        .alert(
            "Re-hash imputed entries?",
            isPresented: $pendingVerifyImputed,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Re-hash") { onVerifyImputedChecksums() }
            },
            message: {
                Text("Drops the \(library.imputed.formatted(.number)) trust-seeded SHA1\(library.imputed == 1 ? "" : "s") that cairn imported from Immich's server. The next sync re-hashes those photos locally — on iCloud-Optimized libraries this can take a while because each one's original needs to be downloaded. Locally verified rows are untouched. Use this if you want every checksum computed by cairn itself rather than trusted from the server.")
            }
        )
        .alert(
            "Clear journal?",
            isPresented: $pendingClearJournal,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("This key", role: .destructive) { onClearJournal() }
                Button("All keys (delete file)", role: .destructive) { onClearJournalAllKeys() }
            },
            message: {
                Text("This key: hides existing runs from the active API key's view. Other keys on this account still see their own history if you rotate back. The on-disk journal is preserved.\n\nAll keys: deletes deletion-journal.jsonl from disk. Past runs disappear from every key's view, permanently.")
            }
        )
        .alert(
            "Clear saved servers?",
            isPresented: $pendingClearRecentServers,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearRecentServers() }
            },
            message: {
                Text("Wipes the saved server URLs and sign-in emails used for autocomplete. Credentials, indexed state, journal, and exclusions are kept.")
            }
        )
        .alert(
            "Clear excluded assets?",
            isPresented: $pendingClearExclusions,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Clear all \(excludedCount)", role: .destructive) { onClearExclusions() }
            },
            message: {
                Text("Removes all \(excludedCount) excluded checksums for this account. The index, journal, credentials, and saved servers are kept. Excluded items will start flowing through reconciliation again on the next sync — including any that were previously preserved via restore-via-cairn.")
            }
        )
        // `.alert` rather than `.confirmationDialog` — on iOS 26 the
        // dialog adapts to a popover that anchors to whatever source
        // view SwiftUI picks, often unrelated to the tapped row. Same
        // reasoning as the destructive confirmations above.
        .alert(
            "Export scope",
            isPresented: $showExportPicker,
            actions: {
                Button("Current server") { onExportData(.currentServer) }
                Button("All servers") { onExportData(.allServers) }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Current server backs up only the active Immich account's state. All servers includes every (URL, user) partition on this device.")
            }
        )
        .alert(
            "Inspect asset by filename",
            isPresented: $showInspectAssetAlert,
            actions: { inspectAssetAlertActions },
            message: { inspectAssetAlertMessage }
        )
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    // applySettings: false — restore the cache / observed
                    // / exclusions / journal from the payload, but
                    // preserve the user's current in-app settings
                    // (toggles, thresholds, etc). Otherwise importing a
                    // backup made before any settings change reverts the
                    // user's UI state silently.
                    onImportData(url, false)
                case .failure:
                    break
                }
            }
        )
        .sheet(isPresented: $showAbout) {
            AboutSheet(onClose: { showAbout = false })
        }
        .sheet(isPresented: $showArchivedHistory) {
            ArchivedHistoryScreen(load: loadArchivedHistory)
        }
    }

    // MARK: - Root list

    /// Root settings list — a flat list of category rows that drill
    /// into sub-pages. Replaces the old long-scroll layout. Categories
    /// are grouped by user task ("what are you trying to do?") rather
    /// than by the underlying data model: Library is everything about
    /// what cairn watches; Safety & limits is everything about how
    /// aggressive it gets; Recovery is everything about getting back
    /// to a known-good state; etc.
    // MARK: - Search

    /// Sub-pages reachable from search results. Maps each entry's
    /// destination so the search row knows where to push.
    private enum SettingsPage {
        case connection
        case library
        case safetyLimits
        case appearance
        case dataAndRecovery
        case advanced
        case about
    }

    /// One indexed row. Title is the user-visible name; breadcrumb is
    /// the sub-page label rendered as a secondary line. Keywords are
    /// the alternate names users might type — synonyms, partial
    /// phrases, related concepts. Match is case-insensitive substring
    /// against title + keywords.
    private struct SearchEntry: Identifiable {
        let id: String
        let title: String
        let breadcrumb: String
        let keywords: [String]
        let page: SettingsPage
    }

    /// Flat index of every settable surface across all sub-pages.
    /// Keep in sync as new rows ship; missing entries here means the
    /// search bar won't find them. Title strings stay close to the
    /// row's actual label so a literal-match search ("strictness",
    /// "Reset index") works without typing keywords.
    private static let searchIndex: [SearchEntry] = [
        // Connection
        .init(id: "conn.url", title: "Immich server URL", breadcrumb: "Connection",
              keywords: ["url", "server", "host", "immich"], page: .connection),
        .init(id: "conn.apikey", title: "API key", breadcrumb: "Connection",
              keywords: ["api", "key", "token", "credential"], page: .connection),
        .init(id: "conn.status", title: "Connection status", breadcrumb: "Connection",
              keywords: ["latency", "ping", "healthy", "offline", "ms"], page: .connection),

        // Library
        .init(id: "lib.photos", title: "Photos access", breadcrumb: "Library",
              keywords: ["photokit", "permission", "limited", "denied", "full"], page: .library),
        .init(id: "lib.bgrefresh", title: "Background refresh", breadcrumb: "Library",
              keywords: ["background", "ios", "permission"], page: .library),
        .init(id: "lib.scope", title: "Indexing scope", breadcrumb: "Library",
              keywords: ["album", "albums", "selected albums", "full library"], page: .library),
        .init(id: "lib.fastscan", title: "Trust server checksums", breadcrumb: "Library",
              keywords: ["fast initial scan", "imputed", "trust", "filename match", "checksum"], page: .library),
        .init(id: "lib.cache", title: "Cache breakdown", breadcrumb: "Library",
              keywords: ["imputed", "verified", "hashed", "trust-seeded"], page: .library),
        .init(id: "lib.rehash", title: "Re-hash imputed entries", breadcrumb: "Library",
              keywords: ["verify", "rehash", "imputed", "trust-seeded"], page: .library),
        .init(id: "lib.excluded", title: "Excluded assets", breadcrumb: "Library",
              keywords: ["exclude", "protected", "exclusions"], page: .library),

        // Safety & limits
        .init(id: "safety.percent", title: "Percent threshold", breadcrumb: "Safety & limits",
              keywords: ["mass delete", "abort", "rail", "fraction"], page: .safetyLimits),
        .init(id: "safety.strictness", title: "Deletion strictness", breadcrumb: "Safety & limits",
              keywords: ["cautious", "balanced", "autonomous", "strict", "trusting", "auto"], page: .safetyLimits),
        .init(id: "safety.quarantine", title: "Quarantine window", breadcrumb: "Safety & limits",
              keywords: ["days", "hold", "aging", "quarantine"], page: .safetyLimits),
        .init(id: "safety.icloud", title: "iCloud download limit", breadcrumb: "Safety & limits",
              keywords: ["soft limit", "icloud", "mb"], page: .safetyLimits),
        .init(id: "safety.ceiling", title: "Never-touch ceiling", breadcrumb: "Safety & limits",
              keywords: ["hard ceiling", "never touch", "icloud", "mb"], page: .safetyLimits),
        .init(id: "safety.maxage", title: "Don't propagate old deletes", breadcrumb: "Safety & limits",
              keywords: ["age cutoff", "max age", "old photos", "creation date"], page: .safetyLimits),
        .init(id: "safety.retry", title: "Max retry attempts", breadcrumb: "Safety & limits",
              keywords: ["retry", "queue", "attempts"], page: .safetyLimits),
        .init(id: "safety.alert", title: "Alert on aborted run", breadcrumb: "Safety & limits",
              keywords: ["notification", "alert", "abort"], page: .safetyLimits),
        .init(id: "safety.backlog", title: "Backlog alert threshold", breadcrumb: "Safety & limits",
              keywords: ["banner", "backlog", "notification", "threshold"], page: .safetyLimits),

        // Appearance
        .init(id: "appearance.theme", title: "Appearance", breadcrumb: "Appearance",
              keywords: ["light", "dark", "system", "theme"], page: .appearance),
        .init(id: "appearance.time", title: "Time format", breadcrumb: "Appearance",
              keywords: ["12 hour", "24 hour", "clock"], page: .appearance),

        // Data & recovery
        .init(id: "data.export", title: "Export data", breadcrumb: "Data & recovery",
              keywords: ["backup", "share", "export", "json"], page: .dataAndRecovery),
        .init(id: "data.import", title: "Import data", breadcrumb: "Data & recovery",
              keywords: ["restore", "import", "backup"], page: .dataAndRecovery),
        .init(id: "data.missed", title: "Find missed deletions", breadcrumb: "Data & recovery",
              keywords: ["scan", "missed deletions", "recovery"], page: .dataAndRecovery),
        .init(id: "data.deferred", title: "Deferred queue", breadcrumb: "Data & recovery",
              keywords: ["deferred", "queue", "icloud", "large", "drain"], page: .dataAndRecovery),
        .init(id: "data.rescan", title: "Rescan library", breadcrumb: "Data & recovery",
              keywords: ["re-enumerate", "rescan"], page: .dataAndRecovery),
        .init(id: "data.clearhash", title: "Clear hash cache", breadcrumb: "Data & recovery",
              keywords: ["force re-hash", "drop cache", "rebuild"], page: .dataAndRecovery),
        .init(id: "data.verbose", title: "Verbose journal", breadcrumb: "Data & recovery",
              keywords: ["logging", "journal", "diagnostic"], page: .dataAndRecovery),

        // Advanced
        .init(id: "adv.countfloor", title: "Count floor", breadcrumb: "Advanced",
              keywords: ["minimum", "batch", "floor"], page: .advanced),
        .init(id: "adv.thumbnail", title: "Thumbnail cache cap", breadcrumb: "Advanced",
              keywords: ["thumbnail", "cache", "mb"], page: .advanced),
        .init(id: "adv.thumbhash", title: "Thumbhash cache cap", breadcrumb: "Advanced",
              keywords: ["thumbhash", "placeholder"], page: .advanced),
        .init(id: "adv.incsync", title: "Incremental server sync", breadcrumb: "Advanced",
              keywords: ["stream", "incremental", "sync"], page: .advanced),
        .init(id: "adv.diaglog", title: "Diagnostic logging", breadcrumb: "Advanced",
              keywords: ["debug", "logs", "diagnostic", "bug report", "feedback"], page: .advanced),
        .init(id: "conn.signin", title: "Sign in to Immich", breadcrumb: "Connection",
              keywords: ["session", "email password", "login"], page: .connection),
        .init(id: "adv.resetindex", title: "Reset index", breadcrumb: "Advanced › Danger zone",
              keywords: ["wipe", "danger", "reset"], page: .advanced),
        .init(id: "adv.clearjournal", title: "Clear journal", breadcrumb: "Advanced › Danger zone",
              keywords: ["wipe", "danger", "journal"], page: .advanced),
        .init(id: "adv.clearexcl", title: "Clear excluded assets", breadcrumb: "Advanced › Danger zone",
              keywords: ["wipe", "danger", "exclusions"], page: .advanced),
        .init(id: "conn.disconnect", title: "Disconnect server", breadcrumb: "Connection",
              keywords: ["sign out", "disconnect", "logout", "remove key", "switch server"], page: .connection),

        // About
        .init(id: "about.version", title: "App version", breadcrumb: "About",
              keywords: ["build", "marketing version", "about"], page: .about),
    ]

    /// Filtered + sorted entries for the current `searchText`.
    /// Case-insensitive substring match on title (priority) + any
    /// keyword. Title matches sort first so typing the exact label
    /// surfaces the canonical row at the top.
    private var filteredSearchEntries: [SearchEntry] {
        let q = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var titleHits: [SearchEntry] = []
        var keywordHits: [SearchEntry] = []
        for entry in Self.searchIndex {
            if entry.title.lowercased().contains(q) {
                titleHits.append(entry)
            } else if entry.keywords.contains(where: { $0.lowercased().contains(q) }) {
                keywordHits.append(entry)
            }
        }
        return titleHits + keywordHits
    }

    /// Search result rows rendered in place of the regular root list
    /// while `searchText` is non-empty. Each row is a NavigationLink
    /// that pushes the entry's sub-page. We don't scroll-to-row inside
    /// the destination — Phase 3 just gets you to the right page; the
    /// row is visible there.
    @ViewBuilder
    private var searchResults: some View {
        let entries = filteredSearchEntries
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.cairnScaled(size: 28, weight: .regular))
                    .foregroundStyle(t.textHint)
                Text("No settings match “\(searchText)”")
                    .font(.cairnScaled(size: 14))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .padding(.horizontal, 24)
        } else {
            CairnCard {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    // Value-based push (paired with the NavigationStack's
                    // `.navigationDestination(for: SettingsPage.self)`).
                    // Lighter than the closure-destination form during
                    // the .searchable dismiss + push animation, which
                    // is when the "partial render then lag" stagger was
                    // most visible.
                    NavigationLink(value: entry.page) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.cairnScaled(size: 15))
                                .foregroundStyle(t.textBody)
                            Text(entry.breadcrumb)
                                .font(.cairnScaled(size: 12))
                                .foregroundStyle(t.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.right")
                                .font(.cairnScaled(size: 12, weight: .semibold))
                                .foregroundStyle(t.textHint)
                                .padding(.trailing, 14)
                        }
                    }
                    .buttonStyle(.plain)
                    if idx < entries.count - 1 {
                        RowDivider()
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    /// Resolves a SettingsPage to its destination view. Mirrors the
    /// `SettingsCategoryRow { … }` destination block on the root list
    /// so search-result navigation lands in the same place as
    /// category-row navigation.
    @ViewBuilder
    private func page(for page: SettingsPage) -> some View {
        switch page {
        case .connection: connectionPage
        case .library: libraryPage
        case .safetyLimits: safetyLimitsPage
        case .appearance: appearancePage
        case .dataAndRecovery: dataAndRecoveryPage
        case .advanced: advancedPage
        case .about: aboutPage
        }
    }

    // MARK: - Quick settings

    /// Pinned at the top of the Settings root: the two safety knobs
    /// users revisit most after onboarding (strictness + quarantine
    /// window). Same bindings as the canonical rows inside Safety &
    /// limits — editing here updates the value in both places. The
    /// canonical home stays on the sub-page; this card is a quick-
    /// access shortcut so calibration doesn't require a drill-in
    /// every time.
    @ViewBuilder
    private var quickSettingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUICK SETTINGS")
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textMuted)
                .padding(.horizontal, 22)
                .padding(.top, 16)
            CairnCard {
                VStack(spacing: 0) {
                    StrictnessRow(strictness: $settings.deletionStrictness)
                    RowDivider()
                    QuarantineRow(days: $settings.quarantineDays)
                }
            }
        }
    }

    @ViewBuilder
    private var rootList: some View {
        CairnCard {
            // Connection lives at the top because a wrong / missing
            // server URL or API key blocks everything else; that's the
            // one row a confused user should hit first.
            SettingsCategoryRow(
                icon: "network",
                iconTint: t.info,
                title: "Connection",
                summary: connectionSummary
            ) { connectionPage }

            RowDivider()

            SettingsCategoryRow(
                icon: "photo.on.rectangle.angled",
                iconTint: t.primary,
                title: "Library",
                summary: librarySummary
            ) { libraryPage }

            RowDivider()

            SettingsCategoryRow(
                icon: "shield",
                iconTint: t.verified,
                title: "Safety & limits",
                summary: safetyLimitsSummary
            ) { safetyLimitsPage }

            RowDivider()

            SettingsCategoryRow(
                icon: "paintpalette",
                iconTint: t.accent,
                title: "Appearance",
                summary: appearanceSummary
            ) { appearancePage }

            RowDivider()

            // Data + Recovery merged. Both are about moving state
            // around / getting back to a known-good place; the two
            // were artificially separate in Phase 1.
            SettingsCategoryRow(
                icon: "arrow.up.arrow.down",
                iconTint: t.quiet,
                title: "Data & recovery",
                summary: dataAndRecoverySummary
            ) { dataAndRecoveryPage }

            RowDivider()

            // Advanced now contains the Danger zone subsection at
            // the bottom. Power-user surface in one place — both the
            // tunable knobs (cache caps, count floor, incremental
            // sync) and the irreversible data-reset actions (reset
            // index, clear journal, clear servers/exclusions) live
            // behind one row. Credential lifecycle (disconnect) lives
            // in Connection, not here.
            SettingsCategoryRow(
                icon: "wrench.and.screwdriver",
                iconTint: t.textMuted,
                title: "Advanced",
                summary: nil
            ) { advancedPage }

            RowDivider()

            SettingsCategoryRow(
                icon: "info.circle",
                iconTint: t.info,
                title: "About",
                summary: AboutInfo.versionLabel
            ) { aboutPage }
        }
        .padding(.top, 16)
    }

    // MARK: - Inline summaries

    /// Short status text on the Connection parent row — surfaces
    /// connection state inline so the user can spot a broken setup
    /// without drilling in.
    private var connectionSummary: String? {
        switch connectionStatus {
        case .healthy: return "Connected"
        case .offline: return "Offline"
        case .authStale: return "Auth stale"
        }
    }

    /// Library summary — prefer a Photos-auth health flag when
    /// non-full (denied / limited blocks everything else), else fall
    /// back to the scope description. Photos access lives on the
    /// Library page now, so a degraded permission state surfacing
    /// on the parent row is honest.
    private var librarySummary: String? {
        switch photoAuthStatus {
        case .denied: return "Photos: denied"
        case .limited: return "Photos: limited"
        case .full, .none:
            switch settings.indexingScope {
            case .fullLibrary: return "All photos"
            case .selectedAlbums(let ids):
                if ids.isEmpty { return "No albums selected" }
                return "\(ids.count) album\(ids.count == 1 ? "" : "s")"
            }
        }
    }

    /// Safety & limits summary — strictness + quarantine in shorthand
    /// (e.g. "Trusting · 14d"). These are the two highest-signal
    /// rails values; surfacing them inline lets the user verify the
    /// current calibration without entering the sub-page.
    private var safetyLimitsSummary: String? {
        let strictness: String
        switch settings.deletionStrictness {
        case .strict: strictness = "Cautious"
        case .trusting: strictness = "Balanced"
        case .autonomous: strictness = "Autonomous"
        }
        let days = settings.quarantineDays
        let quarantine = days == 0 ? "no quarantine" : "\(days)d"
        return "\(strictness) · \(quarantine)"
    }

    /// Appearance summary — current theme override. `.system` shows
    /// nothing (default; nothing notable to surface). Time format
    /// stays inside the sub-page since it's lower-signal.
    private var appearanceSummary: String? {
        switch settings.appearance {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return nil
        }
    }

    /// Data & recovery summary — only shows when there's actually
    /// something to surface (non-empty deferred queue is the
    /// load-bearing signal there; otherwise the page is just
    /// affordances and there's nothing for the parent row to say).
    private var dataAndRecoverySummary: String? {
        let count = deferredQueue.count + deferredQueue.aboveCeiling
        guard count > 0 else { return nil }
        return "\(count) deferred"
    }

    // MARK: - Sub-pages
    //
    // Each sub-page wraps the corresponding section computed property
    // (still defined below for preview / single-section reuse) inside
    // a scrollable container with a navigation title. KeylineSection
    // headers inside section views double as visual sub-section
    // markers when a page combines multiple groupings.

    @ViewBuilder
    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                immichServerSection
            }
        }
        .background(t.bg)
        .navigationTitle("Connection")
        .cairnNavigationTitleDisplayMode(.inline)
        // Re-ping on appear so the latency reading is always fresh
        // when the user looks. Without this the value is from app
        // boot or the last manual retry — can easily be hours old.
        // Cheap (one HTTP round-trip); only runs while this page is
        // on screen, so it doesn't burn battery in normal use.
        .task {
            onRefreshConnection()
        }
    }

    @ViewBuilder
    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                photosAccessSection
                backgroundRefreshSection
                indexingScopeSection
                initialScanSection
                excludedAssetsLibrarySection
            }
        }
        .background(t.bg)
        .navigationTitle("Library")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    /// Excluded-assets row lifted out of the old safety-rails page
    /// into Library — it's about *what* cairn manages, not *how* it
    /// behaves. Same KeyValRow + value preview as before; just a
    /// different home.
    private var excludedAssetsLibrarySection: some View {
        Group {
            KeylineSection("Excluded assets", icon: "hand.raised", iconTint: t.quiet)
            CairnCard {
                KeyValRow(
                    "Excluded assets",
                    value: { excludedValue },
                    onTap: onOpenExcluded
                )
            }
        }
    }

    @ViewBuilder
    private var safetyLimitsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                safetyRailsCoreSection
                safetyAlertsSection
            }
        }
        .background(t.bg)
        .navigationTitle("Safety & limits")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    /// Just the actual safety rails — percent threshold, strictness,
    /// quarantine, iCloud limits, hard ceiling, propagation cutoff,
    /// retry attempts. Excluded assets / deferred queue / rescan /
    /// clear-hash-cache live on Library and Recovery now.
    private var safetyRailsCoreSection: some View {
        Group {
            KeylineSection("Safety rails", icon: "shield", iconTint: t.verified)
            CairnCard {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Spacer(minLength: 0)
                            HelpPopover {
                                Text("**Safety rail.** If a single run would move more than this fraction of matched photos to Immich's Trash, the run aborts without touching the server.")
                                Text("Defends against bugs, permission regressions, or a library-wipe cascading into a mass delete.")
                                Text("The \"Count floor\" under Advanced is paired with this: for small libraries, 1% can be just one or two photos, which is noise — the floor sets a minimum batch size before the percent check engages.")
                            }
                            .padding(.trailing, 6)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, -4)

                        SliderInputRow(
                            label: "Percent threshold",
                            sub: String(
                                format: "Abort if a run would move more than %.1f%% of matched assets to Immich's Trash.",
                                settings.maxDeletePercent
                            ),
                            value: $settings.maxDeletePercent,
                            range: 0.5...5,
                            step: 0.1,
                            unitSuffix: "%",
                            format: { String(format: "%.1f", $0) },
                            parse: NumericInputParse.decimal
                        )
                    }
                    RowDivider()
                    StrictnessRow(strictness: $settings.deletionStrictness)
                    RowDivider()
                    QuarantineRow(days: $settings.quarantineDays)
                    RowDivider()
                    ICloudDownloadLimitRow(mb: $settings.iCloudDownloadLimitMB)
                    RowDivider()
                    HardCeilingRow(mb: $settings.iCloudMaxEverBytesMB)
                    RowDivider()
                    PropagationMaxAgeRow(days: $settings.propagationMaxAgeDays)
                    RowDivider()
                    MaxRetryAttemptsRow(attempts: $settings.maxRetryAttempts)
                }
            }
        }
    }

    @ViewBuilder
    private var appearancePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appearanceSection
            }
        }
        .background(t.bg)
        .navigationTitle("Appearance")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    /// Combines old Data (export / import) + Recovery (find missed
    /// deletions + deferred queue + rescan + clear hash cache).
    /// Both are about moving state around to get back to a working
    /// place — natural co-location.
    @ViewBuilder
    private var dataAndRecoveryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dataSection
                recoverySection
                recoveryHashCacheSection
                verboseJournalSection
            }
        }
        .background(t.bg)
        .navigationTitle("Data & recovery")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    /// Hash-cache management rows. Recovery-shaped affordances
    /// (rebuild the cache, drop the change token, etc.) rather than
    /// safety knobs.
    private var recoveryHashCacheSection: some View {
        Group {
            KeylineSection("Hash cache", icon: "arrow.clockwise", iconTint: t.info)
            CairnCard {
                VStack(spacing: 0) {
                    DeferredQueueRow(
                        summary: deferredQueue,
                        isSyncing: isSyncing,
                        syncProgress: syncProgress,
                        onHashNow: onForceDrainDeferred
                    )
                    RowDivider()
                    KeyValRow(
                        "Rescan library",
                        value: { Text("Force re-enumerate").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { pendingRescanLibrary = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Clear hash cache",
                        value: { Text("Force re-hash").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { pendingClearHashCache = true }
                    )
                }
            }
        }
    }

    /// Advanced now hosts the Danger zone subsection at the bottom.
    /// Both surfaces are "for power users who know what they're
    /// doing" — natural co-location. The old standalone collapse
    /// toggle inside `advancedSection` is gone now that Advanced
    /// has its own page (one-tap navigation already filters to
    /// power users; the second collapse-then-tap was friction
    /// without value).
    @ViewBuilder
    private var advancedPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                advancedSection
                dangerZoneSection
            }
        }
        .background(t.bg)
        .navigationTitle("Advanced")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                howItWorksSection
                aboutSection
            }
        }
        .background(t.bg)
        .navigationTitle("About")
        .cairnNavigationTitleDisplayMode(.inline)
    }

    private static let scrollTopAnchor = "cairn.scroll.top"

    // MARK: - Immich server

    // MARK: - Section icon/tint mapping
    //
    // Each section gets a leading SF Symbol + semantic color so a
    // long list of neutral-gray section titles becomes easy to scan.
    // Color choices follow existing semantic uses elsewhere in the
    // app (info=network, verified=safe, pending=warn, danger=destructive,
    // accent=creative-when-no-other-fits, quiet=ambient-secondary).
    private var immichServerSection: some View {
        Group {
            KeylineSection("Immich server", icon: "network", iconTint: t.info)
            CairnCard {
                VStack(spacing: 0) {
                    // Read-only — the URL is only editable via Sign
                    // out + re-onboarding. No chevron to suggest
                    // tappability.
                    KeyValRow(
                        "URL",
                        value: serverUrl.replacingOccurrences(of: "https://", with: ""),
                        mono: true
                    )
                    RowDivider()
                    // Single entry point for everything API-key: tapping
                    // opens a sheet to reveal/copy, rotate the key in
                    // place, or disconnect. Consolidates what used to be a
                    // separate inline key display and a separate Disconnect
                    // row.
                    KeyValRow(
                        "API key",
                        value: { Text(apiKeyMasked).foregroundStyle(t.textMuted) },
                        mono: true,
                        chevron: true,
                        onTap: { showApiKeyDetail = true }
                    )
                    RowDivider()
                    KeyValRow("Connection", value: { ConnectionPill(status: connectionStatus) })
                    if let serverVersion {
                        RowDivider()
                        KeyValRow(
                            "Server version",
                            value: {
                                Text(serverVersion.description)
                                    .foregroundStyle(serverVersionAdvisory == nil ? t.textMuted : t.pendingInk)
                            },
                            mono: true
                        )
                        if let serverVersionAdvisory {
                            // Soft advisory only — a newer Immich major than
                            // cairn was verified against. Not a blocker.
                            Text(serverVersionAdvisory)
                                .font(.cairnScaled(size: 12))
                                .foregroundStyle(t.pendingInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 10)
                        }
                    }
                    RowDivider()
                    // Email/password session sign-in lives here with the
                    // rest of server auth (URL + API key). The API key
                    // covers everything except the /sync/* endpoints, which
                    // Immich gates behind a real session — so this is what
                    // unlocks "Incremental server sync" (toggle in Advanced).
                    // The "?" explains that advantage (what session auth
                    // buys you over the API key alone).
                    if hasSessionToken {
                        sessionRow(
                            label: "Signed in to Immich",
                            value: { Text("Sign out").foregroundStyle(t.dangerInk) },
                            chevron: false,
                            onTap: onSignOutSession
                        )
                    } else {
                        sessionRow(
                            label: "Sign in to Immich",
                            value: { Text("Enables incremental sync").foregroundStyle(t.textMuted) },
                            chevron: true,
                            onTap: onOpenSessionSignIn
                        )
                    }
                    // Disconnect lives inside the API-key sheet now (the
                    // single home for the server credential lifecycle),
                    // not as its own card row.
                }
            }
        }
        .sheet(isPresented: $showApiKeyDetail) {
            ApiKeyDetailSheet(
                rawKey: apiKey,
                masked: apiKeyMasked,
                replaceKey: onReplaceAPIKey,
                onDisconnect: {
                    showApiKeyDetail = false
                    onSignOut()
                },
                onDismiss: { showApiKeyDetail = false }
            )
        }
    }

    /// Session sign-in/out row with an inline "?" explaining what
    /// email/password auth adds over the API key. The help glyph is its
    /// own button (its tap opens the popover); the rest of the row taps
    /// through to `onTap`. Factored out so the signed-in and
    /// signed-out variants share one layout + one help body.
    @ViewBuilder
    private func sessionRow<V: View>(
        label: String,
        @ViewBuilder value: () -> V,
        chevron: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
            HelpPopover { sessionAuthHelp }
            Spacer(minLength: 12)
            value()
                .font(.cairnScaled(size: 15))
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.cairnScaled(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var sessionAuthHelp: some View {
        Text("Your API key already covers everything ") + .cairnWord + Text(" needs to detect deletions and move photos to Immich's Trash. Signing in with your Immich email and password adds one extra capability.")
        (Text("Immich only allows its incremental-sync stream over a logged-in session, not an API key. With it, ") + .cairnWord + Text(" fetches just what changed on the server since the last sync instead of re-listing every asset — noticeably faster on large libraries."))
            .padding(.top, 4)
        (Text("The session token is stored in your iPhone's Keychain and used only for that streaming path. Sign out anytime — your API key stays connected."))
            .padding(.top, 4)
    }

    // MARK: - Excluded-value sub-view

    @ViewBuilder
    private var excludedValue: some View {
        HStack(spacing: 6) {
            Text(excludedCount > 0 ? "\(excludedCount) protected" : "None")
                .font(.cairnScaled(size: 15))
                .foregroundStyle(excludedCount > 0 ? t.infoInk : t.textMuted)
            Image(systemName: "chevron.right")
                .font(.cairnScaled(size: 12, weight: .semibold))
                .foregroundStyle(t.textHint)
        }
    }

    // MARK: - Indexing scope

    private var indexingScopeSection: some View {
        Group {
            KeylineSection("Indexing scope", icon: "rectangle.dashed", iconTint: t.info)
            CairnCard {
                VStack(spacing: 0) {
                    IndexingScopeRow(scope: $settings.indexingScope)
                    if settings.indexingScope.isRestricted {
                        RowDivider()
                        KeyValRow(
                            "Selected albums",
                            value: { selectedAlbumsValue },
                            onTap: onOpenAlbumPicker
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedAlbumsValue: some View {
        let count = settings.indexingScope.albumLocalIdentifiers.count
        HStack(spacing: 6) {
            Text(count == 0
                 ? "Pick at least one"
                 : "\(count) album\(count == 1 ? "" : "s")")
                .font(.cairnScaled(size: 15))
                .foregroundStyle(count > 0 ? t.infoInk : t.pendingInk)
            Image(systemName: "chevron.right")
                .font(.cairnScaled(size: 12, weight: .semibold))
                .foregroundStyle(t.textHint)
        }
    }

    // MARK: - Initial scan

    /// Fast-initial-scan toggle. When on, cairn matches phone photos
    /// against server assets on `(filename, capture date)` and trusts
    /// the server's SHA1 for unambiguous matches — skipping local
    /// hashing for those entries. Surfaced as a discrete row because
    /// the choice meaningfully affects first-scan time on iCloud-
    /// optimized libraries (hours → seconds) and what cairn verifies
    /// locally vs imputes from the server.
    private var initialScanSection: some View {
        Group {
            KeylineSection("Initial scan", icon: "bolt", iconTint: t.info)
            CairnCard {
                VStack(spacing: 0) {
                    ToggleRow(
                        "Trust server checksums",
                        sub: "For phone photos that match a server asset by filename and capture date, use the server's SHA1 instead of re-hashing locally. Ambiguous matches (multiple server photos with the same filename and date) fall through to local hashing. Off = always hash locally.",
                        value: $settings.fastInitialScan
                    )
                    RowDivider()
                    ToggleRow(
                        "Keep screen on during sync",
                        sub: "Prevents Auto-Lock while a sync is running so the foreground hashing pass doesn't stall when the device sleeps. On by default for the first sync; auto-disables after that. Re-enable for big follow-up runs (large onboarding, bulk delete) when you want to leave the phone unattended without it locking.",
                        value: $settings.keepScreenAwakeDuringSync
                    )
                    if library.imputed > 0 {
                        RowDivider()
                        cachedHashDiagnosticRow
                        RowDivider()
                        KeyValRow(
                            "Re-hash imputed entries",
                            value: { Text("Verify locally").foregroundStyle(t.infoInk) },
                            chevron: true,
                            onTap: { pendingVerifyImputed = true }
                        )
                    }
                }
            }
        }
    }

    /// Diagnostic line shown when at least one row in the cache was
    /// imputed from the server rather than locally hashed. Surfaces
    /// the breakdown so the user can see how much of the cache is
    /// trust-seeded vs verified.
    @ViewBuilder
    private var cachedHashDiagnosticRow: some View {
        let verified = max(0, library.indexed - library.imputed)
        let imputed = library.imputed
        KeyValRow(
            "Cache breakdown",
            value: {
                HStack(spacing: 6) {
                    Text("\(verified.formatted(.number)) verified")
                        .font(.cairnScaled(size: 14))
                        .foregroundStyle(t.textBody)
                    Text("·")
                        .foregroundStyle(t.textHint)
                    Text("\(imputed.formatted(.number)) trust-seeded")
                        .font(.cairnScaled(size: 14))
                        .foregroundStyle(t.infoInk)
                }
            }
        )
    }

    // MARK: - Trip alerts (Safety & limits)

    /// Notification-shaped rows that hang off the safety rails:
    /// alert when a run aborts, and alert when quarantine backlog
    /// crosses a threshold. Both are "tell me when the rails do
    /// their job" — they belong with the rails themselves rather
    /// than in their own Notifications page.
    private var safetyAlertsSection: some View {
        Group {
            KeylineSection("Alerts", icon: "bell", iconTint: t.pending)
            CairnCard {
                VStack(spacing: 0) {
                    ToggleRow(
                        "Alert on aborted run",
                        sub: "Local notification when a safety rail trips. Tapping it opens the review screen.",
                        value: $settings.notifyOnAbort
                    )
                    RowDivider()
                    BacklogAlertRow(threshold: $settings.deletionBacklogAlertThreshold)
                }
            }
        }
    }

    // MARK: - Verbose journal (Data & recovery)

    /// Journal verbosity toggle. Sat with the other notification
    /// rows historically; it's actually about journal data
    /// recording, so it lives with Data & recovery now.
    private var verboseJournalSection: some View {
        Group {
            KeylineSection("Journal", icon: "list.bullet.rectangle", iconTint: t.quiet)
            CairnCard {
                ToggleRow(
                    "Verbose journal",
                    sub: "Record every API request in deletion-journal.jsonl.",
                    value: $settings.verboseLogging
                )
            }
        }
    }

    // MARK: - Photos access (Library)

    /// Photos-access row lifted out of the old combined permissions
    /// section into Library — Photos access and indexing scope both
    /// bound "what cairn can see," so they belong together. The
    /// limited-mode Callout follows the row.
    private var photosAccessSection: some View {
        Group {
            KeylineSection("Photos access", icon: "lock", iconTint: t.quiet)
            CairnCard {
                // Can't *grant* permissions in-app — iOS only
                // allows requesting them once. After that the
                // user has to flip the switch in Settings → cairn.
                // Row taps deep-link there so the fix is one tap
                // away rather than a "go find it yourself" trek.
                KeyValRow(
                    "Photos access",
                    value: { photoAccessValueLabel },
                    chevron: true,
                    onTap: openIOSSettings
                )
            }
            // Explanatory note for `.limited` mode. Lives outside the
            // card as a soft-tone Callout so it reads as context, not
            // as another tap target. Hidden under `.full` and `.denied`
            // (denied has its own actionable copy elsewhere).
            //
            // `.pending` (amber) reads as "between informational and
            // warning" — a real degradation the user should know
            // about, but not an error. Same tone we use for inferred
            // orphans, mass-offload heads-ups, and the held-by-
            // quarantine line.
            if photoAuthStatus == .limited {
                Callout(.pending, icon: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Limited Photos access").fontWeight(.semibold)
                        (Text.cairnWord + Text(" can only see the photos you selected. Normal deletes still propagate, but any delete the system change-log misses (or any photo you deselect from the picked set) goes to ") + Text("Pending review").fontWeight(.semibold) + Text(" for manual confirmation instead of auto-trashing on Immich. Switch to Full Photos access for the strongest automatic safety."))
                            .opacity(0.88).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Background refresh (Notifications)

    /// Background-refresh row split out of the old combined
    /// permissions section. Stays on the Notifications page since
    /// background refresh is what enables background syncs that
    /// in turn drive notification surfaces.
    private var backgroundRefreshSection: some View {
        Group {
            KeylineSection("Background refresh", icon: "arrow.triangle.2.circlepath", iconTint: t.quiet)
            CairnCard {
                KeyValRow(
                    "Background refresh",
                    value: { Text("Allowed").foregroundStyle(t.verifiedInk) },
                    chevron: true,
                    onTap: openIOSSettings
                )
            }
        }
    }

    /// "Full library" / "Selected photos" / "Denied" / fallback copy
    /// for the Photos-access row, color-coded by health.
    @ViewBuilder
    private var photoAccessValueLabel: some View {
        switch photoAuthStatus {
        case .full:
            Text("Full library").foregroundStyle(t.verifiedInk)
        case .limited:
            Text("Selected photos").foregroundStyle(t.pendingInk)
        case .denied:
            Text("Denied").foregroundStyle(t.dangerInk)
        case .none:
            // No status yet (preview, mid-bootstrap). Match the
            // legacy hardcoded copy so nothing regresses visually.
            Text("Full library").foregroundStyle(t.verifiedInk)
        }
    }

    /// Opens iOS Settings → cairn (the app's per-app settings pane).
    /// `UIApplication.openSettingsURLString` is the canonical deep
    /// link; always resolvable for apps that have asked for any
    /// permission.
    private func openIOSSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Group {
            KeylineSection("Appearance", icon: "paintpalette", iconTint: t.accent)
            CairnCard {
                AppearanceRow(appearance: $settings.appearance)
                Divider().background(t.divider)
                TimeFormatRow(format: $settings.timeDisplayFormat)
            }
        }
    }

    // MARK: - Advanced

    /// Niche tuning knobs that most users won't need to touch. Hidden
    /// by default behind a tap; expand reveals the rows. Matches the
    /// app's existing Keyline + Card pattern rather than SwiftUI's
    /// `DisclosureGroup` so the visual language stays consistent.
    /// Collapsed by default. Documents the exact sequence cairn runs
    /// through on trash + restore so users understand what's happening
    /// on their Immich server — tags applied, what's moved where, and
    /// how to inspect it server-side.
    private var howItWorksSection: some View {
        Group {
            KeylineSection("How it works", icon: "info.circle", iconTint: t.quiet)
            CairnCard {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? .none : .snappy(duration: 0.16)) {
                            howItWorksExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(howItWorksExpanded
                                 ? "Hide server-side details"
                                 : "What cairn does on your Immich server")
                                .font(.cairnScaled(size: 15))
                                .foregroundStyle(t.textBody)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Image(systemName: howItWorksExpanded ? "chevron.up" : "chevron.down")
                                .font(.cairnScaled(size: 12, weight: .semibold))
                                .foregroundStyle(t.textHint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(howItWorksExpanded ? "Hide how it works" : "Show how it works")

                    if howItWorksExpanded {
                        RowDivider()
                        howItWorksBody
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var howItWorksBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            howItWorksParagraph(
                title: "What cairn proposes for trash",
                body: Text("A photo becomes a trash candidate only when all three are true:\n\n1. ") + .cairnWord + Text(" observed the photo on this iPhone (its checksum entered the local index).\n2. The photo is no longer in this iPhone's library.\n3. Immich still has the photo.\n\nPhotos uploaded to Immich from a different device — never on this iPhone — are invisible to ") + .cairnWord + Text(" and stay put.")
            )
            howItWorksParagraph(
                title: "Quarantine window",
                body: Text("When ") + .cairnWord + Text(" detects a deletion, it starts a 14-day clock (adjustable in Settings → Quarantine). The photo sits in Pending Review for the full window, giving you time to undo. After 14 days it moves to Ready to Trash and the next sync calls Immich.")
            )
            howItWorksParagraph(
                title: "Edits stay safe",
                body: Text("Editing a photo in iOS Photos doesn't propagate to Immich as a trash. ") + .cairnWord + Text(" anchors the original checksum and protects it for as long as the photo is alive on this iPhone — even after edits change the bytes locally. The Immich mobile app uploads each edit as a separate version, so Immich typically holds two versions per edited photo: the original (anchored) and the current rendered edit. When you delete the photo locally, both versions enter quarantine together.\n\nMultiple edits without reverting: intermediate versions quarantine and trash; the original-content and the latest edit stay on Immich indefinitely.\n\nApple's edit history is private to Photos.app — neither ") + .cairnWord + Text(" nor Immich can replay edits from a downloaded file. Keep the photo on this iPhone if you want to revert later.")
            )
            howItWorksParagraph(
                title: "Changing your mind before quarantine",
                body: Text("Restoring a deleted photo from iOS's Recently Deleted (Photos → Albums → Recently Deleted → Recover) within the quarantine window cancels propagation. ") + .cairnWord + Text(" detects the asset returning and clears its entry — the next sync removes it from Pending Review without ever calling Immich.")
            )
            howItWorksParagraph(
                title: "Live Photos",
                body: Text("A Live Photo on iOS is two assets on Immich: the still and a paired motion video (hidden by default). ") + .cairnWord + Text(" includes both halves in the same trash call so they propagate together — neither orphans.")
            )
            howItWorksParagraph(
                title: "Trash flow",
                body: Text("When you confirm a sync, ") + .cairnWord + Text(" does the following on your Immich server, in order:\n\n1. Upserts a tag named ")
                    + Text("cairn/v1/run/<run-id>").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" where ")
                    + Text("<run-id>").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" is an ISO-8601 timestamp plus a short device id.\n2. Applies that tag to every affected asset (stills + paired Live Photo motion videos).\n3. Calls ")
                    + Text("DELETE /api/assets {force: false}").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" — the asset moves to Immich's Trash folder, which retains it for 30 days.")
            )
            howItWorksParagraph(
                title: "Undoing a cairn run",
                body: Text("After a sync has run, the Runs tab can restore any past run via ")
                    + Text("POST /api/trash/restore/assets").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(". The ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text) + Text(" tag stays on the asset — it's a breadcrumb, not a state flag — so you can always find what a given run touched via Immich's Tags view.")
            )
            howItWorksParagraph(
                title: "Nothing is permanent",
                body: Text("Immich's Trash retains for 30 days regardless of how the asset got there (") + .cairnWord + Text(" or the Immich web UI). Past that window, Immich's own retention policy applies; ") + .cairnWord + Text(" has no say in what happens after.")
            )
            howItWorksParagraph(
                title: "Local journal",
                body: Text("Every step is also written to an append-only ")
                    + Text("deletion-journal.jsonl").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text)
                    + Text(" on this device. The Runs tab renders that file; Settings → Danger zone → Clear journal deletes it.")
            )
            howItWorksParagraph(
                title: "Where to inspect on Immich",
                body: Text("Open the Immich web UI → Tags. Every ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 12, design: .monospaced)).foregroundStyle(t.text) + Text(" tag shows its assets. The Trash view shows everything still recoverable.")
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func howItWorksParagraph(title: String, body: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.cairnScaled(size: 12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(t.textMuted)
                .textCase(.uppercase)
            body
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textBody)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Advanced power-user settings. No collapse toggle anymore —
    /// the page itself is the affordance now that Advanced has its
    /// own NavigationLink. Putting a "Show/hide" button inside a
    /// page the user already chose to enter is double-friction.
    private var advancedSection: some View {
        Group {
            KeylineSection("Advanced", icon: "wrench.and.screwdriver", iconTint: t.textMuted)
            CairnCard {
                VStack(spacing: 0) {
                    CountFloorRow(floor: $settings.minDeleteFloor)
                    RowDivider()
                    HashConcurrencyRow(value: $settings.hashConcurrency)
                    RowDivider()
                    ThumbnailCacheCapRow(mb: $settings.thumbnailCacheCapMB)
                    RowDivider()
                    ThumbhashCacheCapRow(mb: $settings.thumbhashCapMB)
                    RowDivider()
                    ToggleRow(
                        "Incremental server sync",
                        sub: "Stream only the changes since the last sync instead of refetching the whole server library each time. Much faster on large libraries. Falls back to the slower full-refetch path if you're not signed in to Immich (Connection settings) or your account doesn't allow the streaming endpoint.",
                        value: $settings.useIncrementalServerSync
                    )
                    RowDivider()
                    ToggleRow(
                        "Diagnostic logging",
                        sub: "Continuously capture logs across launches so a bug report has full history. Off by default to skip the background work; turn it on, reproduce the issue, then Export. Export still works while off (current session only).",
                        value: $settings.persistentDiagnosticLogging
                    )
                    RowDivider()
                    KeyValRow(
                        "Export diagnostic logs",
                        value: { Text("Save & share").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: onExportDiagnosticLogs
                    )
                    RowDivider()
                    KeyValRow(
                        "Inspect asset by filename",
                        value: { Text("Triage").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { showInspectAssetAlert = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "View archived history",
                        value: { Text("Older runs").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: { showArchivedHistory = true }
                    )
                    #if DEBUG
                    RowDivider()
                    KeyValRow(
                        "Replay onboarding (dev)",
                        value: { Text("Review setup").foregroundStyle(t.textMuted) },
                        chevron: true,
                        onTap: onReplayOnboarding
                    )
                    RowDivider()
                    KeyValRow(
                        "Fire BG refresh now (dev)",
                        value: { Text("Run scheduled scan").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: onFireBackgroundRefresh
                    )
                    #endif
                }
            }
        }
    }

    // MARK: - Data (export / import)

    private var dataSection: some View {
        Group {
            KeylineSection("Data", icon: "arrow.up.arrow.down", iconTint: t.verifiedInk)
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Export data",
                        value: {
                            if isTransferringData {
                                ProgressView()
                            } else {
                                Text("Share backup").foregroundStyle(t.infoInk)
                            }
                        },
                        chevron: !isTransferringData,
                        onTap: { if !isTransferringData { showExportPicker = true } }
                    )
                    RowDivider()
                    KeyValRow(
                        "Import data",
                        value: {
                            if isTransferringData {
                                ProgressView()
                            } else {
                                Text("Restore from file").foregroundStyle(t.infoInk)
                            }
                        },
                        chevron: !isTransferringData,
                        onTap: { if !isTransferringData { showImportPicker = true } }
                    )
                }
            }
        }
    }

    // MARK: - Recovery

    /// Manual recovery tools — actions that scan the Immich server and
    /// fix accumulated drift cairn's normal sync pipeline couldn't
    /// catch (missed deletions during a sync gap, etc.). Filename-
    /// matched, so the user reviews each candidate before acting.
    private var recoverySection: some View {
        Group {
            KeylineSection("Recovery", icon: "wand.and.stars", iconTint: t.pendingInk)
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Find missed deletions",
                        value: { Text("Scan server").foregroundStyle(t.infoInk) },
                        chevron: true,
                        onTap: onOpenMissedDeletions
                    )
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        Group {
            KeylineSection("Danger zone", icon: "exclamationmark.triangle", iconTint: t.danger)
            CairnCard {
                VStack(spacing: 0) {
                    KeyValRow(
                        "Reset index",
                        value: { Text("Re-seed").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingResetIndex = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Clear journal",
                        value: { Text("Delete JSONL").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingClearJournal = true }
                    )
                    RowDivider()
                    KeyValRow(
                        "Clear saved servers & logins",
                        value: { Text("Wipe autocomplete").foregroundStyle(t.dangerInk) },
                        chevron: true,
                        onTap: { pendingClearRecentServers = true }
                    )
                    if excludedCount > 0 {
                        RowDivider()
                        KeyValRow(
                            "Clear excluded assets",
                            value: { Text("Wipe \(excludedCount)").foregroundStyle(t.dangerInk) },
                            chevron: true,
                            onTap: { pendingClearExclusions = true }
                        )
                    }
                    // "Disconnect server" (full sign-out) moved to
                    // Settings → Connection, alongside the URL / API key /
                    // session controls — Danger zone keeps only data-reset
                    // actions, not credential lifecycle.
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeylineSection("About", icon: "info.circle", iconTint: t.info)
            CairnCard {
                KeyValRow(
                    "About cairn",
                    value: AboutInfo.versionLabel,
                    chevron: true,
                    onTap: { showAbout = true }
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            Text.cairnWord + Text(" \(AboutInfo.versionLabel) · not affiliated with Immich")
            Text("MIT · open source · privacy")
        }
        .font(.cairnScaled(size: 11))
        .foregroundStyle(t.textHint)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}

/// Cross-platform shim for `navigationBarTitleDisplayMode` — only
/// available on iOS, but the CairnIOSCore module also builds on macOS
/// for tests / previews / lint targets. On non-iOS platforms this is
/// a no-op so the call sites can stay flat.
extension View {
    @ViewBuilder
    func cairnNavigationTitleDisplayMode(_ mode: CairnNavigationTitleDisplayMode) -> some View {
        #if os(iOS)
        switch mode {
        case .large: self.navigationBarTitleDisplayMode(.large)
        case .inline: self.navigationBarTitleDisplayMode(.inline)
        }
        #else
        self
        #endif
    }
}

enum CairnNavigationTitleDisplayMode {
    case large
    case inline
}

/// Row used by the new hierarchical Settings root. Visually inspired
/// by iOS Settings.app's category rows: leading rounded icon tile,
/// title, optional summary value, trailing chevron. Wraps a
/// `NavigationLink` so the destination view pushes onto the
/// surrounding `NavigationStack`. Tap target spans the row.
private struct SettingsCategoryRow<Destination: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    /// Optional inline summary on the right (before the chevron).
    /// Lets the parent row show "Indexing scope · 3 albums" so the
    /// user can spot a non-default state without drilling in.
    let summary: String?
    let destination: () -> Destination

    @Environment(\.cairnTokens) private var t

    init(
        icon: String,
        iconTint: Color,
        title: String,
        summary: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.summary = summary
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconTint.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.cairnScaled(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                Text(title)
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                Spacer(minLength: 8)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.cairnScaled(size: 13))
                        .foregroundStyle(t.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(.cairnScaled(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(summary.map { "Current: \($0)" } ?? "")
    }
}

/// Static helpers reading the bundled marketing version + build
/// number from `Info.plist`. Centralized so the footer, About
/// sheet, and any future diagnostics surface stay consistent.
enum AboutInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Compact "v0.1.0 (37)" used in row values + the footer.
    static var versionLabel: String {
        "v\(version) (\(build))"
    }
}

/// Modal "About cairn" sheet surfaced from Settings → About.
/// Shows the marketing version + build number alongside the
/// project's brand statement and links. Kept deliberately spare —
/// most users won't open it, and the few who do are mostly checking
/// "what build am I on" before filing a bug.
struct AboutSheet: View {
    let onClose: () -> Void
    @Environment(\.cairnTokens) private var t

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .center, spacing: 12) {
                        CairnMark(size: 64)
                        VStack(spacing: 4) {
                            Text.cairnWord
                                .font(.cairnScaled(size: 28, weight: .semibold))
                            Text(AboutInfo.versionLabel)
                                .font(.cairnScaled(size: 14, design: .monospaced))
                                .foregroundStyle(t.textHint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    CairnCard {
                        VStack(alignment: .leading, spacing: 0) {
                            KeyValRow("App version", value: AboutInfo.version, mono: true)
                            Divider().background(t.divider)
                            KeyValRow("Build", value: AboutInfo.build, mono: true)
                        }
                    }
                    .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("cairn propagates iPhone Photos deletions to a self-hosted Immich server. Not affiliated with Immich.")
                            .font(.cairnScaled(size: 13))
                            .foregroundStyle(t.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("MIT-licensed · open source.")
                            .font(.cairnScaled(size: 12))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 16)

                    Spacer(minLength: 24)
                }
            }
            .background(t.bg)
            .navigationTitle("About")
            #if canImport(UIKit)
            .cairnNavigationTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

// MARK: - Connection pill

/// Compact "● healthy · 42ms · 12s ago" / "● offline" pill that lives
/// on the right side of the URL/Connection row. The trailing
/// relative-time tail tells the user how stale the latency reading
/// is — important because the value only refreshes on Connection
/// page open + after each sync, so anything older than that is
/// genuinely old. Re-renders periodically via TimelineView so a
/// page sitting open doesn't show a frozen "5s ago" forever.
private struct ConnectionPill: View {
    let status: SettingsScreen.ConnectionStatus
    @Environment(\.cairnTokens) private var t

    var body: some View {
        // TimelineView re-fires every minute so the relative tail
        // ticks forward on long-lived views. The tail itself is
        // formatted via `relativeAge(for:from:)` with the current
        // wall-clock from `context.date`.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(label(now: context.date))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(inkColor)
            }
        }
    }

    private func label(now: Date) -> String {
        switch status {
        case .healthy(let ms, let checkedAt):
            return "healthy · \(ms)ms · \(Self.relativeAge(for: checkedAt, now: now))"
        case .offline:
            return "offline"
        case .authStale:
            return "auth expired"
        }
    }
    private var inkColor: Color {
        switch status {
        case .healthy: t.verifiedInk
        case .offline, .authStale: t.dangerInk
        }
    }
    private var dotColor: Color { inkColor.opacity(0.85) }

    /// Compact "just now / 12s ago / 3m ago / 2h ago / 4d ago".
    /// No external dependencies — `RelativeDateTimeFormatter` is
    /// fine but produces "1 minute ago" with full units which is
    /// chattier than this surface wants.
    static func relativeAge(for date: Date, now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }
}

// (SliderInputRow has been promoted to a public primitive in
// `CairnPrimitives.swift` so other screens — InitialScan scan
// options, future Setup thresholds — can reuse it. See that file
// for the current definition.)

// MARK: - Strictness picker row

/// Segmented picker for `DeletionStrictness`. The copy below the
/// picker is our own (the prototype was built before this landed) and is
/// kept short and factual — matches the existing sysadmin-tool tone.
/// Picker row for `CairnSettings.indexingScope`. Two-segment toggle:
/// "Full library" (default) vs. "Selected albums". The actual album
/// list is picked in a separate sheet — this row just owns the kind
/// switch + a one-line explanation that adapts per choice.
///
/// Because `IndexingScope` carries an associated `Set<String>` for the
/// selected case, the picker can't bind directly to the enum. We bridge
/// through a private `Kind` enum: switching to "Selected albums"
/// preserves the previously-selected album set if any, otherwise
/// initializes an empty set (the user's next tap on "Selected albums"
/// row opens the picker to fill it in).
private struct IndexingScopeRow: View {
    @Binding var scope: IndexingScope
    @Environment(\.cairnTokens) private var t

    private enum Kind: Hashable { case fullLibrary, selectedAlbums }

    private var kindBinding: Binding<Kind> {
        Binding(
            get: { scope.isRestricted ? .selectedAlbums : .fullLibrary },
            set: { newKind in
                switch newKind {
                case .fullLibrary:
                    scope = .fullLibrary
                case .selectedAlbums:
                    // Preserve any prior selection; default to empty
                    // so the "pick at least one" affordance surfaces.
                    scope = .selectedAlbums(scope.albumLocalIdentifiers)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Indexing scope")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Full library** — cairn watches every visible photo on this iPhone. The default.")
                    Text("**Selected albums** — cairn only watches photos in albums you pick. Photos outside those albums are silently ignored: never hashed, never proposed for trash, never sent to your server. Add a photo to a selected album later and cairn picks it up on the next sync.")
                    Text("Useful if you want to manage just one album (Camera Roll, say) and leave synced family albums alone — or if you're recording a demo and don't want your full library on screen.")
                }
                Spacer()
            }
            CairnSegmentedPicker(
                selection: kindBinding,
                options: [
                    .init(value: Kind.fullLibrary,    label: "Full library"),
                    .init(value: Kind.selectedAlbums, label: "Selected albums"),
                ]
            )
            Text(explanation)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch scope {
        case .fullLibrary:
            return "Every visible photo on this iPhone is in scope."
        case .selectedAlbums(let ids):
            if ids.isEmpty {
                return "Pick the albums cairn should watch. Until you pick at least one, no photos are in scope."
            }
            return "cairn watches only the picked albums. Photos elsewhere are ignored."
        }
    }
}

private struct StrictnessRow: View {
    @Binding var strictness: DeletionStrictness
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Deletion strictness")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Cautious** — nothing is trashed automatically. Confirmed deletions surface as Ready to trash, and anything unconfirmed goes to Pending Review, for you to confirm by hand.")
                    Text("**Balanced** — past-quarantine deletions are trashed automatically on the next sync, as long as the run stays within your safety limits. Held deletions still wait out the window; anything over the limit is left for you to review.")
                    Text("**Autonomous** — deletions are trashed automatically on the next sync with no quarantine wait (still within your safety limits). Rely on Immich's 30-day Trash for recovery.")
                }
                Spacer()
            }
            CairnSegmentedPicker(
                selection: $strictness,
                options: [
                    .init(value: DeletionStrictness.strict,     label: "Cautious"),
                    .init(value: DeletionStrictness.trusting,   label: "Balanced"),
                    .init(value: DeletionStrictness.autonomous, label: "Autonomous"),
                ]
            )
            Text(explanation)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(strictness == .autonomous ? t.dangerInk : t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch strictness {
        case .strict:
            return "Nothing is trashed automatically — deletions wait as Ready to trash for you to confirm, and unconfirmed items go to Pending Review."
        case .trusting:
            return "Past-quarantine deletions move to Immich's Trash automatically on sync, within your safety limits. Held deletions still wait out the quarantine window."
        case .autonomous:
            return "Deletions move to Immich's Trash automatically on sync — no quarantine, no confirmation (within your safety limits). Immich keeps items in Trash for 30 days."
        }
    }
}

// MARK: - Quarantine window row

/// Slider for `CairnSettings.quarantineDays`. Thin wrapper over
/// `SliderInputRow` that adapts the `Int` binding to Double and formats
/// `0` as "Off" (the sentinel that collapses the held-by-quarantine
/// bucket entirely).
private struct QuarantineRow: View {
    @Binding var days: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(days) },
            set: { days = Int($0.rounded()) }
        )
    }

    private var summary: String {
        days == 0 ? "Off" : "\(days) day\(days == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("A photo you delete on iPhone won't move to Immich's Trash until this many days have passed — a grace window for accidental mass-offloads (iCloud sync hiccup, \"Remove from this iPhone\") to be caught.")
                    Text("Held photos show up in Pending Review with a countdown. Approve them early if you're sure, or exclude them if you want to keep the server copy.")
                    Text("Set to 0 to move to Trash as soon as a deletion is detected — no safety net.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Quarantine window",
                sub: "Confirmed deletions wait this long before they're eligible to trash. Catches accidental mass-offloads.",
                value: doubleBinding,
                range: Double(CairnSettings.quarantineDaysRange.lowerBound)...Double(CairnSettings.quarantineDaysRange.upperBound),
                step: 1,
                unitSuffix: days == 1 ? " day" : " days",
                format: { $0 == 0 ? "Off" : String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Max retry attempts row

/// Slider for `CairnSettings.maxRetryAttempts`. Caps how many times
/// the auto-drain re-attempts a failed trash before parking the
/// intent. Manual "Retry now" still works on parked intents, so
/// this never permanently blocks the user — just stops the loop
/// when a transient-looking failure is actually persistent.
private struct MaxRetryAttemptsRow: View {
    @Binding var attempts: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(attempts) },
            set: { attempts = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("When a trash run fails (network down, server unreachable, transient 5xx), cairn queues the intent and retries it automatically on the next sync.")
                    Text("After this many attempts, the auto-retry stops and the request is marked stuck. It stays in the queue — tap \u{201C}Retry now\u{201D} on the Status banner once you've fixed the underlying cause.")
                    Text("Default 5 is a balance: enough to ride out a brief outage, not so many that a wrong API key flaps forever.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Max retry attempts",
                sub: "Stop auto-retrying a failed trash after this many tries. Manual retry still works.",
                value: doubleBinding,
                range: Double(CairnSettings.maxRetryAttemptsRange.lowerBound)...Double(CairnSettings.maxRetryAttemptsRange.upperBound),
                step: 1,
                unitSuffix: attempts == 1 ? " attempt" : " attempts",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Count floor row

/// Minimum batch size required before the percent-threshold rail
/// engages. On a small library, 1% can round to 1–2 assets, which is
/// noise — this floor lets the user say "don't even apply the percent
/// check until a run would trash at least N assets."
private struct CountFloorRow: View {
    @Binding var floor: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(floor) },
            set: { floor = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("**Paired with Percent threshold.** The percent safety rail only engages once a run would move at least this many assets to Immich's Trash. Below the floor, the run proceeds without the percent check.")

                    Text("**Why it matters most on small libraries.**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("On a 150-photo library with a 1% threshold, 1% is ≈ 1 photo. A floor of 1 means a run that moves 2 photos to Trash trips the rail — almost every legitimate deletion aborts. Raising the floor lets small real deletions through.")

                    Text("**Concrete scenarios** (assuming Percent = 1%)")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• **150 photos, Floor = 1:** 2 photos to Trash (1.3%) → ABORT. Annoying.")
                    Text("• **150 photos, Floor = 5:** 4 photos to Trash → runs (floor not met). 10 photos (6.7%) → ABORT.")
                    Text("• **150 photos, Floor = 20:** 15 photos to Trash (10%) → runs. 25 (16.7%) → ABORT.")
                    Text("• **10,000 photos, Floor = 5:** 50 photos to Trash (0.5%) → runs. 150 (1.5%) → ABORT. (Floor is essentially moot here — percent alone guards you.)")

                    Text("**Rule of thumb.** Raise the floor for libraries under ~500 photos. Leave at 5 otherwise.")
                        .padding(.top, 2)
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Count floor",
                sub: "Minimum run size before the percent threshold engages. Prevents noisy aborts on small libraries.",
                value: doubleBinding,
                range: 1...50,
                step: 1,
                unitSuffix: floor == 1 ? " asset" : " assets",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Hash concurrency row

/// Lets advanced users tune initial-scan parallelism — the `TaskGroup`
/// ceiling in `PhotoKitPersistentChangeReconciler.hashAssets`. Default
/// 4 is the previous hardcoded value; users with newer iPhones and
/// network-bound (iCloud-optimized) libraries can push it higher,
/// users on older devices can pull it down. Takes effect on the next
/// sync — the reconciler reads it at construction time.
private struct HashConcurrencyRow: View {
    @Binding var value: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { value = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("**Concurrent hashes.** Number of photos the initial scan hashes at the same time. Default 4 is the value previous builds shipped — conservative for older hardware. Modern iPhones (15 Pro, 16, 17) can handle 8–12 comfortably; on an iCloud-heavy library that's where most of the wall-clock win lives, because each parallel slot is doing its own network fetch.")

                    Text("**Trade-offs.**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• Higher saturates iCloud bandwidth and CPU; faster scans.")
                    Text("• Higher raises peak memory — a parallel ProRes video or Live Photo motion track can buffer tens of MB during the fetch.")
                    Text("• Lower reduces memory pressure and leaves more headroom for iOS background slots.")
                    Text("• `1` opts out of parallelism — useful for comparing serial vs parallel timing when diagnosing a slow scan.")

                    Text("**Rule of thumb.** Start at 4. If the initial scan feels slow and you're on a recent device, try 8. Only push past 12 if you've confirmed memory isn't the bottleneck.")
                        .padding(.top, 2)

                    Text("**Takes effect on the next sync** — changing this mid-scan doesn't retroactively widen the active task group.")
                        .padding(.top, 2)
                        .foregroundStyle(t.textMuted)
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Concurrent hashes",
                sub: "How many photos the initial scan hashes at once. Higher = faster on capable devices; lower = gentler on memory.",
                value: doubleBinding,
                range: Double(CairnSettings.hashConcurrencyRange.lowerBound)...Double(CairnSettings.hashConcurrencyRange.upperBound),
                step: 1,
                unitSuffix: value == 1 ? " stream" : " streams",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Thumbnail cache cap row

private struct ThumbnailCacheCapRow: View {
    @Binding var mb: Int

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        SliderInputRow(
            label: "Thumbnail cache cap",
            sub: "Max disk space for cached server thumbnails. Oldest entries evict first.",
            value: doubleBinding,
            range: Double(CairnSettings.thumbnailCacheCapMBRange.lowerBound)...Double(CairnSettings.thumbnailCacheCapMBRange.upperBound),
            step: 10,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer
        )
    }
}

// MARK: - Thumbhash cache cap row

private struct ThumbhashCacheCapRow: View {
    @Binding var mb: Int

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        SliderInputRow(
            label: "Thumbhash cache cap",
            sub: "Max disk space for thumbhash placeholders. Typically negligible.",
            value: doubleBinding,
            range: Double(CairnSettings.thumbhashCapMBRange.lowerBound)...Double(CairnSettings.thumbhashCapMBRange.upperBound),
            step: 1,
            unitSuffix: " MB",
            format: { String(format: "%.0f", $0) },
            parse: NumericInputParse.integer
        )
    }
}

// MARK: - iCloud download limit row

/// Per-asset cap on iCloud-only bytes the **foreground** scan will
/// download. Over-limit assets queue in `DeferredHashStore` and drain
/// in two paths: a small budget during each subsequent foreground scan,
/// or the whole queue during a `BGProcessingTask` slot (power + Wi-Fi,
/// unbounded). Wraps `SliderInputRow` with an `Int ↔ Double` adapter
/// since the slider primitive is Double-typed.
private struct ICloudDownloadLimitRow: View {
    @Binding var mb: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(mb) },
            set: { mb = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("**Foreground soft limit.** Assets larger than this skip the foreground pipeline and wait in the deferred-hashing queue for a later drain. Foreground sync also gives up on any single asset after 60 seconds (prefers to defer than stall).")

                    Text("**Where does the work go?**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• iOS background slot (plugged in + Wi-Fi + idle) → the queue drains with no soft limit and no timeout, so multi-GB videos can finish.")
                    Text("• Or tap **Hash now** below to drain immediately in foreground with the same unlimited-fetch semantics.")

                    Text("**Tuning**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• Lower → faster first sync, more items queued.")
                    Text("• Higher → more items hash upfront, slower syncs on slow networks.")
                    Text("• Use the **Never-touch ceiling** below for assets you never want cairn to try fetching at all.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "iCloud download limit",
                sub: "Foreground cap on per-asset iCloud downloads. Larger assets queue for background hashing instead of blocking the sync.",
                value: doubleBinding,
                range: Double(CairnSettings.iCloudDownloadLimitMBRange.lowerBound)...Double(CairnSettings.iCloudDownloadLimitMBRange.upperBound),
                step: 5,
                unitSuffix: " MB",
                format: { String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Hard ceiling row

/// Hard never-touch ceiling. Assets whose iCloud download would exceed
/// this are **never hashed**, by any path — not foreground, not
/// background. Off by default (nil); the toggle enables the value field
/// below it.
///
/// Tradeoff surfaced in the help popover: excluded assets never enter
/// `observed`, so deletion propagation stops at them. That's the
/// intended semantic ("out of scope by user choice") but important to
/// make explicit — there's no other place this invariant shows up.
private struct HardCeilingRow: View {
    @Binding var mb: Int?
    @Environment(\.cairnTokens) private var t

    /// Remembers the last enabled value so toggling off and back on
    /// restores what the user had set, not the cold-start default.
    /// Seeded from the current `mb` at view construction. Lives across
    /// off/on cycles within the view's lifetime; resets to 1 GB on
    /// fresh launches where the user had previously toggled the
    /// ceiling off (persisting the remembered value across launches
    /// would need a separate field on CairnSettings).
    @State private var rememberedValue: Int

    init(mb: Binding<Int?>) {
        self._mb = mb
        // 1 GB default — cleanly above the soft-limit default of
        // 100 MB so the two thresholds don't collapse into each other.
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
                // Track the live slider value so toggling off after
                // any adjustment captures the latest setting (not just
                // the value at the moment the row was constructed).
                rememberedValue = rounded
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Never-touch ceiling")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Hard skip threshold.** Assets with an iCloud download above this are ignored entirely — never hashed, even in background slots.")
                    Text("Use for multi-GB archived videos you don't want to index. They stay on your server and your iPhone untouched.")
                    Text("Trade-off: ignored assets aren't tracked, so if you later delete them from iPhone, the server copy won't be trashed. That's usually the whole point — but worth knowing.")
                }
                Spacer(minLength: 0)
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    // `t.verified` (cairn's "verified/active" green) for
                    // the on-state. `t.primaryInk` and `t.text` both
                    // resolve to `p.bone` (light cream) in dark mode,
                    // so a tint sourced from either rendered the pill
                    // as light-on-light against the toggle's white
                    // thumb — visually indistinguishable from a single
                    // filled bar. `verified` is the closest semantic
                    // analog to "this switch is enabled" and reads
                    // correctly in both color schemes.
                    .tint(t.verified)
            }
            if mb != nil {
                Text("Assets whose iCloud fetch would exceed this are out-of-scope — never indexed, never proposed for deletion.")
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(
                    value: doubleBinding,
                    in: Double(CairnSettings.iCloudMaxEverBytesMBRange.lowerBound)...Double(CairnSettings.iCloudMaxEverBytesMBRange.upperBound),
                    step: 50
                )
                .tint(t.verified)
                HStack {
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
                Text("Off. Every asset is eligible to hash, however large.")
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

}

// MARK: - Propagation max-age row

/// Optional age cutoff on which phone deletions propagate to the
/// server. When set, deletions of photos older than N days are
/// silently dropped — server copy stays, no quarantine entry. The
/// row mirrors HardCeilingRow's shape (toggle + slider with
/// remembered value) so the on/off semantics read consistently with
/// the never-touch ceiling. Default off; only protects OLD photos —
/// recent deletes still propagate through the normal quarantine.
private struct PropagationMaxAgeRow: View {
    @Binding var days: Int?
    @Environment(\.cairnTokens) private var t

    /// Remembers the last enabled value so toggling off then on
    /// restores the user's prior choice (matching the never-touch
    /// ceiling pattern).
    @State private var rememberedValue: Int

    init(days: Binding<Int?>) {
        self._days = days
        // 365 days (one year) is the suggested starting value when
        // the user first toggles the cutoff on. Wide enough that a
        // "look back at last summer" photo isn't accidentally
        // protected; tight enough that genuinely old photos that the
        // user has already curated on the server side are covered.
        self._rememberedValue = State(initialValue: days.wrappedValue ?? 365)
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { days != nil },
            set: { newValue in
                if newValue {
                    days = rememberedValue
                } else {
                    if let current = days {
                        rememberedValue = current
                    }
                    days = nil
                }
            }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(days ?? CairnSettings.propagationMaxAgeDaysRange.lowerBound) },
            set: { newValue in
                let rounded = Int(newValue.rounded())
                days = rounded
                rememberedValue = rounded
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Don't propagate old deletes")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("**Age cutoff for propagation.** When on, cairn silently ignores phone-delete events for photos taken more than N days ago. Their server copies stay on Immich; no quarantine entry is written.")
                    Text("Use case: you've already curated your Immich library and want to bulk-clean older photos off the phone without those deletions mirroring to the server.")
                    Text("Protects only OLD photos. Recent deletions still propagate through the normal quarantine path — this isn't a global pause.")
                    Text("The age is measured from each photo's capture date (creationDate), not from when cairn first saw it. Scanned-in photos with backdated EXIF will auto-skip too.")
                }
                Spacer(minLength: 0)
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .tint(t.verified)
            }
            if let days {
                Text("Ignores phone-delete events for photos taken more than \(days.formatted(.number)) day\(days == 1 ? "" : "s") ago. Recent deletes still propagate normally.")
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(
                    value: doubleBinding,
                    in: Double(CairnSettings.propagationMaxAgeDaysRange.lowerBound)...Double(CairnSettings.propagationMaxAgeDaysRange.upperBound),
                    step: 30
                )
                .tint(t.verified)
                HStack {
                    Spacer()
                    EditableNumericField(
                        value: doubleBinding,
                        range: Double(CairnSettings.propagationMaxAgeDaysRange.lowerBound)...Double(CairnSettings.propagationMaxAgeDaysRange.upperBound),
                        step: 30,
                        unitSuffix: " days",
                        format: { String(format: "%.0f", $0) },
                        parse: NumericInputParse.integer
                    )
                }
            } else {
                Text("Off. Every phone deletion is in scope for propagation, regardless of when the photo was taken.")
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

// MARK: - Backlog alert row

/// Threshold for the Status backlog-alert banner. Slider step is 5
/// so the user can sweep across 0→500 quickly; the `"Off"` label at
/// 0 makes the opt-out affordance explicit.
private struct BacklogAlertRow: View {
    @Binding var threshold: Int
    @Environment(\.cairnTokens) private var t

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(threshold) },
            set: { threshold = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Spacer(minLength: 0)
                HelpPopover {
                    Text("Status shows a bell-icon banner when the total pending deletions (eligible-to-trash + pending-review + quarantined) reach this count.")
                    Text("The pending-candidates card already shows the running count; this threshold just escalates to a louder alert for users who open cairn infrequently and might miss a growing backlog.")
                    Text("Set to 0 to disable entirely — the existing card is still visible, just no loud alert.")
                }
                .padding(.trailing, 6)
            }
            .padding(.top, 10)
            .padding(.bottom, -4)

            SliderInputRow(
                label: "Backlog alert",
                sub: "Show a Status banner when pending deletions reach this many items.",
                value: doubleBinding,
                range: Double(CairnSettings.deletionBacklogAlertThresholdRange.lowerBound)...Double(CairnSettings.deletionBacklogAlertThresholdRange.upperBound),
                step: 5,
                unitSuffix: threshold == 1 ? " item" : " items",
                format: { $0 == 0 ? "Off" : String(format: "%.0f", $0) },
                parse: NumericInputParse.integer
            )
        }
    }
}

// MARK: - Appearance override row

/// Three-way segmented picker for the system / light / dark color
/// scheme. Writes through to `CairnSettings.appearance`; the
/// app root translates that to `.preferredColorScheme`. Default is
/// "Auto" (follow iOS Settings).
private struct AppearanceRow: View {
    @Binding var appearance: AppearanceOverride
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color scheme")
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
            CairnSegmentedPicker(
                selection: $appearance,
                options: [
                    .init(value: AppearanceOverride.system, label: "Auto"),
                    .init(value: AppearanceOverride.light,  label: "Light"),
                    .init(value: AppearanceOverride.dark,   label: "Dark"),
                ]
            )
            Text(explanation)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch appearance {
        case .system: return "Follows iOS Settings → Display & Brightness."
        case .light:  return "Always light, regardless of the system setting."
        case .dark:   return "Always dark, regardless of the system setting."
        }
    }
}

// MARK: - Time format row

/// Three-way segmented picker for how clock times render across
/// the app — journal tail rows, per-run "time of day," any other
/// surface that prints a clock time. Default is "System" which
/// honors the device's 12/24-hour preference from
/// iOS Settings → General → Date & Time.
private struct TimeFormatRow: View {
    @Binding var format: TimeDisplayFormat
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time format")
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
            CairnSegmentedPicker(
                selection: $format,
                options: [
                    .init(value: TimeDisplayFormat.system, label: "System"),
                    .init(value: TimeDisplayFormat.h12,    label: "12-hour"),
                    .init(value: TimeDisplayFormat.h24,    label: "24-hour"),
                ]
            )
            Text(explanation)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var explanation: String {
        switch format {
        case .system: return "Follows iOS Settings → General → Date & Time."
        case .h12:    return "Always 12-hour with AM/PM (e.g. 5:57 PM)."
        case .h24:    return "Always 24-hour (e.g. 17:57)."
        }
    }
}

// MARK: - Deferred queue row

/// Row showing the current count of queued-for-later assets plus a
/// "Hash now" button that triggers a foreground drain. Empty state:
/// collapses to a muted "Everything indexed" line so the row doesn't
/// imply there's something wrong when the queue is clean.
private struct DeferredQueueRow: View {
    let summary: CairnAppModel.DeferredQueueSummary
    let isSyncing: Bool
    let syncProgress: (hashed: Int, total: Int)?
    let onHashNow: () -> Void
    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deferred hashing")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                HelpPopover {
                    Text("Assets skipped by the foreground iCloud-download limit wait here until they can be hashed without blocking you.")

                    Text("**When does the queue drain?**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• **Background slot** — iOS grants time when the device is plugged in, on Wi-Fi, and idle (often overnight). No timeout in this mode; a 10 GB video can fetch over 15 minutes without getting clipped. iOS controls when it fires — you can't force it.")
                    Text("• **Hash now** — runs the same unlimited-fetch path in foreground, so you can force progress without waiting for iOS. PhotoKit has no partial-download resume, so keep the app open until it finishes (or tap Cancel to pause).")

                    Text("**Common flows**")
                        .fontWeight(.semibold)
                        .padding(.top, 2)
                    Text("• Plug in, connect to Wi-Fi, leave overnight → queue drains via the BG slot.")
                    Text("• \"I want it done now\" → open Settings, tap Hash now, keep the app open.")
                    Text("• \"I have a few 20 GB archive videos I never want indexed\" → turn on **Never-touch ceiling** above at a size that excludes them.")

                    Text("The hard ceiling applies to both paths above. Soft-limit changes apply on the next drain attempt (or tap **Rescan library** to re-evaluate immediately).")
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            if summary.count > 0 {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(summary.count) \(summary.count == 1 ? "asset" : "assets") queued")
                            .font(.cairnScaled(size: 14).monospacedDigit())
                            .foregroundStyle(t.textBody)
                        if summary.totalKnownBytes > 0 {
                            Text("\(formatBytes(summary.totalKnownBytes)) to fetch")
                                .font(.cairnScaled(size: 12))
                                .foregroundStyle(t.textMuted)
                        }
                    }
                    Spacer()
                    hashNowButton
                }
            } else {
                Text("Everything indexed. No assets queued for background hashing.")
                    .font(.cairnScaled(size: 12))
                    .foregroundStyle(t.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    /// The "Hash now" CTA, adapted so a tap produces visible local
    /// feedback: while the drain runs, the button swaps to a spinner +
    /// "Hashing…" (or "Hashing N / M" when progress is known) and is
    /// disabled to prevent re-invocation. Settings has no other
    /// progress surface, so without this the user sees nothing change
    /// on-screen and assumes the tap missed.
    @ViewBuilder
    private var hashNowButton: some View {
        Button(action: onHashNow) {
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(t.primaryInk)
                    Text(syncLabel)
                        .font(.cairnScaled(size: 13, weight: .semibold).monospacedDigit())
                } else {
                    Text("Hash now")
                        .font(.cairnScaled(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(t.primaryInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSyncing ? t.primary.opacity(0.6) : t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .disabled(isSyncing)
    }

    private var syncLabel: String {
        if let progress = syncProgress, progress.total > 0 {
            return "Hashing \(progress.hashed) / \(progress.total)"
        }
        return "Hashing…"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        CairnTimeHelpers.formatBytes(bytes)
    }
}

// MARK: - API key row

/// Row showing a masked key by default, with Reveal/Hide + Copy buttons.
/// Reveal swaps to a tinted surface, surfaces a "Don't screenshot." warning,
/// and auto-hides after 8s (per the prototype). Copy briefly flashes
/// "Copied ✓" before reverting.
///
/// The "Hiding automatically in a few seconds. Don't screenshot." copy is
/// load-bearing — see HANDOFF.md "Keep these copies verbatim."
public struct ApiKeyRow: View {
    public let rawKey: String
    public let masked: String
    public let initiallyRevealed: Bool

    @State private var revealed: Bool
    @State private var copied: Bool = false
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var copyTask: Task<Void, Never>? = nil

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rawKey: String, masked: String, initiallyRevealed: Bool = false) {
        self.rawKey = rawKey
        self.masked = masked
        self.initiallyRevealed = initiallyRevealed
        self._revealed = State(initialValue: initiallyRevealed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API key")
                    .font(.cairnScaled(size: 15))
                    .foregroundStyle(t.textBody)
                Spacer()
                Button(action: toggleReveal) {
                    Text(revealed ? "Hide" : "Reveal")
                        .font(.cairnScaled(size: 12, weight: .medium))
                        .foregroundStyle(revealed ? t.dangerInk : t.infoInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "Hide API key" : "Reveal API key")
                Button(action: copyKey) {
                    Text(copied ? "Copied \u{2713}" : "Copy")
                        .font(.cairnScaled(size: 12, weight: .medium))
                        .foregroundStyle(copied ? t.verifiedInk : t.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy API key")
            }
            Text(revealed ? rawKey : masked)
                .font(.cairnScaled(size: 13, design: .monospaced).monospacedDigit())
                .tracking(revealed ? 0 : 0.5)
                .foregroundStyle(revealed ? t.text : t.textMuted)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(revealed ? t.dangerSoft : t.surfaceAlt)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(revealed ? t.dangerInk.opacity(0.35) : t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(reduceMotion ? .none : .easeInOut(duration: 0.16), value: revealed)
            if revealed {
                HStack(spacing: 5) {
                    Text("\u{26A0}").font(.cairnScaled(size: 10))
                    Text("Hiding automatically in a few seconds. Keep it secret. Keep it safe.")
                        .font(.cairnScaled(size: 11))
                }
                .foregroundStyle(t.dangerInk)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onDisappear {
            // Force-hide on navigation away. Just cancelling the timer
            // (the previous behavior) left `revealed = true` stuck —
            // when the user came back, the key was still on display
            // with no auto-hide timer running. Navigation is a stronger
            // signal than the 8s timer; treat it as immediate hide.
            revealTask?.cancel()
            copyTask?.cancel()
            revealed = false
            copied = false
        }
    }

    private func toggleReveal() {
        revealed.toggle()
        revealTask?.cancel()
        guard revealed else { return }
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled {
                revealed = false
            }
        }
    }

    private func copyKey() {
        #if canImport(UIKit)
        UIPasteboard.general.string = rawKey
        #endif
        copied = true
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Preview helpers

#if DEBUG
private struct SettingsScreenPreviewHost: View {
    @State var settings: CairnSettings = .defaults
    var connection: SettingsScreen.ConnectionStatus = .healthy(latencyMs: 42)
    var excludedCount: Int = 7

    var body: some View {
        SettingsScreen(
            settings: $settings,
            serverUrl: "https://immich.home.arpa",
            apiKey: "imk_live_8a3F2b9cD1eP4qR7sT0uVwXyZ_nH3k",
            apiKeyMasked: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}nH3k",
            excludedCount: excludedCount,
            connectionStatus: connection,
            onOpenExcluded: {},
            onResetIndex: {},
            onClearJournal: {},
            onSignOut: {},
            onRescanLibrary: {}
        )
        .cairnTheme()
    }
}

/// Preview host that mounts the API key row already revealed so the warning
/// state is visible in Xcode previews without manually tapping.
private struct SettingsScreenRevealedPreviewHost: View {
    @State var settings: CairnSettings = .defaults

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AppHeader(title: "Settings")
                KeylineSection("Immich server")
                CairnCard {
                    VStack(spacing: 0) {
                        KeyValRow(
                            "URL",
                            value: "immich.home.arpa",
                            mono: true
                        )
                        RowDivider()
                        ApiKeyRow(
                            rawKey: "imk_live_8a3F2b9cD1eP4qR7sT0uVwXyZ_nH3k",
                            masked: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}nH3k",
                            initiallyRevealed: true
                        )
                    }
                }
            }
        }
        .background(Color.clear)
        .cairnTheme()
    }
}

#Preview("Settings — healthy") {
    SettingsScreenPreviewHost()
}

#Preview("Settings — dark") {
    SettingsScreenPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("Settings — API key revealed") {
    SettingsScreenRevealedPreviewHost()
}
#endif
