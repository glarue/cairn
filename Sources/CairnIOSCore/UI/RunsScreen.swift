import SwiftUI
import CairnCore

/// The full history list. Mirrors the prototype's `screens/runs.jsx`.
///
/// Surfaces (top-to-bottom):
///   1. AppHeader — "Runs" with subtitle showing total count + last-run age
///   2. Day-grouped list of runs in reverse chronological order
///        - Each day section is wrapped in a `KeylineSection`
///        - Inside each day: a `CairnCard` containing one `RunListRow` per run
///   3. Empty state (when `runs.isEmpty`):
///        - Dashed-bordered icon tile
///        - Headline + explainer paragraph
///        - "A run includes" detail card with four bulleted lines
///        - Primary CTA: "Start a sync from Status"
///
/// Tapping a row calls `onOpenRun(run)`. The detail sheet itself is owned
/// by the parent (this screen never presents it directly), which keeps
/// navigation policy out of the leaf view.
///
/// The `now` parameter is injected so that #Preview blocks render a stable
/// "today/yesterday/Apr 15" grouping. Reading `Date()` from inside the body
/// would make previews jitter every time Xcode rebuilt them, and would
/// also break snapshot tests.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md "Keep these
/// copies verbatim" — the empty-state explainer in particular is
/// load-bearing (it teaches the user what a "run" is before they have one
/// to inspect).
public struct RunsScreen: View {

    public let runs: [CairnFixtures.RunFixture]
    public let now: Date
    public let onOpenRun: (CairnFixtures.RunFixture) -> Void
    public let onStartSync: () -> Void
    /// Token incremented by the host when the user re-taps the active
    /// tab — see `CairnTabBar.onReselect`. Each increment scrolls the
    /// screen back to the top.
    public let scrollResetToken: Int

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Default `now` matches the prototype's pinned clock in
    /// `parts.jsx::relTime` so the hand-off design and ported screen show
    /// the same relative timestamps when reviewed side-by-side.
    public static let previewNow: Date = {
        ISO8601DateFormatter().date(from: "2026-04-21T18:30:00Z") ?? Date()
    }()

