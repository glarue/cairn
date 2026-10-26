import SwiftUI

/// The review-and-sync modal — the safety-critical core flow. Mirrors
/// `screens/dryrun.jsx`. Multi-stage:
///
///   review → confirming → running → done
///
/// `review` is where the user sees the candidate grid, the safety-checks
/// list, and decides. `confirming` is the rust-banner second-confirm
/// (live mode only). `running` shows progress. `done` is the receipt.
///
/// In tripped mode (over the percent + floor cap), the layout is the same
/// but the CTA changes to "Proceed anyway" + a quieter "Raise threshold
/// to N% and retry" affordance — the design wants users to *see* the
/// candidates before deciding, not be hidden behind a separate screen.
///
/// Microcopy is verbatim from the prototype. See HANDOFF.md "Keep these
/// copies verbatim" — don't paraphrase.
public struct DryRunSheet: View {

    public enum Phase: Sendable, Equatable {
        case review, confirming, running, done
    }

    public let candidates: [CairnFixtures.CandidateFixture]
    public let library: CairnFixtures.LibrarySize
    public let maxDeletePercent: Double
    public let minDeleteFloor: Int
    public let forceTripped: Bool
    /// Whether Photos access is currently Full (vs Limited/Denied). Drives
    /// the real "Photos access is Full" safety-check row instead of a
    /// hardcoded green checkmark on a destructive surface.
    public let photoAccessIsFull: Bool
    public let onClose: () -> Void
    /// Runs the actual orchestrator call. Awaited from `runIt()` so the
    /// "running" phase reflects real work in flight and the "done"
    /// phase only appears after `onConfirm` returns. The previous
    /// `() -> Void` signature meant the sheet showed a fake 2-second
    /// success animation before the host had even started trashing —
    /// dismissing the sheet during that window (swipe or tap-away)
    /// silently skipped the actual trash call.
    public let onConfirm: () async -> Void

    @State private var phase: Phase = .review
    @State private var sort: Sort = .recent
    @State private var zoomedCandidate: CairnFixtures.CandidateFixture?

    @Environment(\.cairnTokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        candidates: [CairnFixtures.CandidateFixture] = CairnFixtures.candidates,
        library: CairnFixtures.LibrarySize = CairnFixtures.medium,
        maxDeletePercent: Double = 1.0,
        minDeleteFloor: Int = 5,
        forceTripped: Bool = false,
        photoAccessIsFull: Bool = true,
        onClose: @escaping () -> Void = {},
        onConfirm: @escaping () async -> Void = {}
    ) {
        self.candidates = candidates
        self.library = library
        self.maxDeletePercent = maxDeletePercent
        self.minDeleteFloor = minDeleteFloor
        self.forceTripped = forceTripped
        self.photoAccessIsFull = photoAccessIsFull
        self.onClose = onClose
        self.onConfirm = onConfirm
    }

    public enum Sort: Sendable { case recent, type }

    private var pct: Double {
        guard library.matched > 0 else { return 0 }
        return Double(candidates.count) / Double(library.matched) * 100
    }
    private var overPct: Bool { pct > maxDeletePercent }
    private var overFloor: Bool { candidates.count > minDeleteFloor }
    private var tripped: Bool { forceTripped || (overPct && overFloor) }

    private var totalBytes: Int { candidates.reduce(0) { $0 + $1.bytes } }
    private var livePairs: Int { candidates.filter { $0.kind == .livePair }.count }
    private var videoCount: Int { candidates.filter { $0.kind == .video }.count }

    private var sorted: [CairnFixtures.CandidateFixture] {
        switch sort {
        case .recent: return candidates
        case .type:
            return candidates.sorted { a, b in
                rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : a.name < b.name
            }
        }
    }

    private func rank(_ k: CairnFixtures.CandidateFixture.Kind) -> Int {
        switch k {
        case .video: 0
        case .livePair: 1
        case .photo: 2
        }
    }

