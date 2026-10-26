import SwiftUI
import CairnCore

/// Read-only viewer for journal history that `DeletionJournal.rotateIfNeeded`
/// has moved out of the live file. Presented as a sheet from Settings →
/// Advanced. Rows are loaded on demand via the injected `load` closure and
/// held only for the screen's lifetime — nothing is cached on the model, so
/// closing the sheet frees the (potentially large) archived history.
///
/// Mirrors the Status-screen journal tail's vocabulary — severity dot, time,
/// event token, message — laid out vertically for a plain `List` (the Status
/// row scrolls horizontally; an archive of thousands of rows wants vertical
/// scrolling and tap-to-inspect instead). Tapping a row opens its raw JSON.
public struct ArchivedHistoryScreen: View {
    let load: @Sendable () async -> [CairnFixtures.JournalTailEntry]

    @Environment(\.cairnTokens) private var t
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [CairnFixtures.JournalTailEntry] = []
    @State private var isLoading = true
    @State private var detail: CairnFixtures.JournalTailEntry?

    public init(load: @escaping @Sendable () async -> [CairnFixtures.JournalTailEntry]) {
        self.load = load
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Archived history".loc)
                .cairnNavigationTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done".loc) { dismiss() }
                    }
                }
        }
        .task {
            let loaded = await load()
            rows = loaded
            isLoading = false
        }
        .sheet(item: $detail) { entry in
            ArchivedRawJSONSheet(entry: entry)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(rows) { row in
                        ArchivedHistoryRow(entry: row)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = row }
                    }
                } header: {
                    Text(CairnL10n.isChinese ? "\(rows.count) 条归档事件 · 最新的排在前面" : "\(rows.count) archived event\(rows.count == 1 ? "" : "s") · newest first")
                        .font(.cairnScaled(size: 11))
                        .foregroundStyle(t.textHint)
                } footer: {
                    if CairnL10n.isChinese {
                        (Text("当活跃历史超过约 500 次运行时，") + .cairnWord + Text(" 会自动将较早的运行记录移至此处。不会删除任何内容 — 还原仍可处理归档运行，导出备份也包含它们。"))
                            .font(.cairnScaled(size: 11))
                            .foregroundStyle(t.textHint)
                            .padding(.top, 4)
                    } else {
                        Text("cairn moves older runs here automatically once your live history passes about 500 runs. Nothing is deleted — restore still reaches archived runs, and Export includes them.")
                            .font(.cairnScaled(size: 11))
                            .foregroundStyle(t.textHint)
                            .padding(.top, 4)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(t.textHint)
            Text("Nothing archived yet".loc)
                .font(.cairnScaled(size: 15, weight: .semibold))
                .foregroundStyle(t.text)
            if CairnL10n.isChinese {
                (Text.cairnWord + Text(" 会在活跃历史（状态和运行记录）中保留最近约 500 次运行。较早的运行会自动移至此处 — 不会删除任何内容。"))
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            } else {
                Text("cairn keeps your most recent ~500 runs in the live history (Status and Runs). Older runs move here automatically — none are deleted.")
                    .font(.cairnScaled(size: 13))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One archived event, two lines: a header line (time · event · runId) and
/// the message. Severity drives the dot, glyph, and event-token color so a
/// reader can scan for trouble without reading every word.
private struct ArchivedHistoryRow: View {
    let entry: CairnFixtures.JournalTailEntry
    @Environment(\.cairnTokens) private var t

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
                .frame(width: 8, alignment: .center)
                .padding(.top, 4)
            Image(systemName: entry.glyph)
                .font(.cairnScaled(size: 11, weight: .semibold))
                .foregroundStyle(severityColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.time)
                        .font(.cairnScaled(size: 11.5, design: .monospaced))
                        .foregroundStyle(t.textHint)
                    Text(entry.event)
                        .font(.cairnScaled(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(severityColor)
                    Spacer(minLength: 0)
                    if !entry.runIdSuffix.isEmpty {
                        Text(entry.runIdSuffix)
                            .font(.cairnScaled(size: 11, design: .monospaced))
                            .foregroundStyle(t.textHint)
                    }
                }
                Text(entry.message)
                    .font(.cairnScaled(size: 12, design: .monospaced))
                    .foregroundStyle(t.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var severityColor: Color {
        switch entry.severity {
        case .info:  return t.textHint
        case .ok:    return t.verifiedInk
        case .warn:  return t.pendingInk
        case .error: return t.dangerInk
        }
    }
}

/// Raw-JSON inspector for one archived row — the same forensic detail the
/// Status tail offers on long-press, here on tap (a `List` row's tap is its
/// natural affordance). Selectable so a bug report can copy it verbatim.
private struct ArchivedRawJSONSheet: View {
    let entry: CairnFixtures.JournalTailEntry
    @Environment(\.cairnTokens) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(entry.rawJSON ?? "No raw event data for this row.".loc)
                    .font(.cairnScaled(size: 12, design: .monospaced))
                    .foregroundStyle(t.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(entry.event)
            .cairnNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".loc) { dismiss() }
                }
            }
        }
    }
}
