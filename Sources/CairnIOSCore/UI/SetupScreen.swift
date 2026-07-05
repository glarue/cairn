import SwiftUI
import CairnCore

/// First-launch onboarding wizard. Mirrors the prototype's
/// `screens/setup.jsx` and adds a strictness step that the prototype
/// pre-dates.
///
/// Why a wizard rather than a single scrolling form: each step asks the
/// user for a *decision* (server identity, OS permissions, safety
/// posture) and we want them to land on each one with full attention.
/// The prototype's pattern — top progress dots, big primary CTA,
/// optional Back — is reproduced here so onboarding feels of-a-piece
/// with the rest of the app.
///
/// Step order:
///   1. Welcome — wordmark + one-sentence pitch (host-owned closure
///      gates the only real action: "Continue").
///   2. Server — URL + API key text fields, with a Verify button that
///      hits a host-supplied closure (real iOS impl should call
///      `ImmichClient.listAllAssets()` and surface its `.count`; the
///      mock returns `1,204` per the prototype).
///   3. Photos permission — explainer + "Grant Full access" button.
///      The closure-based seam keeps `PHPhotoLibrary` out of this view
///      so the package builds on macOS.
///   4. Background refresh — explainer + "Allow" button. Skippable.
///   5. Safety thresholds — sliders for percent + count floor, seeded
///      from `CairnSettings.defaults`.
///   6. Strictness — radio list of `.strict` / `.trusting` / `.autonomous`,
///      copy seeded from the plan doc's "Confirmed-deletion signal
///      (Wave 4) → User-facing messaging" section. This step exists
///      *because* the strictness model is load-bearing for safety; it
///      deserves a dedicated wizard step rather than being buried in
///      Settings. Autonomous mode skips quarantine + review entirely
///      and trusts Immich's 30-day Trash window as the only undo.
///   7. First dry-run — "Every scheduled run is preview-only…" copy
///      from HANDOFF.md, plus the CTA that hands off to the host.
///
/// Microcopy is verbatim from `screens/setup.jsx`, HANDOFF.md, and the
/// plan doc — do not paraphrase without designer review. Source files
/// are cited inline at each copy site.
public struct SetupScreen: View {

    // MARK: - Step model

    /// The eight onboarding steps. Order matches `body`'s switch and
    /// the progress-dots row at the top of the screen.
    public enum Step: Int, CaseIterable, Sendable {
        case welcome
        case server
        case photos
        case background
        case thresholds
        case strictness
        case initialScan
        case firstRun

        var label: String {
            switch self {
            case .welcome:     return "Welcome"
            case .server:      return "Server"
            case .photos:      return "Photos"
            case .background:  return "Background"
            case .thresholds:  return "Safety"
            case .strictness:  return "Strictness"
            case .initialScan: return "Initial scan"
            case .firstRun:    return "First run"
            }
        }
    }

    /// Result of a server-verify probe. Host computes this off the wire
    /// (real impl: `ImmichClient.listAllAssets().count`); the screen
    /// only renders it.
    public struct ServerVerifyResult: Sendable {
        public let success: Bool
        public let assetCount: Int?
        public let errorMessage: String?

        public init(success: Bool, assetCount: Int?, errorMessage: String?) {
            self.success = success
            self.assetCount = assetCount
            self.errorMessage = errorMessage
        }
    }

    /// Outcome of the Photos permission prompt. `.full` is the unrestricted
    /// authorization PhotoKit calls `.authorized`; `.limited` is the
    /// system-level "Selected Photos" mode where PhotoKit transparently
    /// scopes fetches to the user's chosen subset; `.denied` covers
    /// `.denied` and `.restricted` (cairn can't enumerate at all).
    ///
    /// Both `.full` and `.limited` advance the wizard. The Photos step
    /// surfaces an inline note when `.limited` so the user knows their
    /// effective scope and the limited-mode safety guard.
    public enum PhotoAuthOutcome: Sendable, Equatable {
        case full
        case limited
        case denied
    }

    // MARK: - Inputs

    @Binding public var serverUrl: String
    @Binding public var apiKey: String
    @Binding public var settings: CairnSettings

    public let onVerifyServer: @Sendable (String, String) async -> ServerVerifyResult
    public let onRequestPhotosAccess: @Sendable () async -> PhotoAuthOutcome
    /// Read current Photos auth status without prompting. Used to
    /// pre-fill the photos step on appear and to re-poll after the
    /// user grants in iOS Settings and returns to the app. Returns
    /// `nil` for `.notDetermined` (no decision yet).
    public let onPollPhotoAuthStatus: @Sendable () async -> PhotoAuthOutcome?
    public let onRequestBackgroundRefresh: @Sendable () async -> Bool
    /// Fetches the keychain-backed recent-servers list, sorted by
    /// `lastUsedAt` descending. Drives the URL field's autocomplete.
    /// Default = `[]` so previews and tests don't need a host wiring.
    public let onLoadRecentServers: @Sendable () async -> [RecentServerEntry]
    public let onComplete: () -> Void