    public var body: some View {
        // Native iOS sheet — `.presentationDetents` +
        // `.presentationDragIndicator(.visible)` give us the
        // standard grabber, swipe-down-to-dismiss, and resizable
        // heights without bespoke gesture plumbing.
        Group {
            switch phase {
            case .review, .confirming:
                reviewSheet
            case .running, .done:
                terminalSheet
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(t.surface)
        .overlay {
            if let zoomed = zoomedCandidate {
                ZStack {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                                zoomedCandidate = nil
                            }
                        }
                    VStack(spacing: 12) {
                        ImmichAssetThumb(assetId: zoomed.assetId, filename: zoomed.name, size: 280, isLivePair: zoomed.isLivePair)
                        Text(zoomed.name)
                            .font(.cairnScaled(size: 14, design: .monospaced))
                            .foregroundStyle(.white)
                        if !zoomed.date.isEmpty {
                            Text(zoomed.date)
                                .font(.cairnScaled(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Review

    private var reviewSheet: some View {
        VStack(spacing: 0) {
            header
            if tripped { trippedBanner }
            summaryStrip
            sortStrip
            candidateGrid
            safetyChecks
            actionsBar
        }
        .background(t.surface)
        .cairnBannerAnimation(value: tripped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ModeChip(tripped: tripped)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.cairnScaled(size: 14, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text(headerTitle)
                .font(.cairnScaled(size: 22, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(headerSubtitle)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var headerTitle: String {
        if tripped {
            return CairnL10n.isChinese
                ? "\(candidates.count) 项候选删除已超过上限"
                : "\(candidates.count) candidates is above your cap"
        }
        return CairnL10n.isChinese
            ? "将 Immich 上的 \(candidates.count) 项移入废纸篓？"
            : "Trash \(candidates.count) on Immich?"
    }

    private var headerSubtitle: String {
        if tripped { return "Nothing was touched. Review the photos before deciding.".loc }
        let bytesStr = CairnTimeHelpers.formatBytes(totalBytes)
        return CairnL10n.isChinese
            ? "\(bytesStr) · 在 Immich 废纸篓中保留 30 天"
            : "\(bytesStr) · stays in Immich's Trash for 30 days"
    }

    private var trippedBanner: some View {
        Callout(.danger, icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 2) {
                Text(CairnL10n.isChinese
                    ? String(format: "将移入废纸篓的照片占已匹配的 %.2f%%", pct)
                    : String(format: "%.2f%% of matched would be trashed", pct))
                    .fontWeight(.semibold)
                if CairnL10n.isChinese {
                    (Text("你的上限为 ") + Text(String(format: "%.1f%%", maxDeletePercent)).bold()
                        + Text("（且至少 ") + Text("\(minDeleteFloor)+").bold() + Text(" 项照片）。")
                        + Text("请浏览下方照片网格 — 是否与你在手机上删除的一致？"))
                        .opacity(0.9).fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("Your cap is ") + Text(String(format: "%.1f%%", maxDeletePercent)).bold()
                        + Text(" (and ") + Text("\(minDeleteFloor)+").bold() + Text(" assets). ")
                        + Text("Look through the grid — does it match what you deleted on your phone?"))
                        .opacity(0.9).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.cairnBanner)
    }

    private var summaryStrip: some View {
        CairnCard {
            HStack(spacing: 12) {
                MiniStat(label: (tripped ? "Over cap" : "Of matched").loc,
                         value: String(format: "%.2f%%", pct),
                         sub: CairnL10n.isChinese ? String(format: "上限 %.1f%%", maxDeletePercent) : String(format: "cap %.1f%%", maxDeletePercent),
                         tone: tripped ? .danger : .neutral)
                Rectangle().fill(t.divider).frame(width: 0.5)
                MiniStat(label: "Live pairs".loc, value: "\(livePairs)", sub: "still + motion".loc)
                Rectangle().fill(t.divider).frame(width: 0.5)
                MiniStat(label: "Videos".loc, value: "\(videoCount)")
                Rectangle().fill(t.divider).frame(width: 0.5)
                let bytesParts = CairnTimeHelpers.formatBytes(totalBytes).split(separator: " ")
                MiniStat(label: "Freed".loc,
                         value: String(bytesParts.first ?? "0"),
                         sub: bytesParts.count > 1 ? String(bytesParts[1]) : nil)
            }
            .padding(12)
        }
        .padding(.bottom, 12)
    }

    private var sortStrip: some View {
        HStack {
            Text(CairnL10n.isChinese ? "\(candidates.count) 张照片 · 轻点缩放" : "\(candidates.count) PHOTOS · TAP TO ZOOM")
                .font(.cairnScaled(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textHint)
            Spacer()
            HStack(spacing: 2) {
                SegBtn(label: "Recent".loc, active: sort == .recent) { sort = .recent }
                SegBtn(label: "By type".loc, active: sort == .type) { sort = .type }
            }
            .padding(2)
            .background(t.bg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var candidateGrid: some View {
        ScrollView {
            CairnCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                    ForEach(sorted) { c in
                        Button {
                            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                                zoomedCandidate = c
                            }
                        } label: {
                            VStack(spacing: 4) {
                                ImmichAssetThumb(assetId: c.assetId, filename: c.name, size: 76, isLivePair: c.isLivePair)
                                Text(c.name.replacingOccurrences(of: ".HEIC", with: "").replacingOccurrences(of: ".MP4", with: ""))
                                    .font(.cairnScaled(size: 9.5, design: .monospaced))
                                    .foregroundStyle(t.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            c.isLivePair
                                ? "\(c.name), Live Photo. Candidate for trashing on Immich. Tap to zoom."
                                : "\(c.name). Candidate for trashing on Immich. Tap to zoom."
                        )
                    }
                }
                .padding(10)
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 260)
    }

    private var safetyChecks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SAFETY CHECKS".loc)
                .font(.cairnScaled(size: 11, weight: .semibold)).tracking(0.9)
                .foregroundStyle(t.textHint)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            CairnCard {
                VStack(spacing: 0) {
                    CheckRow(label: CairnL10n.isChinese ? String(format: "低于 %.1f%% 上限", maxDeletePercent) : String(format: "Under %.1f%% cap", maxDeletePercent), pass: !overPct)
                    RowDivider()
                    CheckRow(label: CairnL10n.isChinese ? "超过 \(minDeleteFloor) 项照片底线" : "Over \(minDeleteFloor)-asset floor", pass: overFloor)
                    RowDivider()
                    CheckRow(label: "Server returned > 0 assets".loc, pass: library.server > 0)
                    RowDivider()
                    CheckRow(label: "Photos access is Full".loc, pass: photoAccessIsFull)
                    RowDivider()
                    CheckRow(label: "Purview set populated".loc, pass: library.matched > 0)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var actionsBar: some View {
        VStack(spacing: 10) {
            switch phase {
            case .review:
                if tripped { trippedActions } else { normalActions }
            case .confirming:
                confirmingActions
            case .running, .done:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            t.surface.overlay(
                Rectangle().fill(t.divider).frame(height: 0.5),
                alignment: .top
            )
        )
    }

    private var normalActions: some View {
        HStack(spacing: 10) {
            ActionButton(label: "Not now".loc, role: .secondary, action: onClose)
                .frame(maxWidth: .infinity)
            ActionButton(label: CairnL10n.isChinese ? "将 \(candidates.count) 项移入废纸篓" : "Move \(candidates.count) to Trash", icon: "trash", role: .danger) {
                phase = .confirming
            }
            .frame(maxWidth: .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private var trippedActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ActionButton(label: "Cancel".loc, role: .secondary, action: onClose)
                    .frame(maxWidth: .infinity)
                ActionButton(label: "Proceed anyway".loc, icon: "exclamationmark.triangle", role: .primary) {
                    phase = .confirming
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var confirmingActions: some View {
        VStack(spacing: 12) {
            Callout(.danger, icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm once more".loc).fontWeight(.semibold)
                    if CairnL10n.isChinese {
                        (Text.cairnWord + Text(" 将标记 ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 11.5, design: .monospaced))
                            + Text(" 然后将 \(candidates.count) 项资产移入 Immich 废纸篓。"))
                            .opacity(0.9).fixedSize(horizontal: false, vertical: true)
                    } else {
                        (Text.cairnWord + Text(" will tag ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 11.5, design: .monospaced))
                            + Text(" then move \(candidates.count) asset\(candidates.count == 1 ? "" : "s") to Immich's Trash."))
                            .opacity(0.9).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                ActionButton(label: "Back".loc, role: .secondary) { phase = .review }
                    .frame(maxWidth: .infinity)
                ActionButton(label: CairnL10n.isChinese ? "确认，将 \(candidates.count) 项移入废纸篓" : "Yes, move \(candidates.count) to Trash", role: .danger) {
                    runIt()
                }
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Terminal phases

    private var terminalSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if phase == .running {
                    runningContent
                } else {
                    doneContent
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
        }
        .background(t.surface)
    }

    private var runningContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(t.surfaceAlt).frame(width: 48, height: 48)
                ProgressView().tint(t.textBody)
            }
            Text("Tagging and moving to Trash".loc)
                .font(.cairnScaled(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(t.text)
            Text(CairnL10n.isChinese ? "正在写入标记 · \(candidates.count) 项资产" : "Writing breadcrumb · \(candidates.count) assets")
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
        }
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(t.verifiedSoft)
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark")
                    .font(.cairnScaled(size: 22, weight: .semibold))
                    .foregroundStyle(t.verifiedInk)
            }
            Text(CairnL10n.isChinese ? "\(candidates.count) 项已移入废纸篓" : "\(candidates.count) moved to Trash")
                .font(.cairnScaled(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(t.text)
            if CairnL10n.isChinese {
                (Text("已添加标记 ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 11.5, design: .monospaced)) + Text("。可在 Immich 废纸篓中保留 30 天。"))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            } else {
                (Text("Tagged ") + Text("cairn/v1/run/…").font(.cairnScaled(size: 11.5, design: .monospaced)) + Text(". Recoverable in Immich's Trash for 30 days."))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

            ActionButton(label: "Back to status".loc, role: .primary) {
                onClose()
            }
            .padding(.top, 8)
        }
    }

    private func runIt() {
        phase = .running
        Task { @MainActor in
            await onConfirm()
            phase = .done
        }
    }
}

// MARK: - Sub-views

private struct ModeChip: View {
    let tripped: Bool

    @Environment(\.cairnTokens) private var t

    var body: some View {
        let (label, soft, ink): (String, Color, Color) = {
            if tripped { return ("Tripped · review needed", t.dangerSoft, t.dangerInk) }
            return ("Live · moves to Trash", t.dangerSoft.mix(with: t.danger, amount: 0.30), t.dangerInk)
        }()
        return Text(CairnL10n.isChinese ? label.loc : label.loc.uppercased())
            .font(.cairnScaled(size: 10, weight: .semibold))
            .tracking(0.9)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(ink)
            .background(soft)
            .clipShape(Capsule())
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    var sub: String? = nil
    var tone: Tone = .neutral

    enum Tone { case neutral, danger }

    @Environment(\.cairnTokens) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CairnL10n.isChinese ? label.loc : label.loc.uppercased())
                .font(.cairnScaled(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(t.textHint)
            Text(value)
                .font(.cairnScaled(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone == .danger ? t.dangerInk : t.text)
            if let sub {
                Text(sub)
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(t.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegBtn: View {
    let label: String
    let active: Bool
    let action: () -> Void

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            Text(label.loc)
                .font(.cairnScaled(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(active ? t.text : t.textMuted)
                .background(active ? t.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CheckRow: View {
    let label: String
    let pass: Bool

    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pass ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(pass ? t.verifiedInk : t.dangerInk)
                .font(.cairnScaled(size: 14))
            Text(label.loc)
                .font(.cairnScaled(size: 14))
                .foregroundStyle(t.textBody)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ActionButton: View {
    let label: String
    var icon: String? = nil
    let role: Role
    let action: () -> Void

    enum Role { case primary, secondary, danger, quiet }

    @Environment(\.cairnTokens) private var t

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.cairnScaled(size: 13, weight: .semibold))
                }
                Text(label.loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(ink)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var bg: Color {
        switch role {
        case .primary: t.primary
        case .secondary: t.surfaceAlt
        case .danger: t.danger
        case .quiet: Color.clear
        }
    }
    private var ink: Color {
        switch role {
        case .primary: t.primaryInk
        case .secondary: t.text
        case .danger: t.bg.opacity(0.95)  // light text on red
        case .quiet: t.textMuted
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("DryRun — review") {
    DryRunSheet()
        .cairnTheme()
}

#Preview("DryRun — tripped (forced)") {
    DryRunSheet(forceTripped: true)
        .cairnTheme()
}

#Preview("DryRun — dark") {
    DryRunSheet()
        .cairnTheme()
        .preferredColorScheme(.dark)
}
#endif
