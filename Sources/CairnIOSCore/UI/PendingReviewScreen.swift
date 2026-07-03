import SwiftUI
import CairnCore

/// Pending-review surface. Holds to the prototype's design language:
/// `AppHeader`, `KeylineSection`, `CairnCard`, `MockAssetThumb`,
/// `Callout`, per-row bordered buttons that match `ExcludedScreen`'s
/// "Remove" chip.
///
/// Content:
///   - Mass-offload banner at the top when the last scan's burst exceeds
///     `CairnAppModel.massOffloadThreshold`. Two primary affordances:
///     "Bulk exclude" (route through `actions.bulkExcludeRecentOffload`)
///     and an implicit "Review one-by-one" (the rest of the screen).
///   - "Queued" section — candidates held by quarantine, each with a
///     countdown ("Trashes in N days" → "Ready to trash") showing when
///     the next sync will move them to Immich's Trash.
///   - "Unconfirmed" section — candidates with no positive deletion signal
///     at all. Only appears in `.strict` mode; `.trusting` sends these
///     straight to trash candidates so they never land here.
///
/// **Grouping by logical photo.** Rows are grouped by
/// `(originalFileName, fileCreatedAt)` so an edit that produces a second
/// Immich asset (same filename + creation, different SHA1) renders as a
/// single card with a "N versions" badge. Tapping the card expands inline
/// to show every version with a per-version label ("Original" when the
/// checksum is anchored as a `firstObserved` value for a live local
/// identifier, "Retired Nd ago" when it has a confirmed-deleted timestamp).
///
/// Per-row affordances mirror the Excluded screen's compact button style:
/// three icon chips (trash / dismiss / shield) on the trailing edge of the
/// collapsed card; they apply to every version in the group.
public struct PendingReviewScreen: View {

    public let heldGroups: [PendingReviewGroup]
    public let unconfirmedGroups: [PendingReviewGroup]
    /// Quarantine countdown per checksum. Populated by the host from
    /// `LiveReconciliation.confirmedDeletedAt`. Missing entries skip the
    /// countdown (falls back to "held").
    public let confirmedDeletedAt: [String: Date]
    public let quarantineDays: Int
    public let massOffloadCount: Int
    public let showsMassOffloadBanner: Bool
    /// Count of items in this list that are "recycled exclusions" —
    /// previously excluded (typically via restore-via-cairn) and now
    /// re-deleted on the phone. Drives an explanatory callout so the
    /// user understands why these aren't in quarantine like normal
    /// new deletes. Zero hides the banner.
    public let recycledExclusionCount: Int
    /// True when the most recent scan re-enumerated the library because
    /// the persistent-change token expired. Surfaces a banner explaining
    /// that the candidates below come from diff-only detection (no
    /// quarantine clock), and takes precedence over the mass-offload
    /// banner when both would otherwise show.
    public let showsTokenExpiryBanner: Bool
    public let onBack: () -> Void
    /// Approve a set of base64-SHA1 checksums for immediate trashing.
    public let onApprove: ([String]) -> Void
    /// Add a set of checksums to the exclusion list.
    public let onExclude: ([String]) -> Void
    /// Remove a set of checksums from the pending list without excluding.
    public let onDismiss: ([String]) -> Void
    public let onBulkExcludeOffload: () -> Void

    @Environment(\.cairnTokens) private var t
    @State private var pendingAction: PendingAction?
    @State private var selectionMode: Bool = false
    /// Selected checksums (base64). Multi-version groups put every
    /// version's checksum into this set as one toggle.
    @State private var selectedChecksums: Set<String> = []
    /// Group keys currently expanded inline.
    @State private var expandedGroupKeys: Set<PendingReviewGroup.GroupKey> = []
    /// Asset whose thumbnail is currently zoomed in the overlay. Tap
    /// outside the overlay (or any other thumbnail) to dismiss. Mirrors
    /// `DryRunSheet`'s `zoomedCandidate` pattern so the interaction
    /// feels consistent across screens.
    @State private var zoomedAsset: ServerAsset?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum PendingAction: Identifiable {
        case approveGroup(group: PendingReviewGroup)
        case excludeGroup(group: PendingReviewGroup)
        case dismissGroup(group: PendingReviewGroup)
        case approveVersion(checksum: String, label: String)
        case excludeVersion(checksum: String, label: String)
        case dismissVersion(checksum: String, label: String)
        case bulkOffload(count: Int)
        case bulkApprove(count: Int)
        case bulkExcludeSelected(count: Int)
        case bulkDismiss(count: Int)
        case trashAll(count: Int)

        var id: String {
            switch self {
            case .approveGroup(let g): return "approve-group-\(g.key.stableID)"
            case .excludeGroup(let g): return "exclude-group-\(g.key.stableID)"
            case .dismissGroup(let g): return "dismiss-group-\(g.key.stableID)"
            case .approveVersion(let c, _): return "approve-version-\(c)"
            case .excludeVersion(let c, _): return "exclude-version-\(c)"
            case .dismissVersion(let c, _): return "dismiss-version-\(c)"
            case .bulkOffload(let n): return "bulk-\(n)"
            case .bulkApprove(let n): return "bulk-approve-\(n)"
            case .bulkExcludeSelected(let n): return "bulk-exclude-\(n)"
            case .bulkDismiss(let n): return "bulk-dismiss-\(n)"
            case .trashAll(let n): return "trash-all-\(n)"
            }
        }
    }

    public init(
        heldGroups: [PendingReviewGroup] = [],
        unconfirmedGroups: [PendingReviewGroup] = [],
        confirmedDeletedAt: [String: Date] = [:],
        quarantineDays: Int = 14,
        massOffloadCount: Int = 0,
        showsMassOffloadBanner: Bool = false,
        showsTokenExpiryBanner: Bool = false,
        recycledExclusionCount: Int = 0,
        onBack: @escaping () -> Void = {},
        onApprove: @escaping ([String]) -> Void = { _ in },
        onExclude: @escaping ([String]) -> Void = { _ in },
        onDismiss: @escaping ([String]) -> Void = { _ in },
        onBulkExcludeOffload: @escaping () -> Void = {}
    ) {
        self.heldGroups = heldGroups
        self.unconfirmedGroups = unconfirmedGroups
        self.confirmedDeletedAt = confirmedDeletedAt
        self.quarantineDays = quarantineDays
        self.massOffloadCount = massOffloadCount
        self.showsMassOffloadBanner = showsMassOffloadBanner
        self.showsTokenExpiryBanner = showsTokenExpiryBanner
        self.recycledExclusionCount = recycledExclusionCount
        self.onBack = onBack
        self.onApprove = onApprove
        self.onExclude = onExclude
        self.onDismiss = onDismiss
        self.onBulkExcludeOffload = onBulkExcludeOffload
    }

