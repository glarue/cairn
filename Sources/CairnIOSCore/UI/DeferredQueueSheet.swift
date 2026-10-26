import SwiftUI
import Photos
import CairnCore

public struct DeferredQueueSheet: View {
    public let entries: [DeferredHashEntry]
    public let ceilingBytes: Int64?
    public let onClose: () -> Void

    @Environment(\.cairnTokens) private var t
    @State private var resolved: [ResolvedEntry] = []
    @State private var isLoading = true

    struct ResolvedEntry: Identifiable {
        let id: String
        let filename: String
        let reason: DeferredHashEntry.DeferReason
        let sizeBytes: Int64?
        let aboveCeiling: Bool
        let thumbnailData: Data?
    }

    public init(
        entries: [DeferredHashEntry] = [],
        ceilingBytes: Int64? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.entries = entries
        self.ceilingBytes = ceilingBytes
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            AppHeader(
                title: "Deferred queue".loc,
                subtitle: isLoading ? "Loading…".loc : (CairnL10n.isChinese ? "\(resolved.count) 项照片" : "\(resolved.count) assets"),
                leading: {
                    Button(action: onClose) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.cairnScaled(size: 13, weight: .semibold))
                            Text("Status".loc)
                                .font(.cairnScaled(size: 15))
                        }
                        .foregroundStyle(t.textBody)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                },
                trailing: { EmptyView() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                if !isLoading && !resolved.isEmpty {
                    let queued = resolved.filter { !$0.aboveCeiling }
                    let aboveCap = resolved.filter { $0.aboveCeiling }

                    if !queued.isEmpty {
                        KeylineSection("Pending hash".loc) {
                            Text("\(queued.count)")
                                .font(.cairnScaled(size: 11, weight: .semibold))
                                .tracking(0.99)
                                .foregroundStyle(t.textMuted)
                                .monospacedDigit()
                        }
                        CairnCard {
                            VStack(spacing: 0) {
                                ForEach(Array(queued.enumerated()), id: \.element.id) { idx, entry in
                                    entryRow(entry)
                                    if idx < queued.count - 1 { RowDivider() }
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    if !aboveCap.isEmpty {
                        KeylineSection("Above size cap".loc) {
                            Text("\(aboveCap.count)")
                                .font(.cairnScaled(size: 11, weight: .semibold))
                                .tracking(0.99)
                                .foregroundStyle(t.textMuted)
                                .monospacedDigit()
                        }
                        CairnCard {
                            VStack(spacing: 0) {
                                ForEach(Array(aboveCap.enumerated()), id: \.element.id) { idx, entry in
                                    entryRow(entry)
                                    if idx < aboveCap.count - 1 { RowDivider() }
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }

                if !isLoading && resolved.isEmpty {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(t.verifiedSoft).frame(width: 56, height: 56)
                            Image(systemName: "checkmark")
                                .font(.cairnScaled(size: 24, weight: .semibold))
                                .foregroundStyle(t.verifiedInk)
                        }
                        Text("Queue is empty".loc)
                            .font(.cairnScaled(size: 17, weight: .semibold))
                            .foregroundStyle(t.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                Spacer(minLength: 40)
                }
            }
        }
        .background(t.bg)
        .task { await resolveEntries() }
    }

    private func entryRow(_ entry: ResolvedEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnailView(entry)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.cairnScaled(size: 13, design: .monospaced))
                    .tracking(-0.065)
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(reasonLabel(entry.reason))
                    if let size = entry.sizeBytes {
                        Text("·")
                        Text(formatBytes(size))
                    }
                }
                .font(.cairnScaled(size: 11.5))
                .foregroundStyle(t.textMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func thumbnailView(_ entry: ResolvedEntry) -> some View {
        #if canImport(UIKit)
        if let data = entry.thumbnailData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            MockAssetThumb(filename: entry.filename, size: 44)
        }
        #else
        MockAssetThumb(filename: entry.filename, size: 44)
        #endif
    }

    private func reasonLabel(_ reason: DeferredHashEntry.DeferReason) -> String {
        switch reason {
        case .tooLarge: "too large".loc
        case .timedOut: "timed out".loc
        case .noHashableResources: "no resources".loc
        // The "above cap" group already gets its own section in the
        // sheet (resolved.aboveCeiling filter), but a row can still
        // carry this reason if the user changed the ceiling between
        // the hash attempt and now — keep the label short and aligned
        // with the section header copy.
        case .aboveHardCeiling: "above cap".loc
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private func resolveEntries() async {
        let ids = entries.map(\.localIdentifier)
        guard !ids.isEmpty else {
            isLoading = false
            return
        }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assetMap: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetMap[asset.localIdentifier] = asset
        }

        let manager = PHImageManager.default()
        let thumbOpts = PHImageRequestOptions()
        thumbOpts.deliveryMode = .fastFormat
        thumbOpts.isNetworkAccessAllowed = false
        thumbOpts.isSynchronous = false
        let thumbSize = CGSize(width: 88, height: 88)

        var out: [ResolvedEntry] = []
        for entry in entries {
            let asset = assetMap[entry.localIdentifier]
            let filename: String = {
                if let asset {
                    return PHAssetResource.assetResources(for: asset).first?.originalFilename ?? entry.localIdentifier
                }
                return entry.localIdentifier
            }()
            let aboveCeiling: Bool = {
                guard let ceil = ceilingBytes, let size = entry.sizeBytes else { return false }
                return size > ceil
            }()

            var thumbData: Data? = nil
            #if canImport(UIKit)
            if let asset {
                let img: UIImage? = await withCheckedContinuation { cont in
                    manager.requestImage(
                        for: asset,
                        targetSize: thumbSize,
                        contentMode: .aspectFill,
                        options: thumbOpts
                    ) { image, _ in
                        cont.resume(returning: image)
                    }
                }
                thumbData = img?.jpegData(compressionQuality: 0.5)
            }
            #endif

            out.append(ResolvedEntry(
                id: entry.localIdentifier,
                filename: filename,
                reason: entry.reason,
                sizeBytes: entry.sizeBytes,
                aboveCeiling: aboveCeiling,
                thumbnailData: thumbData
            ))
        }

        out.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        resolved = out
        isLoading = false
    }
}