    /// The step the wizard should open on. Defaults to `.welcome`;
    /// previews override it to render mid-flow steps.
    public let initialStep: Step

    public init(
        serverUrl: Binding<String>,
        apiKey: Binding<String>,
        settings: Binding<CairnSettings>,
        onVerifyServer: @escaping @Sendable (String, String) async -> ServerVerifyResult,
        onRequestPhotosAccess: @escaping @Sendable () async -> PhotoAuthOutcome,
        onPollPhotoAuthStatus: @escaping @Sendable () async -> PhotoAuthOutcome? = { nil },
        onRequestBackgroundRefresh: @escaping @Sendable () async -> Bool,
        onLoadRecentServers: @escaping @Sendable () async -> [RecentServerEntry] = { [] },
        onComplete: @escaping () -> Void,
        initialStep: Step = .welcome
    ) {
        self._serverUrl = serverUrl
        self._apiKey = apiKey
        self._settings = settings
        self.onVerifyServer = onVerifyServer
        self.onRequestPhotosAccess = onRequestPhotosAccess
        self.onPollPhotoAuthStatus = onPollPhotoAuthStatus
        self.onRequestBackgroundRefresh = onRequestBackgroundRefresh
        self.onLoadRecentServers = onLoadRecentServers
        self.onComplete = onComplete
        self.initialStep = initialStep
    }

    // MARK: - Internal state

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Step = .welcome

    // Server step
    @State private var verifying: Bool = false
    @State private var verifyResult: ServerVerifyResult? = nil
    @FocusState private var serverUrlFocused: Bool
    /// Guard so we only clear the pre-filled default URL on the *first*
    /// focus — subsequent focus/unfocus cycles (e.g. dismissing the
    /// keyboard and tapping back) leave the user's typed input alone.
    @State private var serverUrlWasCleared: Bool = false
    /// Snapshot of the keychain-backed recent-servers list, loaded on
    /// the server step's appear. Stays in memory for the rest of the
    /// onboarding flow — small, capped at `RecentServerEntry.maxRetained`.
    @State private var recentServers: [RecentServerEntry] = []

    // Photos / background steps — record outcome so the user can see
    // they completed (or skipped) the step before continuing.
    @State private var photoAuth: PhotoAuthOutcome? = nil
    @State private var photosRequesting: Bool = false
    @State private var backgroundGranted: Bool = false
    @State private var backgroundRequesting: Bool = false

