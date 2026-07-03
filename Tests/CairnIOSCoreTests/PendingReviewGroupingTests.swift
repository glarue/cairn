import Foundation
import Testing
import CairnCore
@testable import CairnIOSCore

/// Unit-level coverage for `PendingReviewScreen.PendingReviewGroup.grouped`.
/// The helper is the only piece of the Pending Review redesign that holds
/// real logic; the rest of the screen is rendering. Tests pin the grouping
/// shape (key partitioning, ordering, version sort within a group) without
/// spinning up a SwiftUI view.
@Suite("PendingReviewScreen — grouping")
struct PendingReviewGroupingTests {

    private typealias Group = PendingReviewScreen.PendingReviewGroup

    private static func asset(
        _ id: String,
        checksum ck: String,
        name: String?,
        date: Date?
    ) -> ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: ck),
            originalFileName: name,
            fileCreatedAt: date
        )
    }

    private static let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let d2 = Date(timeIntervalSince1970: 1_700_001_000)

    @Test("empty input produces empty groups")
    func emptyInput() {
        let groups = Group.grouped([])
        #expect(groups.isEmpty)
    }

    @Test("all-singleton input produces N one-version groups")
    func allSingletons() {
        let assets = [
            Self.asset("a", checksum: "ck-a", name: "A.HEIC", date: Self.d1),
            Self.asset("b", checksum: "ck-b", name: "B.HEIC", date: Self.d1),
            Self.asset("c", checksum: "ck-c", name: "C.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.versions.count == 1 })
    }

    @Test("same filename + creationDate collapses to one group with 2 versions")
    func sameFilenameSameDate() {
        let assets = [
            Self.asset("a", checksum: "ck-original", name: "IMG_4821.HEIC", date: Self.d1),
            Self.asset("b", checksum: "ck-edited", name: "IMG_4821.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 1)
        #expect(groups.first?.versions.count == 2)
        #expect(groups.first?.key == .byFilenameAndDate(filename: "IMG_4821.HEIC", date: Self.d1))
    }

    @Test("same filename, different creationDate → two groups")
    func sameFilenameDifferentDate() {
        let assets = [
            Self.asset("a", checksum: "ck-1", name: "IMG.HEIC", date: Self.d1),
            Self.asset("b", checksum: "ck-2", name: "IMG.HEIC", date: Self.d2),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 2)
    }

    @Test("same creationDate, different filename → two groups")
    func sameDateDifferentFilename() {
        let assets = [
            Self.asset("a", checksum: "ck-1", name: "A.HEIC", date: Self.d1),
            Self.asset("b", checksum: "ck-2", name: "B.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 2)
    }

    @Test("mixed input: 5 candidates, 2 forming a pair, 3 singletons → 4 groups in stable order")
    func mixedInput() {
        let assets = [
            Self.asset("a1", checksum: "ck-a1", name: "A.HEIC", date: Self.d1),
            Self.asset("b",  checksum: "ck-b",  name: "B.HEIC", date: Self.d1),
            Self.asset("a2", checksum: "ck-a2", name: "A.HEIC", date: Self.d1), // pairs with a1
            Self.asset("c",  checksum: "ck-c",  name: "C.HEIC", date: Self.d1),
            Self.asset("d",  checksum: "ck-d",  name: "D.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 4)
        // No confirmed-deleted stamps here, so cross-group order falls to
        // the representative-id tiebreak: a1 < b < c < d → A, B, C, D.
        let names = groups.map { Self.filenameInKey($0.key) }
        #expect(names == ["A.HEIC", "B.HEIC", "C.HEIC", "D.HEIC"])
        // The A group has both versions.
        #expect(groups[0].versions.count == 2)
        #expect(groups[1...].allSatisfy { $0.versions.count == 1 })
    }

    /// Pulls the filename out of a filename-keyed `GroupKey`. Tests that
    /// only exercise the fallback path use this; source-id keys return
    /// nil. Lives at the test layer because the property is fileprivate
    /// to the module.
    private static func filenameInKey(_ key: Group.GroupKey) -> String? {
        if case .byFilenameAndDate(let f, _) = key { return f }
        return nil
    }

    @Test("anchored version sorts first within a group")
    func anchoredFirst() {
        let original = Checksum(base64: "ck-original")
        let edited = Checksum(base64: "ck-edited")
        let assets = [
            // Edited listed first to confirm sort, not stable order, drives placement.
            Self.asset("e", checksum: edited.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("o", checksum: original.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(
            assets,
            firstObservedAnchors: [original]
        )
        #expect(groups.count == 1)
        #expect(groups[0].versions.first?.checksum == original)
        #expect(groups[0].firstObservedChecksums == [original])
    }

    @Test("tie-breaker by confirmedDeletedAt ascending then by id")
    func tieBreakers() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_005_000)
        let cks1 = Checksum(base64: "ck-1")
        let cks2 = Checksum(base64: "ck-2")
        let cks3 = Checksum(base64: "ck-3")
        // No anchors. cks1 has earliest retired, cks2 has later, cks3 has none.
        let assets = [
            Self.asset("zzz", checksum: cks3.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("aaa", checksum: cks2.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("mmm", checksum: cks1.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        let confirmedAt: [Checksum: Date] = [
            cks1: earlier,
            cks2: later,
        ]
        let groups = Group.grouped(
            assets,
            firstObservedAnchors: [],
            confirmedDeletedAt: confirmedAt
        )
        #expect(groups.count == 1)
        let order = groups[0].versions.map(\.checksum)
        // Expect: cks1 (earlier retired) → cks2 (later retired) → cks3 (no retire stamp).
        #expect(order == [cks1, cks2, cks3])
    }

    @Test("tie on retired stamp falls back to id ordering for stability")
    func idTieBreaker() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let cksA = Checksum(base64: "ck-A")
        let cksB = Checksum(base64: "ck-B")
        let assets = [
            Self.asset("zzz", checksum: cksA.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("aaa", checksum: cksB.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        let confirmedAt: [Checksum: Date] = [cksA: stamp, cksB: stamp]
        let groups = Group.grouped(
            assets,
            firstObservedAnchors: [],
            confirmedDeletedAt: confirmedAt
        )
        // "aaa" < "zzz" lexicographically → "aaa" first.
        #expect(groups[0].versions.map(\.id) == ["aaa", "zzz"])
    }

    @Test("nil filename + nil creationDate group together but separately from named assets")
    func bothNilsCollapseSeparately() {
        let assets = [
            Self.asset("u1", checksum: "ck-u1", name: nil, date: nil),
            Self.asset("u2", checksum: "ck-u2", name: nil, date: nil),
            Self.asset("named", checksum: "ck-named", name: "IMG.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        // Two groups: one for the (nil,nil) pair, one for the named.
        #expect(groups.count == 2)
        let unknown = groups.first { $0.key == .byFilenameAndDate(filename: nil, date: nil) }
        #expect(unknown?.versions.count == 2)
        let named = groups.first { $0.key == .byFilenameAndDate(filename: "IMG.HEIC", date: Self.d1) }
        #expect(named?.versions.count == 1)
    }

    @Test("nil filename does not collapse with non-nil filename of the same date")
    func nilFilenameDistinctFromNamed() {
        let assets = [
            Self.asset("u", checksum: "ck-u", name: nil, date: Self.d1),
            Self.asset("n", checksum: "ck-n", name: "IMG.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 2)
    }

    @Test("nil creationDate does not collapse with non-nil creationDate of the same filename")
    func nilDateDistinctFromDated() {
        let assets = [
            Self.asset("u", checksum: "ck-u", name: "IMG.HEIC", date: nil),
            Self.asset("n", checksum: "ck-n", name: "IMG.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(assets)
        #expect(groups.count == 2)
    }

    @Test("firstObservedChecksums is the intersection of input anchors and group's checksums")
    func firstObservedScoping() {
        let cksA = Checksum(base64: "ck-A")
        let cksB = Checksum(base64: "ck-B")
        let unrelated = Checksum(base64: "ck-unrelated")
        let assets = [
            Self.asset("a", checksum: cksA.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("b", checksum: cksB.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        let groups = Group.grouped(
            assets,
            firstObservedAnchors: [cksA, unrelated]
        )
        #expect(groups[0].firstObservedChecksums == [cksA])
    }

    // MARK: - Source-id grouping (the edit + delete cross-mode case)

    @Test("two assets sharing source localId but different filenames+dates group together")
    func sourceIdCollapsesAcrossMetadataMismatch() {
        // Models the bug case: an edited Live Photo lands on Immich
        // with a microsecond-mismatched fileCreatedAt vs the original
        // upload. Filename grouping fails, but the reconciler captured
        // both checksums under the same PhotoKit localIdentifier.
        let cksOriginal = Checksum(base64: "ck-original")
        let cksEdited = Checksum(base64: "ck-edited")
        let assets = [
            Self.asset("o", checksum: cksOriginal.base64, name: "IMG_42.HEIC", date: Self.d1),
            Self.asset("e", checksum: cksEdited.base64, name: "IMG_42_E.HEIC", date: Self.d2),
        ]
        let sourceIds: [Checksum: String] = [
            cksOriginal: "phasset/abc-123",
            cksEdited: "phasset/abc-123",
        ]
        let groups = Group.grouped(
            assets,
            sourceLocalIdentifiersByChecksum: sourceIds
        )
        #expect(groups.count == 1)
        #expect(groups[0].versions.count == 2)
        #expect(groups[0].key == .bySourceId("phasset/abc-123"))
    }

    @Test("one asset with source-id, one without → two distinct groups (no spurious join)")
    func sourceIdAbsentDoesNotJoinFilenameBucket() {
        // The asset without a source-id falls back to filename grouping.
        // It must NOT collapse with the source-id-keyed asset even if
        // they happen to share filename+date (which they don't, here).
        let cksWithSrc = Checksum(base64: "ck-src")
        let cksNoSrc = Checksum(base64: "ck-nosrc")
        let assets = [
            Self.asset("s", checksum: cksWithSrc.base64, name: "A.HEIC", date: Self.d1),
            Self.asset("n", checksum: cksNoSrc.base64, name: "B.HEIC", date: Self.d1),
        ]
        let sourceIds: [Checksum: String] = [cksWithSrc: "phasset/xyz"]
        let groups = Group.grouped(
            assets,
            sourceLocalIdentifiersByChecksum: sourceIds
        )
        #expect(groups.count == 2)
        let keys = Set(groups.map(\.key))
        #expect(keys.contains(.bySourceId("phasset/xyz")))
        #expect(keys.contains(.byFilenameAndDate(filename: "B.HEIC", date: Self.d1)))
    }

    @Test("filename+date fallback still groups when no source-id is provided for either asset")
    func filenameFallbackStillGroups() {
        let cks1 = Checksum(base64: "ck-1")
        let cks2 = Checksum(base64: "ck-2")
        let assets = [
            Self.asset("a", checksum: cks1.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("b", checksum: cks2.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        // Empty source-id map — every asset hits the fallback.
        let groups = Group.grouped(
            assets,
            sourceLocalIdentifiersByChecksum: [:]
        )
        #expect(groups.count == 1)
        #expect(groups[0].versions.count == 2)
        #expect(groups[0].key == .byFilenameAndDate(filename: "IMG.HEIC", date: Self.d1))
    }

    @Test("source-id wins over filename when an asset matches both")
    func sourceIdWinsOverFilename() {
        // Both assets share filename+date AND source-id. Pinning the
        // priority means a future regression that swaps the order
        // would land here, not in the field.
        let cks1 = Checksum(base64: "ck-1")
        let cks2 = Checksum(base64: "ck-2")
        let assets = [
            Self.asset("a", checksum: cks1.base64, name: "IMG.HEIC", date: Self.d1),
            Self.asset("b", checksum: cks2.base64, name: "IMG.HEIC", date: Self.d1),
        ]
        let sourceIds: [Checksum: String] = [
            cks1: "phasset/shared",
            cks2: "phasset/shared",
        ]
        let groups = Group.grouped(
            assets,
            sourceLocalIdentifiersByChecksum: sourceIds
        )
        #expect(groups.count == 1)
        #expect(groups[0].key == .bySourceId("phasset/shared"))
    }

    @Test("cross-group order is soonest-to-trash first, independent of input order")
    func soonestEligibleGroupSortsFirst() {
        let ckEarly = Checksum(base64: "ck-early")
        let ckLate = Checksum(base64: "ck-late")
        // "later" (d2) appears FIRST in the input; "earlier" (d1) second.
        // A stable-but-input-order sort would keep them in this order —
        // the soonest-first sort must flip them.
        let assets = [
            Self.asset("z-late", checksum: ckLate.base64, name: "LATE.HEIC", date: Self.d2),
            Self.asset("a-early", checksum: ckEarly.base64, name: "EARLY.HEIC", date: Self.d1),
        ]
        let confirmed: [Checksum: Date] = [
            ckEarly: Self.d1,          // eligible sooner
            ckLate: Self.d2,           // eligible later
        ]
        let groups = Group.grouped(assets, confirmedDeletedAt: confirmed)
        #expect(groups.count == 2)
        #expect(Self.filenameInKey(groups[0].key) == "EARLY.HEIC")
        #expect(Self.filenameInKey(groups[1].key) == "LATE.HEIC")
    }

    @Test("cross-group order is stable across repeated grouping of shuffled input")
    func groupOrderIsDeterministic() {
        let ckA = Checksum(base64: "ck-aaa")
        let ckB = Checksum(base64: "ck-bbb")
        let ckC = Checksum(base64: "ck-ccc")
        let confirmed: [Checksum: Date] = [ckA: Self.d1, ckB: Self.d1, ckC: Self.d1]
        // Same three assets, same stamps, two different input orders.
        let order1 = [
            Self.asset("aaa", checksum: ckA.base64, name: "A.HEIC", date: Self.d1),
            Self.asset("bbb", checksum: ckB.base64, name: "B.HEIC", date: Self.d1),
            Self.asset("ccc", checksum: ckC.base64, name: "C.HEIC", date: Self.d1),
        ]
        let order2 = [order1[2], order1[0], order1[1]]
        let g1 = Group.grouped(order1, confirmedDeletedAt: confirmed).map(\.versions.first?.id)
        let g2 = Group.grouped(order2, confirmedDeletedAt: confirmed).map(\.versions.first?.id)
        // Identical (id-tiebreak) regardless of the shuffled input order.
        #expect(g1 == ["aaa", "bbb", "ccc"])
        #expect(g1 == g2)
    }

    @Test("empty input still produces empty groups when source-id map is provided")
    func emptyInputWithSourceIdMap() {
        // Defensive: source-id map is unused for an empty asset list,
        // and the helper must not crash or produce phantom groups.
        let groups = Group.grouped(
            [],
            sourceLocalIdentifiersByChecksum: [Checksum(base64: "stale"): "phasset/abc"]
        )
        #expect(groups.isEmpty)
    }
}