    /// Convenience init that builds groups from raw `ServerAsset` lists.
    /// `CairnAppRoot` uses this; tests prefer the group-list init so they
    /// can assert on grouping output independently from the view.
    public init(
        heldAssets: [ServerAsset],
        unconfirmedAssets: [ServerAsset],
        firstObservedAnchors: Set<Checksum> = [],
        confirmedDeletedAt: [Checksum: Date] = [:],
        sourceLocalIdentifiersByChecksum: [Checksum: String] = [:],
        quarantineDays: Int = 14,
        massOffloadCount: Int = 0,
        showsMassOffloadBanner: Bool = false,
        showsTokenExpiryBanner: Bool = false,
        recycledExclusionCount: Int = 0,
        onBack: @escaping () -> Void = {},
        onApprove: @escaping ([String]) -> Void = { _ in },
        onExclude: @escaping ([String]) -> Void = { _ in },
        onDismiss: @escaping ([String]) -> Void = { _ in },
        onBulkExcludeOffload: @escaping () -> Void = {}
    ) {
        self.heldGroups = PendingReviewGroup.grouped(
            heldAssets,
            firstObservedAnchors: firstObservedAnchors,
            confirmedDeletedAt: confirmedDeletedAt,
            sourceLocalIdentifiersByChecksum: sourceLocalIdentifiersByChecksum
        )
        self.unconfirmedGroups = PendingReviewGroup.grouped(
            unconfirmedAssets,
            firstObservedAnchors: firstObservedAnchors,
            confirmedDeletedAt: confirmedDeletedAt,
            sourceLocalIdentifiersByChecksum: sourceLocalIdentifiersByChecksum
        )
        self.confirmedDeletedAt = Dictionary(
            uniqueKeysWithValues: confirmedDeletedAt.map { ($0.key.base64, $0.value) }
        )
        self.quarantineDays = quarantineDays
        self.massOffloadCount = massOffloadCount
        self.showsMassOffloadBanner = showsMassOffloadBanner
        self.showsTokenExpiryBanner = showsTokenExpiryBanner
        self.recycledExclusionCount = recycledExclusionCount
        self.onBack = onBack
        self.onApprove = onApprove
        self.onExclude = onExclude
        self.onDismiss = onDismiss
        self.onBulkExcludeOffload = onBulkExcludeOffload
    }