    /// Either `.full` or `.limited` is enough to advance the wizard —
    /// the engine works with whatever PhotoKit exposes; the limited-mode
    /// safety guard lives at the reconciler layer.
    private var photosGranted: Bool {
        switch photoAuth {
        case .full, .limited: return true
        case .denied, .none:  return false
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            stepper
            ScrollView {
                stepContent
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            // Keyboard dismissal: drag the scroll interactively,
            // or tap empty chrome outside the focused field.
            .scrollDismissesKeyboard(.interactively)
            .cairnDismissKeyboardOnBackgroundTap()
            footerNav
        }
        .background(t.bg)
        .onAppear { step = initialStep }
        .task {
            // Preload recent servers once on first mount. Cheap (Keychain
            // read of a small JSON blob) and re-running per-step would
            // race with the user typing. The list refreshes naturally
            // on next launch when verifyServer success bumps an entry.
            recentServers = await onLoadRecentServers()
        }
    }

    // MARK: - Brand + stepper

    private var brandHeader: some View {
        HStack(spacing: 0) {
            CairnWordmark(size: 22, variant: .adaptive)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, CairnLayout.brandHeaderTopPadding)
        .padding(.bottom, 18)
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? t.text.opacity(0.85) : t.divider)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: step)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:     welcomeStep
        case .server:      serverStep
        case .photos:      photosStep
        case .background:  backgroundStep
        case .thresholds:  thresholdsStep
        case .strictness:  strictnessStep
        case .initialScan: initialScanStep
        case .firstRun:    firstRunStep
        }
    }

    // MARK: - Step: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Lockup: onboarding welcome is the single most gaze-dwelled
            // surface in the app, so it uses the detailed multi-color
            // hero art rather than the smaller theme-responsive mark
            // used in nav chrome.
            CairnWordmark(size: 40, variant: .hero)
            // The pitch sentence below opens with `Text.cairnWord` —
            // its own "cairn" announcement. Hiding the hero wordmark
            // from VoiceOver avoids the duplicate read ("cairn,
            // cairn cleans up your Immich server"). Sighted users
            // still see the visual brand mark.
            .accessibilityHidden(true)
            .padding(.bottom, 24)

            // Pitch — verbatim from the brief; this is the elevator
            // sentence used elsewhere in product surfaces too.
            (Text.cairnWord + Text(" cleans up your Immich server when you delete photos on your iPhone."))
                .font(.cairnScaled(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(t.text)
                .lineSpacing(2)
                .padding(.bottom, 14)

            // Privacy reassurance — verbatim from `screens/setup.jsx`
            // step 0 and HANDOFF.md "Keep these copies verbatim".
            Text("Photos never leave your iPhone or your Immich server.")
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.textMuted)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: Server

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Headline + intro — verbatim from `screens/setup.jsx` step 0.
            stepHeadline(Text("Point ") + .cairnWord + Text(" at your Immich server."))
            stepBlurb(Text("Photos never leave your iPhone or your Immich server. ") + .cairnWord + Text(" only sends trash requests, signed with your API key."))

            // Auto-focus the URL field on first arrival. Apple's App
            // Review on iPad Air flagged this screen for "greyed-out
            // onboarding buttons" because the reviewer didn't realize
            // input was required — Verify gates on URL+key, Continue
            // gates on a successful Verify, so both buttons stay
            // muted until the user types something. Focusing the
            // first input pops the keyboard up immediately, which is
            // the clearest "type here" signal we can give.
            //
            // We only force focus on the very first appearance of
            // this step in the session — re-entering after the user
            // dismissed the keyboard shouldn't re-pop it.

            fieldLabel("Server URL")
            CairnCard {
                HStack(spacing: 0) {
                    Image(systemName: "server.rack")
                        .font(.cairnScaled(size: 14))
                        .foregroundStyle(t.textMuted)
                        .padding(.leading, 14)
                    TextField("immich.home.arpa", text: $serverUrl)
                        .textFieldStyle(.plain)
                        .font(.cairnScaled(size: 14, design: .monospaced))
                        .foregroundStyle(t.textBody)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .focused($serverUrlFocused)
                        .onChange(of: serverUrlFocused) { _, nowFocused in
                            // First-focus clear: the field ships pre-filled
                            // with a scaffold URL so unused surfaces (the
                            // Status subhead) have something to render.
                            // When the user actually taps in, wipe so they
                            // don't have to select-all-and-delete before
                            // typing their real URL. Guarded so they can
                            // unfocus and refocus without losing their own
                            // in-progress input.
                            if nowFocused && !serverUrlWasCleared {
                                serverUrlWasCleared = true
                                serverUrl = ""
                            }
                        }
                        .onChange(of: serverUrl) { _, _ in verifyResult = nil }
                }
            }
            .padding(.horizontal, -20) // CairnCard adds its own 16 inset; counter our 20.
            .padding(.bottom, recentSuggestions.isEmpty ? 16 : 8)

            recentServerSuggestions
                .padding(.horizontal, -20)
                .padding(.bottom, recentSuggestions.isEmpty ? 0 : 16)

            fieldLabel("API key")
            CairnCard {
                ApiKeyInput(
                    text: $apiKey,
                    placeholder: "paste key from Immich account settings",
                    onChange: { verifyResult = nil }
                )
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 10)

            // Scopes hint — verbatim copy + monospace token list from
            // `screens/setup.jsx` step 0. Only the API-key-usable
            // scopes appear here. Incremental sync uses a separate
            // session-auth path (Settings → Advanced → Sign in to
            // Immich) and doesn't need anything extra on the key —
            // see ARCHITECTURE.md "API endpoints" for the discovery
            // that `sync.*` permissions exist on the server but
            // aren't reachable via API key auth.
            (Text("Scopes required: ")
                + monoCode("asset.read") + Text(", ")
                + monoCode("asset.view") + Text(", ")
                + monoCode("asset.download") + Text(", ")
                + monoCode("asset.delete") + Text(", ")
                + monoCode("tag.create") + Text(", ")
                + monoCode("tag.asset") + Text(", ")
                + monoCode("tag.read") + Text("."))
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
                .lineSpacing(3)
                .padding(.bottom, 18)
                .fixedSize(horizontal: false, vertical: true)

            verifyArea
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: step) {
            // Auto-focus rationale: see comment at top of serverStep.
            // The `task(id: step)` modifier fires when this step
            // becomes the visible content, not on every body
            // recomposition, so we don't fight the user if they
            // dismiss the keyboard and tap somewhere else.
            guard step == .server, !serverUrlWasCleared else { return }
            // One-frame delay lets SwiftUI finish placing the field
            // before the focus binding fires; without it, FocusState
            // can silently drop the request during the step
            // transition's `withAnimation`.
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { serverUrlFocused = true }
        }
    }

    private func monoCode(_ s: String) -> Text {
        Text(s).font(.cairnScaled(size: 11.5, design: .monospaced))
    }

    @ViewBuilder
    private var verifyArea: some View {
        if let result = verifyResult, result.success {
            // Success callout — phrasing mirrors `screens/setup.jsx`
            // ("1,204 assets visible to this key").
            Callout(.verified, icon: "checkmark.circle") {
                let count = result.assetCount.map { $0.formatted(.number) } ?? "0"
                (Text("Connected. ").fontWeight(.semibold)
                    + Text("\(count) assets visible to this key."))
            }
        } else if let result = verifyResult, !result.success {
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't connect.").fontWeight(.semibold)
                    Text(result.errorMessage ?? "Check the URL and API key, then try again.")
                        .opacity(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            primaryButton(
                title: verifying ? "Verifying…" : "Verify connection",
                tone: .secondary,
                disabled: verifying || serverUrl.isEmpty || apiKey.isEmpty,
                action: runVerify
            )
        }
    }

    private func runVerify() {
        verifying = true
        let url = serverUrl
        let key = apiKey
        Task {
            let result = await onVerifyServer(url, key)
            await MainActor.run {
                self.verifyResult = result
                self.verifying = false
            }
        }
    }

    // MARK: - Recent-server autocomplete

    /// Suggestions filtered against `serverUrl` using the textbook URL
    /// autocomplete ranking: prefix-match on the canonicalized URL
    /// outranks host-substring outranks anywhere-substring; recency
    /// (`lastUsedAt` desc) breaks ties. Empty input returns the full
    /// recents list (most-recent first) so the user sees options
    /// before typing anything. Returns up to four — beyond that the
    /// list crowds the URL field on small devices.
    ///
    /// Rationale: at this list size (cap = 10) the work is microseconds
    /// regardless of algorithm. Substring + prefix-priority + recency
    /// is what browser omniboxes use; fzf-style subsequence matching
    /// is the next tier but overkill for short, exact-typed URLs.
    /// Levenshtein/Jaro-Winkler are wrong for this domain.
    private var recentSuggestions: [RecentServerEntry] {
        let needle = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // No input → render the full list newest-first.
        guard !needle.isEmpty else {
            return Array(recentServers.prefix(4))
        }
        struct Scored { let entry: RecentServerEntry; let rank: Int }
        let scored: [Scored] = recentServers.compactMap { entry in
            let canonical = RecentServerEntry.canonicalize(entry.url).lowercased()
            // Skip entries that match exactly — re-suggesting what's
            // already typed adds visual noise without value.
            guard canonical != needle else { return nil }
            if canonical.hasPrefix(needle) { return Scored(entry: entry, rank: 0) }
            if let host = URLComponents(string: canonical)?.host,
               host.contains(needle) {
                return Scored(entry: entry, rank: 1)
            }
            if canonical.contains(needle) { return Scored(entry: entry, rank: 2) }
            return nil
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.entry.lastUsedAt > rhs.entry.lastUsedAt
        }
        return Array(sorted.prefix(4)).map(\.entry)
    }

    @ViewBuilder
    private var recentServerSuggestions: some View {
        if !recentSuggestions.isEmpty {
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(recentSuggestions.enumerated()), id: \.element.url) { idx, entry in
                        Button(action: { applySuggestion(entry) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.cairnScaled(size: 12))
                                    .foregroundStyle(t.textHint)
                                Text(entry.url)
                                    .font(.cairnScaled(size: 13, design: .monospaced))
                                    .foregroundStyle(t.textBody)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.cairnScaled(size: 11))
                                    .foregroundStyle(t.textHint)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < recentSuggestions.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
        }
    }

    private func applySuggestion(_ entry: RecentServerEntry) {
        serverUrl = entry.url
        serverUrlWasCleared = true   // suppress first-focus auto-clear
        serverUrlFocused = false
        verifyResult = nil
    }

    // MARK: - Step: Photos

    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline("Grant Photos access.")
            stepBlurb(Text.cairnWord + Text(" reads each photo once to compute a SHA1 fingerprint — the same identifier Immich uses. Bytes are hashed in memory and discarded; only the fingerprints leave your iPhone, and only to your own Immich server."))

            CairnCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.cairnScaled(size: 18))
                        .foregroundStyle(t.textBody)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full or limited access")
                            .font(.cairnScaled(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        (Text.cairnWord + Text(" works with either. Full access lets it manage your whole library; with limited access it manages only the photos you select in the system picker."))
                            .font(.cairnScaled(size: 12.5))
                            .foregroundStyle(t.textMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 16)

            switch photoAuth {
            case .full:
                Callout(.verified, icon: "checkmark.circle") {
                    Text("Full access granted.").fontWeight(.semibold)
                }
            case .limited:
                VStack(alignment: .leading, spacing: 10) {
                    Callout(.verified, icon: "checkmark.circle") {
                        Text("Limited access granted.").fontWeight(.semibold)
                    }
                    // The limited-mode safety guard at the reconciler
                    // layer requires a PhotoKit `deletedLocalIdentifiers`
                    // event to propagate a deletion to Immich. Surface
                    // the implication so the user isn't surprised when
                    // toggling the system "Selected Photos" picker
                    // doesn't immediately mass-trash on Immich.
                    Callout(.pending, icon: "info.circle") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Heads up about limited access.").fontWeight(.semibold)
                            (Text.cairnWord + Text(" only manages the photos you've shared. To keep you safe from accidental deletions, only photos you actively trash in Photos.app will propagate to Immich — changing your Selected Photos selection won't. You can switch to full access anytime in iOS Settings."))
                                .font(.cairnScaled(size: 12.5))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            case .denied, .none:
                // When status is already `.denied`, the system won't
                // re-prompt — the request closure will deep-link to
                // iOS Settings instead. Reflect that in the button copy
                // so the user knows what's about to happen.
                primaryButton(
                    title: photosRequesting
                        ? "Requesting…"
                        : (photoAuth == .denied ? "Open Photos in iOS Settings" : "Allow Photos access"),
                    tone: .primary,
                    disabled: photosRequesting,
                    action: requestPhotos
                )
                if photoAuth == .denied {
                    Callout(.pending, icon: "exclamationmark.triangle") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Access not granted.").fontWeight(.semibold)
                            (Text.cairnWord + Text(" needs at least limited Photos access to find deleted photos. Tap above to open iOS Settings and grant access — this screen will update when you return."))
                                .font(.cairnScaled(size: 12.5))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: step) {
            // Pre-poll the system Photos auth status when this step
            // first appears so an existing decision (denied or
            // already-granted) is reflected without requiring a tap.
            // Keying the task on `step` re-runs it whenever the user
            // navigates back to the photos step.
            guard step == .photos else { return }
            if let polled = await onPollPhotoAuthStatus() {
                await MainActor.run { self.photoAuth = polled }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // User may have just returned from iOS Settings after
            // granting/changing access. Re-poll so the UI catches up
            // without a manual tap.
            guard newPhase == .active, step == .photos else { return }
            Task {
                if let polled = await onPollPhotoAuthStatus() {
                    await MainActor.run { self.photoAuth = polled }
                }
            }
        }
    }

    private func requestPhotos() {
        photosRequesting = true
        Task {
            let outcome = await onRequestPhotosAccess()
            await MainActor.run {
                self.photoAuth = outcome
                self.photosRequesting = false
            }
        }
    }

    // MARK: - Step: Background

    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline(Text("Let ") + .cairnWord + Text(" check in periodically."))
            // Tone is taken from the plan doc's framing of background
            // refresh as load-bearing-but-skippable safety scaffolding.
            stepBlurb(Text.cairnWord + Text(" uses Background App Refresh to pick up deletions while the app is closed. You can skip this — ") + .cairnWord + Text(" still works in the foreground."))

            CairnCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.cairnScaled(size: 18))
                        .foregroundStyle(t.textBody)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background App Refresh")
                            .font(.cairnScaled(size: 14, weight: .medium))
                            .foregroundStyle(t.textBody)
                        (Text("iOS decides exactly when. ") + .cairnWord + Text(" never moves anything to Trash automatically — every scheduled run is preview-only."))
                            .font(.cairnScaled(size: 12.5))
                            .foregroundStyle(t.textMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 16)

            if backgroundGranted {
                Callout(.verified, icon: "checkmark.circle") {
                    Text("Background refresh enabled.").fontWeight(.semibold)
                }
            } else {
                VStack(spacing: 10) {
                    primaryButton(
                        title: backgroundRequesting ? "Requesting…" : "Allow",
                        tone: .primary,
                        disabled: backgroundRequesting,
                        action: requestBackground
                    )
                    quietButton(title: "Skip for now") {
                        advance()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestBackground() {
        backgroundRequesting = true
        Task {
            let granted = await onRequestBackgroundRefresh()
            await MainActor.run {
                self.backgroundGranted = granted
                self.backgroundRequesting = false
            }
        }
    }

    // MARK: - Step: Thresholds

    private var thresholdsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline("Set safety thresholds.")
            // Verbatim from `screens/setup.jsx` step 2.
            stepBlurb(Text("Defaults are conservative. A run that would move more than the threshold to Immich's Trash stops and asks first. Nothing's permanent — Immich keeps deleted assets for 30 days."))

            CairnCard {
                VStack(spacing: 0) {
                    sliderRow(
                        label: "Percent cap",
                        value: Binding(
                            get: { settings.maxDeletePercent },
                            set: { settings.maxDeletePercent = $0 }
                        ),
                        range: 0.1 ... 10.0,
                        step: 0.1,
                        unitSuffix: "%",
                        format: { String(format: "%.1f", $0) },
                        parse: NumericInputParse.decimal,
                        sub: "of matched assets"
                    )
                    RowDivider()
                    sliderRow(
                        label: "Count floor",
                        value: Binding(
                            get: { Double(settings.minDeleteFloor) },
                            set: { settings.minDeleteFloor = Int($0.rounded()) }
                        ),
                        range: 1 ... 50,
                        step: 1,
                        unitSuffix: "",
                        format: { String(format: "%.0f", $0) },
                        parse: NumericInputParse.integer,
                        sub: "minimum candidates before the cap kicks in"
                    )
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 12)

            quietButton(title: "Reset to defaults") {
                settings.maxDeletePercent = CairnSettings.defaults.maxDeletePercent
                settings.minDeleteFloor = CairnSettings.defaults.minDeleteFloor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Onboarding slider row. Retains the larger display-size number
    /// for emphasis (this is the user's first exposure to these
    /// values) but the number doubles as an editable field via the
    /// reusable `EditableNumericField` — so power users can type the
    /// exact value they want without scrubbing. Falls back to a plain
    /// label when `unitSuffix` / `format` / `parse` aren't supplied
    /// (legacy call sites).
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unitSuffix: String,
        format: @escaping (Double) -> String,
        parse: @escaping (String) -> Double?,
        sub: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(t.textMuted)
                Spacer()
                EditableNumericField(
                    value: value,
                    range: range,
                    step: step,
                    unitSuffix: unitSuffix,
                    format: format,
                    parse: parse
                )
            }
            Slider(value: value, in: range, step: step)
                // Match every other slider in the app (Settings rows,
                // InitialScan) on the active-green fill, rather than
                // t.primary which read as a slightly different tint.
                .tint(t.verified)
            Text(sub)
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Step: Strictness

    private var strictnessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline(Text("Pick how strict ") + .cairnWord + Text(" is."))
            // Post-Wave-4 copy: the original plan-doc seed referenced
            // "Recently Deleted album" as the positive signal, but
            // Wave 4 pivoted to `PHPhotoLibrary.fetchPersistentChanges`
            // (iOS fires `deletedLocalIdentifiers` at soft-delete
            // time). Copy reframed around "iOS confirms a deletion"
            // — same strict/trusting split, accurate mechanism.
            stepBlurb(Text.cairnWord + Text(" watches your Photos library and sees deletions as they happen. When iOS confirms a photo was deleted on this device, ") + .cairnWord + Text(" moves the matching photo to Immich's Trash. If ") + .cairnWord + Text(" ever misses a deletion event — the app didn't run for weeks, for example — it falls back to a more conservative inference."))

            // Radio list inlines each mode's explanation with the
            // option itself — the strict/trusting choice is load-
            // bearing in onboarding, and a separate tooltip card
            // below the picker disrupted the left-to-right-then-down
            // reading flow.
            CairnRadioList(
                selection: Binding(
                    get: { settings.deletionStrictness },
                    set: { settings.deletionStrictness = $0 }
                ),
                options: [
                    .init(
                        value: DeletionStrictness.strict,
                        title: "Cautious",
                        subtitle: "Nothing is trashed without your say-so. When iOS confirms a deletion the photo becomes Ready to trash for you to confirm; anything unconfirmed waits in Pending Review. Recommended with iCloud Photo Library and iCloud-Optimized Storage."
                    ),
                    .init(
                        value: DeletionStrictness.trusting,
                        title: "Balanced",
                        subtitle: "After the quarantine window, cairn moves matching server photos to Immich's Trash automatically — no tap needed — as long as the run stays within your safety limits. Anything over the limit is left for you to review. The default."
                    ),
                    .init(
                        value: DeletionStrictness.autonomous,
                        title: "Autonomous",
                        subtitle: "Skip the quarantine wait and confirmation. Every detected deletion moves to Immich's Trash on the next sync (still within your safety limits). The only safety net is Immich's 30-day Trash window. Pick this only if you'd rather catch mistakes after the fact."
                    ),
                ]
            )
            .padding(.bottom, 12)

            Text("You can change this any time in Settings.")
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: Initial scan

    /// Pick how the very first scan bootstraps `LocalHashStore`. The
    /// choice is between trusting Immich's server-computed checksums
    /// for matching uploads (fast, default) and recomputing every
    /// SHA1 locally (slower but every value is locally-verified).
    /// Lives one step before `.firstRun` because it directly shapes
    /// what the user is about to see — picking "Full local hashing"
    /// commits them to a multi-hour wait on an iCloud-Optimized
    /// library; the choice deserves explicit framing rather than a
    /// hidden default.
    private var initialScanStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeadline(Text("Pick how the first scan runs."))
            stepBlurb(Text.cairnWord + Text(" needs the SHA1 of every photo before it can match phone-side and server-side libraries. It can either compute every hash locally, or trust the hashes Immich already computed at upload time. Local hashing is what ") + .cairnWord + Text(" has always done; the trust path is faster but means ") + .cairnWord + Text(" doesn't verify those checksums itself."))

            CairnRadioList(
                selection: $settings.fastInitialScan,
                options: [
                    .init(
                        value: false,
                        title: "Hash everything locally",
                        subtitle: "Compute the SHA1 of every phone photo on this device before the first scan completes. Slower (especially with iCloud-Optimized Storage — originals get downloaded as needed) but every checksum is verified by cairn itself."
                    ),
                    .init(
                        value: true,
                        title: "Trust Immich's hashes for matching photos",
                        subtitle: "Match phone photos to the server by filename and capture date. Where exactly one server photo matches, use its SHA1 instead of re-hashing locally. Ambiguous matches and anything Immich didn't have (web uploads, photos from other devices) still hash here. Imputed entries are flagged in cairn's cache. On iCloud-Optimized libraries this can drop the first scan from hours to seconds."
                    ),
                ]
            )
            .padding(.bottom, 12)

            Text("You can change this any time in Settings.")
                .font(.cairnScaled(size: 12))
                .foregroundStyle(t.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step: First scan

    private var firstRunStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Post-CLI copy rewrite: the original headline said "First
            // run is always a dry-run," but the orchestrator's real
            // `dryRun` flag is never set from iOS — every interactive
            // run calls `TrashOrchestrator.run(dryRun: false)`. The
            // safety comes from the sheet + explicit confirm, not
            // from the orchestrator. Reframe around that mechanism.
            stepHeadline("You'll see the list before anything syncs.")
            stepBlurb(Text.cairnWord + Text(" scans your library, indexes every asset, and shows exactly what would move to Immich's Trash. Nothing happens on the server until you confirm."))

            // The "what happens next" card — preserves the prototype's
            // 4-step preview so the user knows the shape of the work.
            CairnCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("WHAT HAPPENS NEXT")
                            .font(.cairnScaled(size: 11, weight: .semibold))
                            .tracking(0.9)
                            .foregroundStyle(t.textMuted)
                        Spacer()
                        Text("~40s")
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textHint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                    ForEach(Array([
                        "Hash on-device photos (lazy, cached)",
                        "Pull server asset checksums",
                        "Compute diff",
                        "Show preview → you confirm",
                    ].enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().fill(t.surfaceAlt).frame(width: 20, height: 20)
                                Text("\(idx + 1)")
                                    .font(.cairnScaled(size: 11, weight: .medium))
                                    .foregroundStyle(t.textBody)
                            }
                            Text(line)
                                .font(.cairnScaled(size: 13))
                                .foregroundStyle(t.textBody)
                                .padding(.top, 2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if idx < 3 {
                            RowDivider()
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 14)

            Callout(.info, icon: "eye") {
                Text("Every scheduled run is preview-only. You confirm before anything moves to Trash.")
            }
            .padding(.bottom, 16)

            primaryButton(
                title: "Finish setup",
                tone: .primary,
                disabled: false,
                action: onComplete
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer nav

    private var footerNav: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                quietButton(title: "Back") { goBack() }
                    .frame(maxWidth: .infinity)
            }
            if step != .firstRun {
                // Keep Continue visually-primary at all times. Steps
                // that need extra input (server, photos) handle the
                // missing-state case by focusing the relevant field
                // or showing a hint, rather than rendering as a dead
                // grey button. Apple's App Review on iPad flagged a
                // greyed-out Continue as "buttons greyed out — bug";
                // making the tap always do something useful avoids
                // the same misread.
                primaryButton(
                    title: "Continue",
                    tone: .primary,
                    disabled: false,
                    action: tryAdvance
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    /// Continue's tap handler. If the current step's gate is
    /// satisfied, advance. Otherwise nudge the user toward the
    /// missing input (focus a field, hint at the action) instead of
    /// silently no-op'ing.
    private func tryAdvance() {
        if canAdvance {
            advance()
            return
        }
        switch step {
        case .server:
            // Most common cause of not-yet-canAdvance: URL or key
            // empty, OR both filled but Verify hasn't been run yet.
            // Run Verify on the user's behalf when fields are
            // present; otherwise focus the empty field.
            if serverUrl.isEmpty {
                serverUrlFocused = true
            } else if apiKey.isEmpty {
                // Can't reach ApiKeyInput's private FocusState from
                // here, but dismissing URL focus shifts the visual
                // emphasis to the key field — the obvious next tap.
                serverUrlFocused = false
            } else if !verifying {
                runVerify()
            }
        case .photos:
            // Photos gate is "permission granted." Triggering the
            // same request the page's primary CTA fires makes
            // Continue an alias for the in-step action.
            if !photosRequesting {
                requestPhotos()
            }
        default:
            // welcome / background / thresholds / strictness all
            // have canAdvance == true; we shouldn't get here.
            break
        }
    }

    /// Per-step gating for the "Continue" button. Steps with intra-step
    /// state (server fields not yet verified) gate Continue here; steps
    /// that own their own confirmation (Photos, Background) pass-through
    /// so the user can still advance after granting or skipping.
    private var canAdvance: Bool {
        switch step {
        case .welcome:     return true
        case .server:      return verifyResult?.success == true
        case .photos:      return photosGranted
        case .background:  return true   // optional; quiet "Skip for now" also advances
        case .thresholds:  return true
        case .strictness:  return true
        case .initialScan: return true
        case .firstRun:    return true   // not shown — firstRun has its own CTA
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onComplete()
            return
        }
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { step = next }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.18)) { step = prev }
    }

    // MARK: - Shared step chrome

    private func stepHeadline(_ text: String) -> some View { stepHeadline(Text(text)) }
    private func stepBlurb(_ text: String) -> some View { stepBlurb(Text(text)) }

    private func stepHeadline(_ text: Text) -> some View {
        text
            .font(.cairnScaled(size: 26, weight: .semibold))
            .tracking(-0.5)
            .foregroundStyle(t.text)
            .lineSpacing(2)
            .padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepBlurb(_ text: Text) -> some View {
        text
            .font(.cairnScaled(size: 14))
            .foregroundStyle(t.textMuted)
            .lineSpacing(3)
            .padding(.bottom, 22)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.cairnScaled(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(t.textMuted)
            .padding(.bottom, 6)
    }

    // MARK: - Buttons

    private enum ButtonTone { case primary, secondary }

    private func primaryButton(
        title: String,
        tone: ButtonTone,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { if !disabled { action() } }) {
            Text(title)
                .font(.cairnScaled(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(foreground(for: tone, disabled: disabled))
                .background(background(for: tone, disabled: disabled))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func quietButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.cairnScaled(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(t.textBody)
                .background(t.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func foreground(for tone: ButtonTone, disabled: Bool) -> Color {
        if disabled { return t.textMuted }
        switch tone {
        case .primary:   return t.primaryInk
        case .secondary: return t.textBody
        }
    }

    private func background(for tone: ButtonTone, disabled: Bool) -> Color {
        if disabled { return t.surfaceAlt }
        switch tone {
        case .primary:   return t.primary
        case .secondary: return t.surfaceAlt
        }
    }
}

// MARK: - Preview

#if DEBUG
/// Wrapper view that owns `@State` so previews can wire bindings into
/// `SetupScreen`. Without this, previews can't supply `Binding`s.
private struct SetupPreviewHarness: View {
    let initialStep: SetupScreen.Step
    let preVerified: Bool
    @State private var serverUrl: String = "https://immich.home.arpa"
    @State private var apiKey: String = "demo-api-key-placeholder"
    @State private var settings: CairnSettings = .defaults

    var body: some View {
        SetupScreen(
            serverUrl: $serverUrl,
            apiKey: $apiKey,
            settings: $settings,
            onVerifyServer: { _, _ in
                .init(success: true, assetCount: 1_204, errorMessage: nil)
            },
            onRequestPhotosAccess: { .full },
            onRequestBackgroundRefresh: { true },
            onComplete: { },
            initialStep: initialStep
        )
        .cairnTheme()
    }
}

#Preview("Setup — welcome") {
    SetupPreviewHarness(initialStep: .welcome, preVerified: false)
}

#Preview("Setup — server") {
    SetupPreviewHarness(initialStep: .server, preVerified: false)
}

#Preview("Setup — photos") {
    SetupPreviewHarness(initialStep: .photos, preVerified: true)
}

#Preview("Setup — thresholds") {
    SetupPreviewHarness(initialStep: .thresholds, preVerified: true)
}

#Preview("Setup — strictness") {
    SetupPreviewHarness(initialStep: .strictness, preVerified: true)
}

#Preview("Setup — initial scan") {
    SetupPreviewHarness(initialStep: .initialScan, preVerified: true)
}

#Preview("Setup — first dry-run") {
    SetupPreviewHarness(initialStep: .firstRun, preVerified: true)
}

#Preview("Setup — strictness (dark)") {
    SetupPreviewHarness(initialStep: .strictness, preVerified: true)
        .preferredColorScheme(.dark)
}
#endif
