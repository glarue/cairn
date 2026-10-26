import SwiftUI
import Photos
import CairnCore

/// Multi-select picker over the user's Photos albums. Driven by
/// `CairnSettings.indexingScope` — when the user picks "Selected
/// albums" in Settings, this sheet lets them choose which albums.
///
/// The on-disk identity is `PHAssetCollection.localIdentifier` (a
/// stable UUID-shaped string). We display titles + asset counts, but
/// the saved `Set<String>` is identifiers — so renaming an album
/// later doesn't break the selection.
///
/// Authorization: this sheet assumes Photos access is already granted
/// (cairn's setup flow gates on it). If access is missing the sheet
/// renders a friendly empty state pointing the user back to Settings →
/// Photos. Limited Access works the same way as Full — `fetchAssetCollections`
/// returns the user-created albums regardless of selection state.
public struct AlbumPickerSheet: View {

    public let initialSelection: Set<String>
    public let onClose: () -> Void
    public let onSave: (Set<String>) -> Void

    /// Optional fixture override for previews/tests. When non-nil,
    /// PhotoKit is bypassed entirely and the sheet renders against
    /// the supplied albums. Production callers leave this nil.
    public let albumsOverride: [Album]?

    @Environment(\.cairnTokens) private var t
    @State private var selection: Set<String>
    @State private var albums: [Album] = []
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case ready
        case unauthorized
    }

    /// Lightweight value type so previews + tests don't need
    /// `PHAssetCollection` instances. `localIdentifier` matches what
    /// PhotoKit returns; titles + counts are what we'd show in the row.
    public struct Album: Identifiable, Sendable, Equatable {
        public let localIdentifier: String
        public let title: String
        public let assetCount: Int

        public var id: String { localIdentifier }

        public init(localIdentifier: String, title: String, assetCount: Int) {
            self.localIdentifier = localIdentifier
            self.title = title
            self.assetCount = assetCount
        }
    }

    public init(
        initialSelection: Set<String> = [],
        albumsOverride: [Album]? = nil,
        onClose: @escaping () -> Void = {},
        onSave: @escaping (Set<String>) -> Void = { _ in }
    ) {
        self.initialSelection = initialSelection
        self.albumsOverride = albumsOverride
        self.onClose = onClose
        self.onSave = onSave
        self._selection = State(initialValue: initialSelection)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(t.bg)
        .task { await loadAlbums() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel".loc, action: onClose)
                .font(.cairnScaled(size: 15))
                .foregroundStyle(t.textBody)
            Spacer()
            VStack(spacing: 1) {
                Text("Selected albums".loc)
                    .font(.cairnScaled(size: 15, weight: .semibold))
                    .foregroundStyle(t.text)
                Text(selectionSummary)
                    .font(.cairnScaled(size: 11))
                    .foregroundStyle(t.textMuted)
                    .monospacedDigit()
            }
            Spacer()
            Button("Done".loc) {
                onSave(selection)
                onClose()
            }
            .font(.cairnScaled(size: 15, weight: .semibold))
            .foregroundStyle(selection.isEmpty ? t.textMuted : t.infoInk)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(t.divider)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var selectionSummary: String {
        let n = selection.count
        switch n {
        case 0: return "Pick at least one".loc
        case 1: return CairnL10n.isChinese ? "已选择 1 个相册" : "1 album selected"
        default: return CairnL10n.isChinese ? "已选择 \(n) 个相册" : "\(n) albums selected"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingState
        case .unauthorized:
            unauthorizedState
        case .ready where albums.isEmpty:
            emptyState
        case .ready:
            albumList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading albums…".loc)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unauthorizedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.cairnScaled(size: 28))
                .foregroundStyle(t.textMuted)
            Text("Photos access required".loc)
                .font(.cairnScaled(size: 15, weight: .semibold))
                .foregroundStyle(t.text)
            Text("Grant Full Photos access in Settings → cairn → Photos to pick albums.".loc)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.cairnScaled(size: 28))
                .foregroundStyle(t.textMuted)
            Text("No user-created albums".loc)
                .font(.cairnScaled(size: 15, weight: .semibold))
                .foregroundStyle(t.text)
            Text("Create an album in Photos.app to scope cairn to it.".loc)
                .font(.cairnScaled(size: 13))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumList: some View {
        ScrollView {
            VStack(spacing: 0) {
                CairnCard {
                    VStack(spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { idx, album in
                            albumRow(album)
                            if idx < albums.count - 1 { RowDivider() }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Spacer(minLength: 24)
            }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        let isSelected = selection.contains(album.localIdentifier)
        return Button {
            toggle(album.localIdentifier)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.cairnScaled(size: 19))
                    .foregroundStyle(isSelected ? t.infoInk : t.textHint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.cairnScaled(size: 15))
                        .foregroundStyle(t.text)
                    Text(assetCountLabel(album.assetCount))
                        .font(.cairnScaled(size: 12))
                        .foregroundStyle(t.textMuted)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(album.title), \(assetCountLabel(album.assetCount))")
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }

    private func assetCountLabel(_ n: Int) -> String {
        CairnL10n.isChinese ? "\(n) 张照片" : (n == 1 ? "1 photo" : "\(n) photos")
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    // MARK: - PhotoKit loading

    @MainActor
    private func loadAlbums() async {
        if let override = albumsOverride {
            self.albums = override
            self.loadState = .ready
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            self.loadState = .unauthorized
            return
        }
        // Enumerate user-created albums on the calling actor; PhotoKit
        // calls are thread-safe for read operations. Sort alphabetically
        // for predictable display order.
        let collected = await Self.collectUserAlbums()
        self.albums = collected
        self.loadState = .ready
    }

    /// Off-main enumeration of user-created albums (`.albumRegular`).
    /// Returns titles + asset counts. Smart albums (Recents, Favorites,
    /// Hidden) are excluded — too coarse to meaningfully scope, and
    /// users almost always want their own organization.
    nonisolated static func collectUserAlbums() async -> [Album] {
        await Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .albumRegular,
                options: opts
            )
            var out: [Album] = []
            out.reserveCapacity(collections.count)
            collections.enumerateObjects { collection, _, _ in
                let title = collection.localizedTitle ?? "Untitled album"
                // Per-album asset count via a fetch that includes hidden
                // assets so the count matches what cairn actually
                // enumerates. Cheap — PhotoKit indexes membership.
                let assetOpts = PHFetchOptions()
                assetOpts.includeHiddenAssets = true
                let assets = PHAsset.fetchAssets(in: collection, options: assetOpts)
                out.append(Album(
                    localIdentifier: collection.localIdentifier,
                    title: title,
                    assetCount: assets.count
                ))
            }
            return out
        }.value
    }
}

#if DEBUG
private let albumPickerPreviewFixtures: [AlbumPickerSheet.Album] = [
    .init(localIdentifier: "AB12-camera-roll", title: "Camera Roll", assetCount: 4_216),
    .init(localIdentifier: "CD34-screenshots", title: "Screenshots", assetCount: 312),
    .init(localIdentifier: "EF56-family",      title: "Family",      assetCount: 89),
    .init(localIdentifier: "GH78-pets",        title: "Pets",        assetCount: 42),
    .init(localIdentifier: "IJ90-travel-2025", title: "Travel 2025", assetCount: 1_703),
]

#Preview("Album picker — empty selection") {
    AlbumPickerSheet(
        initialSelection: [],
        albumsOverride: albumPickerPreviewFixtures
    )
    .cairnTheme()
}

#Preview("Album picker — partial selection") {
    AlbumPickerSheet(
        initialSelection: ["AB12-camera-roll", "EF56-family"],
        albumsOverride: albumPickerPreviewFixtures
    )
    .cairnTheme()
}

#Preview("Album picker — dark") {
    AlbumPickerSheet(
        initialSelection: ["AB12-camera-roll"],
        albumsOverride: albumPickerPreviewFixtures
    )
    .cairnTheme()
    .preferredColorScheme(.dark)
}

#Preview("Album picker — empty library") {
    AlbumPickerSheet(
        initialSelection: [],
        albumsOverride: []
    )
    .cairnTheme()
}
#endif