    public init(
        runs: [CairnFixtures.RunFixture] = CairnFixtures.runs,
        now: Date = RunsScreen.previewNow,
        onOpenRun: @escaping (CairnFixtures.RunFixture) -> Void = { _ in },
        onStartSync: @escaping () -> Void = {},
        scrollResetToken: Int = 0
    ) {
        self.runs = runs
        self.now = now
        self.onOpenRun = onOpenRun
        self.onStartSync = onStartSync
        self.scrollResetToken = scrollResetToken
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.scrollTopAnchor)
                    if runs.isEmpty {
                        emptyState
                    } else {
                        populated
                    }
                    Spacer(minLength: 24)
                }
            }
            .background(t.bg)
            .onChange(of: scrollResetToken) { _, _ in
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                }
            }
        }
    }

    private static let scrollTopAnchor = "cairn.scroll.top"

    // MARK: - Populated

    private var populated: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Subtitle copy from screens/runs.jsx:83 — "<n> total · last <relTime>".
            AppHeader(
                title: "Runs".loc,
                subtitle: "\(runs.count) \("total".loc) · \("last".loc) \(CairnTimeHelpers.relativeTime(sortedRuns.first?.startedAt ?? now, now: now))"
            )

            ForEach(dayGroups, id: \.dayKey) { group in
                KeylineSection(group.label)
                CairnCard {
                    VStack(spacing: 0) {
                        ForEach(Array(group.runs.enumerated()), id: \.element.id) { idx, run in
                            RunListRow(run: run, now: now, onOpen: { onOpenRun(run) })
                            if idx < group.runs.count - 1 {
                                RowDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reverse-chronological so the most-recent run is first; matches the
    /// prototype's implicit ordering (`RUNS` is already sorted that way).
    private var sortedRuns: [CairnFixtures.RunFixture] {
        runs.sorted { $0.startedAt > $1.startedAt }
    }

    private struct DayGroup {
        let dayKey: Date     // start-of-day for stable identity
        let label: String    // "Today" / "Yesterday" / "Mon, April 15"
        let runs: [CairnFixtures.RunFixture]
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        var bucketed: [Date: [CairnFixtures.RunFixture]] = [:]
        for run in sortedRuns {
            let day = cal.startOfDay(for: run.startedAt)
            bucketed[day, default: []].append(run)
        }
        return bucketed.keys
            .sorted(by: >)
            .map { day in
                DayGroup(
                    dayKey: day,
                    label: Self.dayLabel(day, now: now, calendar: cal),
                    runs: bucketed[day] ?? []
                )
            }
    }

    /// "Today" / "Yesterday" / "Mon, April 15" — mirrors prototype
    /// `screens/runs.jsx:86` (`fmtDate({ weekday: 'short', month: 'long',
    /// day: 'numeric' })`) but adds Today/Yesterday affordances since the
    /// prototype's date string is already implicitly "today" or
    /// "yesterday" most of the time.
    private static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today".loc }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday".loc }
        let f = DateFormatter()
        f.locale = CairnL10n.currentLocale
        if CairnL10n.isChinese {
            f.dateFormat = "M月d日 EEE"
        } else {
            f.dateFormat = "EEE, MMMM d"
        }
        return f.string(from: day)
    }

    // MARK: - Empty state

    /// Verbatim copy from screens/runs.jsx:13–69. The four detail bullets
    /// and the primary CTA label are load-bearing — they teach the user
    /// what a "run" actually contains before they have one to look at.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppHeader(title: "Runs".loc, subtitle: "No runs yet".loc)

            VStack(spacing: 0) {
                // Dashed icon tile.
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(t.divider, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(t.surfaceAlt)
                        )
                        .frame(width: 64, height: 64)
                    Image(systemName: "list.bullet")
                        .font(.cairnScaled(size: 22, weight: .regular))
                        .foregroundStyle(t.textMuted)
                }
                .padding(.bottom, 18)

                Text("No runs yet.".loc)
                    .font(.cairnScaled(size: 18, weight: .semibold))
                    .tracking(-0.27)
                    .foregroundStyle(t.text)
                    .padding(.bottom, 6)

                Text("Every sync lands here — completed, aborted, or restored — with the candidate list and the journal of API calls. You can restore any trashed batch while Immich still has it.".loc)
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 300)
                    .padding(.bottom, 20)

                // "A run includes" detail card.
                runIncludesCard
                    .padding(.bottom, 16)

                // CTA (verbatim, screens/runs.jsx:67).
                Button(action: onStartSync) {
                    Text("Start a sync from Status".loc)
                        .font(.cairnScaled(size: 16, weight: .semibold))
                        .frame(minWidth: 200)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .foregroundStyle(t.primaryInk)
                        .background(t.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 30)
        }
    }

    private var runIncludesCard: some View {
        // Lines copied verbatim from screens/runs.jsx:38–43.
        let lines = [
            "Thumbnails + filenames of every candidate".loc,
            "Safety-rail outcome (pass or tripped)".loc,
            "Raw journal of every Immich API call".loc,
            "One-tap restore for trashed assets".loc,
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text(CairnL10n.isChinese ? "A run includes".loc : "A run includes".loc.uppercased())
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.88)
                .foregroundStyle(t.textHint)
                .padding(.bottom, 10)

            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(t.surfaceAlt)
                            .frame(width: 14, height: 14)
                        Image(systemName: "checkmark")
                            .font(.cairnScaled(size: 8, weight: .bold))
                            .foregroundStyle(t.textMuted)
                    }
                    .padding(.top, 2)

                    Text(line.loc)
                        .font(.cairnScaled(size: 12.5))
                        .foregroundStyle(t.textBody)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .overlay(
                    Rectangle()
                        .fill(idx == 0 ? Color.clear : t.divider)
                        .frame(height: 0.5),
                    alignment: .top
                )
            }
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(t.divider, lineWidth: 0.5)
        )
    }
}

// MARK: - Row