    private var totalGroupCount: Int { heldGroups.count + unconfirmedGroups.count }
    private var totalVersionCount: Int {
        heldGroups.reduce(0) { $0 + $1.versions.count } +
        unconfirmedGroups.reduce(0) { $0 + $1.versions.count }
    }
    private var isEmpty: Bool { totalGroupCount == 0 }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if isEmpty {
                        emptyState
                    } else {
                        // Token-expiry takes precedence over mass-offload —
                        // it's the more specific cause for "this list is
                        // bigger than usual" and tells the user something
                        // the mass-offload banner doesn't.
                        if showsTokenExpiryBanner {
                            tokenExpiryCallout
                        } else if showsMassOffloadBanner {
                            massOffloadCallout
                        }
                        // Independent of the above two — recycled
                        // exclusions are an orthogonal signal and
                        // can co-occur with either banner.
                        if recycledExclusionCount > 0 {
                            recycledExclusionsCallout
                        }
                        if !selectionMode && totalVersionCount > 1 {
                            trashAllButton
                        }
                        if !heldGroups.isEmpty {
                            heldSection
                        }
                        if !unconfirmedGroups.isEmpty {
                            unconfirmedSection
                        }
                        // Trailing space so the last row clears the
                        // floating bulk-action bar in selection mode.
                        Spacer(minLength: selectionMode ? 120 : 40)
                    }
                }
                // Spring-driven entry/exit for the mass-offload
                // callout when burst detection toggles. Paired with
                // `.transition(.cairnBanner)` on the callout itself
                // so the motion matches Status-screen banners.
                .cairnBannerAnimation(value: showsMassOffloadBanner)
                .cairnBannerAnimation(value: showsTokenExpiryBanner)
            }
            .background(t.bg)

            if selectionMode {
                bulkActionBar
                    .transition(.cairnBannerBottom)
            }
        }
        .cairnBannerAnimation(value: selectionMode)
        .overlay {
            if let zoomed = zoomedAsset {
                ZStack {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                                zoomedAsset = nil
                            }
                        }
                        .accessibilityLabel("Close zoomed thumbnail")
                        .accessibilityAddTraits(.isButton)
                    VStack(spacing: 12) {
                        ImmichAssetThumb(
                            assetId: zoomed.id,
                            filename: zoomed.originalFileName ?? "asset-\(zoomed.id.prefix(8))",
                            size: 280,
                            isLivePair: zoomed.livePhotoVideoId != nil
                        )
                        if let name = zoomed.originalFileName {
                            Text(name)
                                .font(.cairnScaled(size: 14, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        if let createdAt = zoomed.fileCreatedAt {
                            Text(createdAt, format: .dateTime)
                                .font(.cairnScaled(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .transition(.opacity)
                // VoiceOver: trap focus inside the zoom overlay so the
                // user doesn't tab back to the row list while the
                // overlay is visible. .isModal does the trapping;
                // explicit dismiss button (background ZStack) carries
                // the off-screen exit action.
                .accessibilityAddTraits(.isModal)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            confirmationButtons
        } message: {
            confirmationMessage
        }
    }

    // MARK: - Header

    private var header: some View {
        AppHeader(
            title: selectionMode ? (selectedChecksums.isEmpty ? "Select items" : "\(selectedChecksums.count) selected") : "Pending review",
            subtitle: selectionMode ? nil : (isEmpty
                ? "Nothing waiting — every candidate has been handled"
                : subtitleCopy),
            leading: {
                if selectionMode {
                    Button(action: exitSelectionMode) {
                        Text("Cancel")
                            .font(.cairnScaled(size: 15))
                            .foregroundStyle(t.textBody)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                            Text("Status")
                                .font(.cairnScaled(size: 15))
                        }
                        .foregroundStyle(t.textBody)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            },
            trailing: {
                if !isEmpty {
                    if selectionMode {
                        Button(action: toggleSelectAll) {
                            Text(allSelected ? "None" : "All")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(t.textBody)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: enterSelectionMode) {
                            Text("Select")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(t.textBody)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        )
    }

    private var allChecksums: [String] {
        (heldGroups + unconfirmedGroups).flatMap { group in
            group.versions.map(\.checksum.base64)
        }
    }

    private var allSelected: Bool {
        !allChecksums.isEmpty && Set(allChecksums).isSubset(of: selectedChecksums)
    }

    private func enterSelectionMode() {
        selectionMode = true
        selectedChecksums = []
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedChecksums = []
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedChecksums = []
        } else {
            selectedChecksums = Set(allChecksums)
        }
    }

    private func toggleGroupSelection(_ group: PendingReviewGroup) {
        let groupChecksums = Set(group.versions.map(\.checksum.base64))
        if groupChecksums.isSubset(of: selectedChecksums) {
            selectedChecksums.subtract(groupChecksums)
        } else {
            selectedChecksums.formUnion(groupChecksums)
        }
    }

    private func toggleVersionSelection(_ checksum: String) {
        if selectedChecksums.contains(checksum) {
            selectedChecksums.remove(checksum)
        } else {
            selectedChecksums.insert(checksum)
        }
    }

    private func isGroupFullySelected(_ group: PendingReviewGroup) -> Bool {
        let groupChecksums = Set(group.versions.map(\.checksum.base64))
        return !groupChecksums.isEmpty && groupChecksums.isSubset(of: selectedChecksums)
    }

    /// Every checksum in `groups`, flattened. Used by per-section
    /// Select All to know what to add to / remove from
    /// `selectedChecksums` in one tap.
    private func sectionChecksums(_ groups: [PendingReviewGroup]) -> Set<String> {
        Set(groups.flatMap { $0.versions.map(\.checksum.base64) })
    }

    private func isSectionFullySelected(_ groups: [PendingReviewGroup]) -> Bool {
        let cks = sectionChecksums(groups)
        return !cks.isEmpty && cks.isSubset(of: selectedChecksums)
    }

    /// Toggle selection for a whole section. Enters selection mode on
    /// first tap if the user wasn't already in it. If every checksum
    /// in the section is selected, removes them; otherwise adds them.
    /// Doesn't touch checksums in other sections — distinct from
    /// `toggleSelectAll` which spans every group.
    private func toggleSectionSelection(_ groups: [PendingReviewGroup]) {
        let cks = sectionChecksums(groups)
        guard !cks.isEmpty else { return }
        if !selectionMode { selectionMode = true }
        if cks.isSubset(of: selectedChecksums) {
            selectedChecksums.subtract(cks)
        } else {
            selectedChecksums.formUnion(cks)
        }
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        VStack(spacing: 0) {
            Divider().background(t.divider)
            HStack(spacing: 10) {
                bulkChip(
                    label: "Move \(selectedChecksums.count) to Trash",
                    foreground: t.dangerInk,
                    disabled: selectedChecksums.isEmpty,
                    action: { pendingAction = .bulkApprove(count: selectedChecksums.count) }
                )
                bulkChip(
                    label: "Dismiss \(selectedChecksums.count)",
                    foreground: t.textBody,
                    disabled: selectedChecksums.isEmpty,
                    action: { pendingAction = .bulkDismiss(count: selectedChecksums.count) }
                )
                bulkChip(
                    label: "Exclude \(selectedChecksums.count)",
                    foreground: t.textBody,
                    disabled: selectedChecksums.isEmpty,
                    action: { pendingAction = .bulkExcludeSelected(count: selectedChecksums.count) }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(t.surface)
    }

    private func bulkChip(label: String, foreground: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.cairnScaled(size: 14, weight: .semibold))
                .foregroundStyle(disabled ? t.textHint : foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .disabled(disabled)
    }

    private var subtitleCopy: String {
        var parts: [String] = []
        if !heldGroups.isEmpty {
            parts.append("\(heldGroups.count) queued")
        }
        if !unconfirmedGroups.isEmpty {
            parts.append("\(unconfirmedGroups.count) unconfirmed")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Trash all

    private var trashAllButton: some View {
        Button(action: { pendingAction = .trashAll(count: totalVersionCount) }) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.cairnScaled(size: 14, weight: .semibold))
                Text("Trash all \(totalVersionCount) now")
                    .font(.cairnScaled(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(t.dangerInk)
            .background(t.dangerSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CairnPressStyle())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(t.verifiedSoft)
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.cairnScaled(size: 24, weight: .semibold))
                    .foregroundStyle(t.verifiedInk)
            }
            .padding(.bottom, 14)

            Text("Nothing to review")
                .font(.cairnScaled(size: 17, weight: .semibold))
                .foregroundStyle(t.text)
                .padding(.bottom, 6)

            Text("Recent deletions are either ready to move to Immich's Trash or still inside the quarantine window. Anything that needs your input will show up here.")
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    // MARK: - Token-expiry callout

    /// Shown when the last scan re-enumerated the library because the
    /// persistent-change token expired. The candidates that surfaced
    /// arrived without quarantine clocks — diff-only — so we hold them
    /// here regardless of strictness and tell the user why.
    private var tokenExpiryCallout: some View {
        Callout(.pending, icon: "clock.arrow.circlepath") {
            (.cairnWord + Text(" was dormant long enough that the system change log expired. We re-indexed your library, but the \(totalVersionCount) candidates below are based on diff-only detection — review them before trashing."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.cairnBanner)
    }

    // MARK: - Recycled-exclusions callout

    /// Surfaced when one or more items in this list are previously-
    /// excluded checksums that the user has now deleted on the phone
    /// again. Explains why they're showing up here instead of in
    /// quarantine — "you told cairn to preserve these last time, but
    /// you've now deleted them, so we want explicit confirmation
    /// before propagating." Tapping Approve on these items clears
    /// the exclusion and trashes them on Immich; tapping Exclude
    /// re-affirms the original preserve intent (and bumps the
    /// `addedAt` so they don't reappear here next sync).
    private var recycledExclusionsCallout: some View {
        let n = recycledExclusionCount
        let noun = n == 1 ? "item" : "items"
        return Callout(.info, icon: "arrow.uturn.backward.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(n) restored \(noun) deleted again").fontWeight(.semibold)
                (Text("You previously restored ") + (n == 1 ? Text("this") : Text("these"))
                    + Text(" via ") + .cairnWord
                    + Text(" — they were marked as preserved on Immich. ")
                    + (n == 1 ? Text("It's") : Text("They're"))
                    + Text(" now deleted on this iPhone again. Approving will clear the exclusion and trash on Immich; excluding re-affirms the original preserve."))
                    .opacity(0.88).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.cairnBanner)
    }

    // MARK: - Mass-offload callout

    private var massOffloadCallout: some View {
        Callout(.pending, icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 10) {
                (Text("Detected \(massOffloadCount) deletions in a recent scan — that's a lot at once. If you were intentionally offloading photos to free up space, exclude them now so ") + .cairnWord + Text(" stops flagging them."))
                    .fixedSize(horizontal: false, vertical: true)
                CairnChip("Bulk exclude \(massOffloadCount)") {
                    pendingAction = .bulkOffload(count: massOffloadCount)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.cairnBanner)
    }

    // MARK: - Sections

    /// Per-section "Select all" affordance rendered in the trailing
    /// slot of each `KeylineSection`. Toggles selection of every
    /// checksum in the supplied groups. Hidden when the section is
    /// empty (no rows to select). Enters selection mode on first tap
    /// if not already active — same affordance as the trailing
    /// "Select" button on the header, scoped to one section.
    @ViewBuilder
    private func sectionSelectAllButton(for groups: [PendingReviewGroup]) -> some View {
        if !groups.isEmpty {
            let isSelected = isSectionFullySelected(groups)
            Button(action: { toggleSectionSelection(groups) }) {
                Text(isSelected ? "Deselect all" : "Select all")
                    .font(.cairnScaled(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(t.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var heldSection: some View {
        Group {
            KeylineSection("Queued") {
                HStack(spacing: 12) {
                    sectionSelectAllButton(for: heldGroups)
                    Text("\(heldGroups.count)")
                        .font(.cairnScaled(size: 11, weight: .semibold))
                        .tracking(0.99)
                        .foregroundStyle(t.textMuted)
                        .monospacedDigit()
                }
            }
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(heldGroups.enumerated()), id: \.element.id) { idx, group in
                        groupCard(group, isUnconfirmed: false)
                        if idx < heldGroups.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var unconfirmedSection: some View {
        Group {
            KeylineSection("Unconfirmed") {
                HStack(spacing: 12) {
                    sectionSelectAllButton(for: unconfirmedGroups)
                    Text("\(unconfirmedGroups.count)")
                        .font(.cairnScaled(size: 11, weight: .semibold))
                        .tracking(0.99)
                        .foregroundStyle(t.textMuted)
                        .monospacedDigit()
                }
            }
            Callout(.info, icon: "questionmark.circle") {
                (Text("These weren't caught by the deletion log — they may have left your library before ") + .cairnWord + Text(" was watching. Review each one before trashing."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            CairnCard {
                VStack(spacing: 0) {
                    ForEach(Array(unconfirmedGroups.enumerated()), id: \.element.id) { idx, group in
                        groupCard(group, isUnconfirmed: true)
                        if idx < unconfirmedGroups.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Group card

    @ViewBuilder
    private func groupCard(_ group: PendingReviewGroup, isUnconfirmed: Bool) -> some View {
        let isMulti = group.versions.count > 1
        let isExpanded = expandedGroupKeys.contains(group.key)
        VStack(spacing: 0) {
            PendingReviewGroupRow(
                group: group,
                countdown: groupCountdown(group, isUnconfirmed: isUnconfirmed),
                selectionMode: selectionMode,
                isSelected: isGroupFullySelected(group),
                isExpanded: isExpanded,
                isMulti: isMulti,
                onToggleSelect: { toggleGroupSelection(group) },
                onToggleExpand: {
                    if isMulti {
                        if isExpanded {
                            expandedGroupKeys.remove(group.key)
                        } else {
                            expandedGroupKeys.insert(group.key)
                        }
                    }
                },
                onApprove: { pendingAction = .approveGroup(group: group) },
                onExclude: { pendingAction = .excludeGroup(group: group) },
                onDismiss: { pendingAction = .dismissGroup(group: group) },
                onTapThumb: { asset in
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                        zoomedAsset = asset
                    }
                }
            )
            if isMulti && isExpanded {
                ForEach(group.versions, id: \.id) { asset in
                    RowDivider()
                    PendingReviewVersionRow(
                        asset: asset,
                        label: versionLabel(for: asset, in: group),
                        countdown: versionCountdown(asset, isUnconfirmed: isUnconfirmed),
                        selectionMode: selectionMode,
                        isSelected: selectedChecksums.contains(asset.checksum.base64),
                        onToggleSelect: { toggleVersionSelection(asset.checksum.base64) },
                        onApprove: {
                            pendingAction = .approveVersion(
                                checksum: asset.checksum.base64,
                                label: asset.originalFileName ?? "version"
                            )
                        },
                        onExclude: {
                            pendingAction = .excludeVersion(
                                checksum: asset.checksum.base64,
                                label: asset.originalFileName ?? "version"
                            )
                        },
                        onDismiss: {
                            pendingAction = .dismissVersion(
                                checksum: asset.checksum.base64,
                                label: asset.originalFileName ?? "version"
                            )
                        },
                        onTapThumb: { tappedAsset in
                            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                                zoomedAsset = tappedAsset
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Countdown helpers

    private func groupCountdown(_ group: PendingReviewGroup, isUnconfirmed: Bool) -> String? {
        guard !isUnconfirmed else { return nil }
        // Surface the soonest-eligible version's countdown — that's the
        // one the user would most want to see at a glance.
        let stamps = group.versions.compactMap { confirmedDeletedAt[$0.checksum.base64] }
        guard let earliest = stamps.min() else { return nil }
        return formatCountdown(earliest)
    }

    private func versionCountdown(_ asset: ServerAsset, isUnconfirmed: Bool) -> String? {
        guard !isUnconfirmed else { return nil }
        guard let stamp = confirmedDeletedAt[asset.checksum.base64] else { return nil }
        return formatCountdown(stamp)
    }

    private func formatCountdown(_ confirmedAt: Date) -> String {
        let eligibleAt = confirmedAt.addingTimeInterval(TimeInterval(quarantineDays) * 86_400)
        let remaining = eligibleAt.timeIntervalSinceNow
        if remaining <= 0 { return "Ready to trash" }
        let days = Int((remaining / 86_400).rounded(.up))
        return days == 1 ? "Trashes in 1 day" : "Trashes in \(days) days"
    }

    // MARK: - Version labels

    private func versionLabel(for asset: ServerAsset, in group: PendingReviewGroup) -> VersionLabel? {
        // Use the precomputed `firstObserved` membership stamped into the
        // group at construction time so labels are stable across re-renders.
        if group.firstObservedChecksums.contains(asset.checksum) {
            return .original
        }
        if let stamp = confirmedDeletedAt[asset.checksum.base64] {
            return .retired(formatRelative(stamp))
        }
        return nil
    }

    /// `Nd ago` / `Nh ago` / `just now` — same shape as
    /// `CairnTimeHelpers.relativeTime` but prefixed-friendly for the
    /// "Retired …" label so we don't double-render "Retired Apr 21".
    private func formatRelative(_ d: Date) -> String {
        let diff = Int(Date().timeIntervalSince(d))
        if diff < 60 { return "just now" }
        let m = diff / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let days = h / 24
        if days < 30 { return "\(days)d ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }

    // MARK: - Confirmation dialog

    private var confirmationTitle: String {
        switch pendingAction {
        case .approveGroup(let g): return "Move \(groupNoun(g)) to Trash now?"
        case .excludeGroup(let g): return "Exclude \(groupNoun(g)) from future runs?"
        case .dismissGroup(let g): return "Dismiss \(groupNoun(g))?"
        case .approveVersion(_, let l): return "Move \(l) version to Trash now?"
        case .excludeVersion(_, let l): return "Exclude \(l) version from future runs?"
        case .dismissVersion(_, let l): return "Dismiss \(l) version?"
        case .bulkOffload(let n): return "Exclude all \(n) recent deletions?"
        case .bulkApprove(let n): return "Move \(n) selected item\(n == 1 ? "" : "s") to Trash now?"
        case .bulkExcludeSelected(let n): return "Exclude \(n) selected item\(n == 1 ? "" : "s")?"
        case .bulkDismiss(let n): return "Dismiss \(n) selected item\(n == 1 ? "" : "s")?"
        case .trashAll(let n): return "Move all \(n) item\(n == 1 ? "" : "s") to Trash now?"
        case .none:              return ""
        }
    }

    private func groupNoun(_ group: PendingReviewGroup) -> String {
        // Source-id-keyed groups don't carry a filename in the key; fall
        // back to the representative version's filename so the
        // confirmation noun stays human-readable. Filename-keyed groups
        // already encode the name in the key.
        let name = group.versions.first?.originalFileName
            ?? group.key.fallbackFilename
            ?? "this photo"
        if group.versions.count > 1 {
            return "\(name) (\(group.versions.count) versions)"
        }
        return name
    }

    private var confirmationMessage: Text {
        switch pendingAction {
        case .approveGroup(let g):
            if g.versions.count > 1 {
                return Text("Skips the quarantine wait for every version. Immich keeps them in Trash for 30 days.")
            }
            return Text("Skips the quarantine wait. Immich keeps it in Trash for 30 days.")
        case .excludeGroup(let g):
            if g.versions.count > 1 {
                return Text("Future runs will skip every version. You can unexclude later from Settings.")
            }
            return Text("Future runs will skip this one. You can unexclude later from Settings.")
        case .dismissGroup(let g):
            if g.versions.count > 1 {
                return Text("Removes every version from the pending list. If you delete the same photo again, they will reappear.")
            }
            return Text("Removes it from the pending list. If you delete the same photo again, it will reappear.")
        case .approveVersion:
            return Text("Skips the quarantine wait for this version only. Immich keeps it in Trash for 30 days.")
        case .excludeVersion:
            return Text("Future runs will skip this version. The other versions in this group are unaffected.")
        case .dismissVersion:
            return Text("Removes this version from the pending list. Other versions in the group remain.")
        case .bulkOffload:
            return Text("All \(massOffloadCount) recent deletions will move to the excluded list. ") + .cairnWord + Text(" will stop considering them.")
        case .bulkApprove:
            return Text("Skips the quarantine wait for every selected item. Immich keeps them in Trash for 30 days.")
        case .bulkExcludeSelected:
            return Text("Future runs will skip every selected item. You can unexclude later from Settings.")
        case .bulkDismiss:
            return Text("Removes selected items from the pending list. If you delete them again, they will reappear.")
        case .trashAll:
            return Text("Skips the quarantine wait for every item. Immich keeps them in Trash for 30 days.")
        case .none:
            return Text("")
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch pendingAction {
        case .approveGroup(let g):
            Button("Move to Trash", role: .destructive) {
                onApprove(g.versions.map(\.checksum.base64))
            }
            Button("Cancel", role: .cancel) {}
        case .excludeGroup(let g):
            Button("Exclude", role: .destructive) {
                onExclude(g.versions.map(\.checksum.base64))
            }
            Button("Cancel", role: .cancel) {}
        case .dismissGroup(let g):
            Button("Dismiss") {
                onDismiss(g.versions.map(\.checksum.base64))
            }
            Button("Cancel", role: .cancel) {}
        case .approveVersion(let c, _):
            Button("Move to Trash", role: .destructive) { onApprove([c]) }
            Button("Cancel", role: .cancel) {}
        case .excludeVersion(let c, _):
            Button("Exclude", role: .destructive) { onExclude([c]) }
            Button("Cancel", role: .cancel) {}
        case .dismissVersion(let c, _):
            Button("Dismiss") { onDismiss([c]) }
            Button("Cancel", role: .cancel) {}
        case .bulkOffload:
            Button("Exclude all", role: .destructive) { onBulkExcludeOffload() }
            Button("Cancel", role: .cancel) {}
        case .bulkApprove:
            Button("Move selected to Trash", role: .destructive) {
                onApprove(Array(selectedChecksums))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .bulkExcludeSelected:
            Button("Exclude selected", role: .destructive) {
                onExclude(Array(selectedChecksums))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .bulkDismiss:
            Button("Dismiss selected") {
                onDismiss(Array(selectedChecksums))
                exitSelectionMode()
            }
            Button("Cancel", role: .cancel) {}
        case .trashAll:
            Button("Move all to Trash", role: .destructive) {
                onApprove(allChecksums)
            }
            Button("Cancel", role: .cancel) {}
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Group model

extension PendingReviewScreen {

    /// A logical photo cluster — every server asset whose checksums
    /// resolve to the same source. The primary key is the source
    /// PhotoKit `localIdentifier`, captured by the reconciler at
    /// delete time and by `OrphanReconciler` at metadata-match time;
    /// when no source-id is available we fall back to
    /// `(originalFileName, fileCreatedAt)`. The fallback exists because
    /// Immich sometimes stores microsecond-mismatched creation dates
    /// across edited/original uploads of the same logical photo, so
    /// pure metadata grouping fails to collapse them. Singleton groups
    /// are still groups so the rendering path is uniform; the "N
    /// versions" pill only appears when `versions.count > 1`.
    public struct PendingReviewGroup: Identifiable, Equatable, Sendable {
        public enum GroupKey: Hashable, Equatable, Sendable {
            /// Two assets share a source PhotoKit identifier — the most
            /// reliable signal that they're versions of the same
            /// logical photo. Wins over filename grouping whenever
            /// available.
            case bySourceId(String)
            /// Fallback when source-id isn't tracked for this asset.
            /// Both fields can be nil; nil/nil collapses together but
            /// stays distinct from any named group.
            case byFilenameAndDate(filename: String?, date: Date?)

            /// Stable, human-debuggable string for diagnostic IDs
            /// (used in `PendingAction.id`). Hashing handles dedup;
            /// this is only for SwiftUI identity stability.
            fileprivate var stableID: String {
                switch self {
                case .bySourceId(let id):
                    return "src|\(id)"
                case .byFilenameAndDate(let filename, let date):
                    let nameSlug = filename ?? "<no-name>"
                    let dateSlug = date.map { String($0.timeIntervalSince1970) } ?? "<no-date>"
                    return "fn|\(nameSlug)|\(dateSlug)"
                }
            }

            /// Filename embedded in the key, when available. Source-id-
            /// keyed groups don't carry a filename — callers fall back
            /// to the representative version's `originalFileName` for
            /// display. `nil` for `.bySourceId` and for filename-keyed
            /// groups whose filename was itself nil.
            fileprivate var fallbackFilename: String? {
                switch self {
                case .bySourceId: return nil
                case .byFilenameAndDate(let filename, _): return filename
                }
            }
        }

        public let key: GroupKey
        public let versions: [ServerAsset]
        /// Subset of `versions` whose checksums are in
        /// `firstObservedAnchors`. Stamped at construction time so the
        /// view's label resolution stays in sync with the ordering decision.
        public let firstObservedChecksums: Set<Checksum>

        public var id: GroupKey { key }

        public init(key: GroupKey, versions: [ServerAsset], firstObservedChecksums: Set<Checksum> = []) {
            self.key = key
            self.versions = versions
            self.firstObservedChecksums = firstObservedChecksums
        }

        /// Build a list of groups from a flat asset list. Group-level
        /// ordering preserves the order each key first appears. Per
        /// asset, the key is resolved in this priority:
        ///   1. `sourceLocalIdentifiersByChecksum[asset.checksum]` if
        ///      present → `.bySourceId(localId)`. Most reliable signal.
        ///   2. `.byFilenameAndDate(originalFileName, fileCreatedAt)`.
        ///      Both fields may be nil; the (nil, nil) bucket still
        ///      collapses together but stays distinct from any named
        ///      group.
        /// Within a group:
        ///   1. Anchored ("Original") versions first.
        ///   2. Then by `confirmedDeletedAt` ascending — oldest retired
        ///      first.
        ///   3. Then by `id` for stability when the prior keys tie.
        public static func grouped(
            _ assets: [ServerAsset],
            firstObservedAnchors: Set<Checksum> = [],
            confirmedDeletedAt: [Checksum: Date] = [:],
            sourceLocalIdentifiersByChecksum: [Checksum: String] = [:]
        ) -> [PendingReviewGroup] {
            var orderedKeys: [GroupKey] = []
            var buckets: [GroupKey: [ServerAsset]] = [:]
            for asset in assets {
                let key: GroupKey
                if let localId = sourceLocalIdentifiersByChecksum[asset.checksum] {
                    key = .bySourceId(localId)
                } else {
                    key = .byFilenameAndDate(
                        filename: asset.originalFileName,
                        date: asset.fileCreatedAt
                    )
                }
                if buckets[key] == nil {
                    orderedKeys.append(key)
                    buckets[key] = [asset]
                } else {
                    buckets[key]?.append(asset)
                }
            }
            let groups = orderedKeys.map { key -> PendingReviewGroup in
                let versions = buckets[key, default: []]
                let sorted = versions.sorted { lhs, rhs in
                    let lAnchored = firstObservedAnchors.contains(lhs.checksum)
                    let rAnchored = firstObservedAnchors.contains(rhs.checksum)
                    if lAnchored != rAnchored { return lAnchored }
                    let lStamp = confirmedDeletedAt[lhs.checksum]
                    let rStamp = confirmedDeletedAt[rhs.checksum]
                    switch (lStamp, rStamp) {
                    case let (l?, r?) where l != r: return l < r
                    case (.some, .none): return true
                    case (.none, .some): return false
                    default: return lhs.id < rhs.id
                    }
                }
                let anchored = Set(sorted.map(\.checksum)).intersection(firstObservedAnchors)
                return PendingReviewGroup(
                    key: key,
                    versions: sorted,
                    firstObservedChecksums: anchored
                )
            }
            // Deterministic display order: soonest-to-trash first (the
            // earliest confirmed-deleted stamp among a group's versions),
            // then the representative asset id as a stable tiebreak.
            // Without this the order followed the input array, which is
            // assembled from unordered sources (Dictionary/Set iteration in
            // the reconciliation rebuild), so the list reshuffled on every
            // reload. Sorting soonest-first also puts the item the Status
            // "next in N days" banner counts down to at the top.
            return groups.sorted { lhs, rhs in
                let lStamp = lhs.versions.compactMap { confirmedDeletedAt[$0.checksum] }.min()
                let rStamp = rhs.versions.compactMap { confirmedDeletedAt[$0.checksum] }.min()
                switch (lStamp, rStamp) {
                case let (l?, r?) where l != r: return l < r
                case (.some, .none): return true
                case (.none, .some): return false
                default: return (lhs.versions.first?.id ?? "") < (rhs.versions.first?.id ?? "")
                }
            }
        }
    }
}

// MARK: - Version label

private enum VersionLabel: Equatable {
    case original
    /// Already retired; payload is the rendered relative-time string
    /// ("3d ago", "just now", "Apr 21").
    case retired(String)

    var text: String {
        switch self {
        case .original: return "Original"
        case .retired(let when): return "Retired \(when)"
        }
    }
}

// MARK: - Group row (collapsed card)

private struct PendingReviewGroupRow: View {
    let group: PendingReviewScreen.PendingReviewGroup
    let countdown: String?
    let selectionMode: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isMulti: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onApprove: () -> Void
    let onExclude: () -> Void
    let onDismiss: () -> Void
    /// Called with the row's representative asset when the thumbnail
    /// itself is tapped. Routes to the screen-level zoom overlay so a
    /// tap on the thumb enlarges it without triggering selection or
    /// expansion (handled by the row body's tap gesture).
    let onTapThumb: (ServerAsset) -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        // Pick the first version (post-sort: anchored or oldest-retired)
        // as the "face" of the group — its assetId drives the thumbnail.
        let representative = group.versions.first
        let displayName = representative?.originalFileName
            ?? group.key.fallbackFilename
            ?? "asset-\(representative?.id.prefix(8) ?? "")"
        HStack(alignment: .center, spacing: 12) {
            if selectionMode {
                selectionIndicator
            }
            Button {
                guard let asset = representative else { return }
                onTapThumb(asset)
            } label: {
                ImmichAssetThumb(
                    assetId: representative?.id,
                    filename: displayName,
                    size: 44,
                    isLivePair: representative?.livePhotoVideoId != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View larger thumbnail of \(displayName)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.cairnScaled(size: 13, design: .monospaced))
                        .tracking(-0.065)
                        .foregroundStyle(t.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isMulti {
                        versionsPill
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(kindLabel(for: representative))
                        .font(.cairnScaled(size: 11.5))
                        .foregroundStyle(t.textMuted)
                        .lineLimit(1)
                    if let countdown {
                        Text(countdown)
                            .font(.cairnScaled(size: 11.5))
                            .foregroundStyle(t.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !selectionMode {
                if isMulti {
                    HStack(spacing: 8) {
                        RowIconButton(
                            systemName: "trash",
                            tone: .danger,
                            accessibilityLabel: "Move all \(group.versions.count) versions of \(displayName) to Trash",
                            action: onApprove
                        )
                        RowIconButton(
                            systemName: "xmark.circle",
                            tone: .neutral,
                            accessibilityLabel: "Dismiss all \(group.versions.count) versions of \(displayName)",
                            action: onDismiss
                        )
                        RowIconButton(
                            systemName: "shield",
                            tone: .neutral,
                            accessibilityLabel: "Exclude all \(group.versions.count) versions of \(displayName)",
                            action: onExclude
                        )
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.cairnScaled(size: 12, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                            .frame(width: 32, height: 28)
                    }
                } else {
                    HStack(spacing: 8) {
                        RowIconButton(
                            systemName: "trash",
                            tone: .danger,
                            accessibilityLabel: "Move \(displayName) to Trash",
                            action: onApprove
                        )
                        RowIconButton(
                            systemName: "xmark.circle",
                            tone: .neutral,
                            accessibilityLabel: "Dismiss \(displayName)",
                            action: onDismiss
                        )
                        RowIconButton(
                            systemName: "shield",
                            tone: .neutral,
                            accessibilityLabel: "Exclude \(displayName)",
                            action: onExclude
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            // In selection mode: toggle the whole group. Otherwise: a
            // multi-version tap expands; a singleton tap is a no-op
            // (the icon chips on the right remain the action surface,
            // matching the existing single-row interaction model).
            if selectionMode {
                onToggleSelect()
            } else if isMulti {
                onToggleExpand()
            }
        }
    }

    private var versionsPill: some View {
        Text("\(group.versions.count) versions")
            .font(.cairnScaled(size: 10, weight: .semibold))
            .tracking(0.55)
            .foregroundStyle(t.textBody)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(t.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? t.primary : t.divider, lineWidth: isSelected ? 0 : 1)
                .background(Circle().fill(isSelected ? t.primary : .clear))
                .frame(width: 22, height: 22)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.cairnScaled(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    private func kindLabel(for asset: ServerAsset?) -> String {
        guard let asset else { return "asset" }
        let name = asset.originalFileName ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "m4v", "avi", "3gp"].contains(ext)
        if asset.livePhotoVideoId != nil { return "live-pair" }
        return isVideo ? "video" : "photo"
    }
}

// MARK: - Version row (expanded leaf)

private struct PendingReviewVersionRow: View {
    let asset: ServerAsset
    let label: VersionLabel?
    let countdown: String?
    let selectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onApprove: () -> Void
    let onExclude: () -> Void
    let onDismiss: () -> Void
    let onTapThumb: (ServerAsset) -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        let displayName = asset.originalFileName ?? "asset-\(asset.id.prefix(8))"
        HStack(alignment: .center, spacing: 12) {
            // Inset to visually nest under the group row.
            Spacer().frame(width: 8)
            if selectionMode {
                selectionIndicator
            }
            Button {
                onTapThumb(asset)
            } label: {
                ImmichAssetThumb(
                    assetId: asset.id,
                    filename: displayName,
                    size: 32,
                    isLivePair: asset.livePhotoVideoId != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View larger thumbnail of \(displayName)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(checksumPrefix)
                        .font(.cairnScaled(size: 11, design: .monospaced))
                        .foregroundStyle(t.textMuted)
                    if let label {
                        labelPill(label)
                    }
                }
                if let countdown {
                    Text(countdown)
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !selectionMode {
                HStack(spacing: 8) {
                    RowIconButton(
                        systemName: "trash",
                        tone: .danger,
                        accessibilityLabel: "Move this version to Trash",
                        action: onApprove
                    )
                    RowIconButton(
                        systemName: "xmark.circle",
                        tone: .neutral,
                        accessibilityLabel: "Dismiss this version",
                        action: onDismiss
                    )
                    RowIconButton(
                        systemName: "shield",
                        tone: .neutral,
                        accessibilityLabel: "Exclude this version",
                        action: onExclude
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(t.bg.opacity(0.4))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectionMode { onToggleSelect() }
        }
    }

    /// First 8 chars of the base64 SHA1 — enough to disambiguate
    /// versions visually without printing the whole 28-char string.
    private var checksumPrefix: String {
        let s = asset.checksum.base64
        return s.count > 8 ? String(s.prefix(8)) + "…" : s
    }

    @ViewBuilder
    private func labelPill(_ label: VersionLabel) -> some View {
        let tone: Color = {
            switch label {
            case .original: return t.verifiedInk
            case .retired:  return t.textMuted
            }
        }()
        let bg: Color = {
            switch label {
            case .original: return t.verifiedSoft
            case .retired:  return t.bg
            }
        }()
        Text(label.text)
            .font(.cairnScaled(size: 10, weight: .semibold))
            .tracking(0.55)
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(t.divider, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? t.primary : t.divider, lineWidth: isSelected ? 0 : 1)
                .background(Circle().fill(isSelected ? t.primary : .clear))
                .frame(width: 18, height: 18)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.cairnScaled(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }
}

// MARK: - Row action button

/// Icon-only action button used on Pending Review rows, where two
/// labeled chips wouldn't fit alongside the filename + metadata.
/// The trash icon reads as "Move to Trash" (danger-tone), the shield
/// icon as "Exclude" (neutral). Full action phrasing lives in the
/// `accessibilityLabel` so VoiceOver users get the same context
/// sighted users recognize from the icon + color.
private struct RowIconButton: View {
    enum Tone { case danger, neutral }

    let systemName: String
    let tone: Tone
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.cairnScaled(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 32, height: 28)
                .background(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                // Expand hit region to Apple HIG's 44pt minimum without
                // growing the visual chrome — the badge looks unchanged
                // but the user (especially with motor impairments or
                // large fingers) can tap anywhere in the 44pt slot.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(CairnPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        switch tone {
        case .danger:  return t.dangerInk
        case .neutral: return t.textBody
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Pending review — populated") {
    let held = Array(CairnFixtures.pendingHeldAssets.prefix(5))
    let unconfirmed = Array(CairnFixtures.pendingUnconfirmedAssets.prefix(3))
    let confirmedAt: [Checksum: Date] = Dictionary(
        uniqueKeysWithValues: held.enumerated().map { i, a in
            (a.checksum, Date(timeIntervalSinceNow: -TimeInterval(i) * 86_400))
        }
    )
    return PendingReviewScreen(
        heldAssets: held,
        unconfirmedAssets: unconfirmed,
        firstObservedAnchors: CairnFixtures.pendingFirstObservedAnchors,
        confirmedDeletedAt: confirmedAt,
        quarantineDays: 14,
        massOffloadCount: 0,
        showsMassOffloadBanner: false
    )
    .cairnTheme()
}

#Preview("Pending review — multi-version groups") {
    return PendingReviewScreen(
        heldAssets: CairnFixtures.pendingHeldAssets,
        unconfirmedAssets: [],
        firstObservedAnchors: CairnFixtures.pendingFirstObservedAnchors,
        confirmedDeletedAt: Dictionary(uniqueKeysWithValues:
            CairnFixtures.pendingHeldAssets.map { ($0.checksum, Date(timeIntervalSinceNow: -86_400 * 2)) }
        ),
        quarantineDays: 14
    )
    .cairnTheme()
}

#Preview("Pending review — mass offload") {
    let held = Array(CairnFixtures.pendingHeldAssets.prefix(8))
    let confirmedAt: [Checksum: Date] = Dictionary(
        uniqueKeysWithValues: held.map { ($0.checksum, Date(timeIntervalSinceNow: -3_600)) }
    )
    return PendingReviewScreen(
        heldAssets: held,
        unconfirmedAssets: [],
        confirmedDeletedAt: confirmedAt,
        quarantineDays: 14,
        massOffloadCount: 312,
        showsMassOffloadBanner: true
    )
    .cairnTheme()
}

#Preview("Pending review — empty") {
    PendingReviewScreen()
        .cairnTheme()
}

#Preview("Pending review — dark") {
    let held = Array(CairnFixtures.pendingHeldAssets.prefix(4))
    return PendingReviewScreen(
        heldAssets: held,
        unconfirmedAssets: [],
        confirmedDeletedAt: Dictionary(uniqueKeysWithValues: held.map { ($0.checksum, Date()) }),
        quarantineDays: 14
    )
    .cairnTheme()
    .preferredColorScheme(.dark)
}
#endif