/// One run line inside the day-grouped list.
///
/// Modeled on `StatusScreen.RunRow` but lives here because that one is
/// `private` to its file. Visually richer than the Status variant: the
/// Runs list is the user's reference for *what a run did*, so we surface
/// the breadcrumb tag value as a muted secondary line and (when present)
/// a "N restored" pill.
private struct RunListRow: View {
    let run: CairnFixtures.RunFixture
    let now: Date
    let onOpen: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconBg)
                        .frame(width: 30, height: 30)
                    Image(systemName: iconName)
                        .font(.cairnScaled(size: 13, weight: .semibold))
                        .foregroundStyle(iconInk)
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusPill(label: pillLabel.loc, tone: pillTone)
                        Text(countLabel)
                            .font(.cairnScaled(size: 13, weight: .medium))
                            .foregroundStyle(t.textBody)
                        if run.restored > 0 {
                            StatusPill(label: CairnL10n.isChinese ? "\(run.restored) 已恢复" : "\(run.restored) restored", tone: .neutral)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(CairnTimeHelpers.relativeTime(run.startedAt, now: now))
                            .font(.cairnScaled(size: 11.5))
                            .foregroundStyle(t.textHint)
                        Text("·")
                            .font(.cairnScaled(size: 11.5))
                            .foregroundStyle(t.textHint)
                        Text(timeOfDay)
                            .font(.cairnScaled(size: 11.5))
                            .foregroundStyle(t.textHint)
                    }
                    if let tag = run.tag {
                        Text(tag)
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textHint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.cairnScaled(size: 12, weight: .semibold))
                    .foregroundStyle(t.textHint)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pillLabel: String {
        if run.status == .aborted { return "aborted" }
        if run.dryRun { return "dry-run" }
        if run.restored > 0 && run.trashed == 0 { return "restored" }
        return "trashed"
    }

    private var pillTone: PillTone {
        if run.status == .aborted { return .danger }
        if run.dryRun { return .info }
        return .verified
    }

    private var countLabel: String {
        if run.status == .aborted { return "0 trashed".loc }
        if run.dryRun { return "0 trashed".loc }
        if run.trashed == 0 { return "no changes".loc }
        if CairnL10n.isChinese { return "\(run.trashed) 项已移入废纸篓" }
        return "\(run.trashed) trashed"
    }

    private var iconName: String {
        if run.status == .aborted { return "exclamationmark.triangle.fill" }
        if run.dryRun { return "eye" }
        return "trash"
    }

    private var iconBg: Color {
        if run.status == .aborted { return t.dangerSoft }
        if run.dryRun { return t.infoSoft }
        return t.verifiedSoft
    }

    private var iconInk: Color {
        if run.status == .aborted { return t.dangerInk }
        if run.dryRun { return t.infoInk }
        return t.verifiedInk
    }

    @Environment(\.cairnTimeFormat) private var timeFormat
    @Environment(\.locale) private var locale

    private var timeOfDay: String {
        // Was a hardcoded `h:mm a`. Now honors the user's
        // Settings → Appearance → Time format pick (or the device's
        // 12/24-hour preference when `.system`). Same rendering path
        // the journal tail goes through, so the two surfaces stay
        // visually in sync.
        //
        // The `\.locale` environment read above is load-bearing for
        // *reactivity*: SwiftUI auto-updates `\.locale` whenever the
        // system locale changes (including the iOS 24-Hour Time
        // toggle), and reading it here makes this view's body
        // dependent on it — so a user flipping the toggle in iOS
        // Settings triggers a re-render of every row's `timeOfDay`
        // immediately, without us having to listen to
        // `NSLocale.currentLocaleDidChangeNotification` ourselves.
        // Passing the same locale into the formatter doubles as
        // belt-and-suspenders: any `Locale.autoupdatingCurrent`
        // cache that hasn't refreshed yet gets overridden by what
        // SwiftUI considers current.
        timeFormat.formatClockTime(run.startedAt, locale: locale)
    }
}

// MARK: - Pill

private enum PillTone {
    case verified, danger, pending, info, neutral
}

private struct StatusPill: View {
    let label: String
    let tone: PillTone

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(inkColor.opacity(0.85))
                .frame(width: 5, height: 5)
            Text(label.loc)
                .font(.cairnScaled(size: 10.5, weight: .semibold))
                .tracking(0.2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
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
}

// MARK: - Preview

#if DEBUG
#Preview("Runs — populated") {
    RunsScreen()
        .cairnTheme()
}

#Preview("Runs — empty") {
    RunsScreen(runs: [])
        .cairnTheme()
}

#Preview("Runs — dark") {
    RunsScreen()
        .cairnTheme()
        .preferredColorScheme(.dark)
}

#Preview("Runs — empty, dark") {
    RunsScreen(runs: [])
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
