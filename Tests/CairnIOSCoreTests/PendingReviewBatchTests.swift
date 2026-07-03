import Foundation
import Testing
import CairnCore
@testable import CairnIOSCore

/// The same-day batch-stacking heuristic: held groups expiring on the
/// same calendar day collapse into one batch row once they reach the
/// threshold, so a bulk delete doesn't bury smaller sets on other days.
@Suite("PendingReview — same-day batch stacking")
struct PendingReviewBatchTests {
    private typealias Group = PendingReviewScreen.PendingReviewGroup

    private static let day0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day3 = day0.addingTimeInterval(3 * 86_400) // a different calendar day

    /// Build sorted held groups + the base64-keyed confirmedDeletedAt map
    /// `heldRows` consumes, from (id, confirmed-deleted date) pairs. Each
    /// id gets a unique filename → one single-version group.
    private static func setup(_ items: [(id: String, at: Date)]) -> (groups: [Group], confirmed: [String: Date]) {
        let assets = items.map {
            ServerAsset(
                id: $0.id,
                checksum: Checksum(base64: "ck-\($0.id)"),
                originalFileName: "\($0.id).HEIC",
                fileCreatedAt: day0
            )
        }
        var byChecksum: [Checksum: Date] = [:]
        var byBase64: [String: Date] = [:]
        for it in items {
            byChecksum[Checksum(base64: "ck-\(it.id)")] = it.at
            byBase64["ck-\(it.id)"] = it.at
        }
        return (Group.grouped(assets, confirmedDeletedAt: byChecksum), byBase64)
    }

    /// The row "shape": each element is the batch's photo count, or nil
    /// for an individual row. Comparing this whole array (no subscripts →
    /// no index traps) makes any count/order bug a clean #expect failure.
    private static func shape(_ items: [(id: String, at: Date)], threshold: Int = 5) -> [Int?] {
        let (groups, confirmed) = setup(items)
        let rows = PendingReviewScreen.heldRows(
            groups, confirmedDeletedAt: confirmed, quarantineDays: 14,
            threshold: threshold, calendar: .current
        )
        return rows.map { if case .batch(_, let g) = $0 { return g.count } else { return nil } }
    }

    @Test("a same-day set at the threshold collapses into one batch")
    func batchesAtThreshold() {
        #expect(Self.shape((0..<5).map { ("a\($0)", Self.day0) }) == [5])
    }

    @Test("below threshold stays as individual rows")
    func belowThresholdSingles() {
        #expect(Self.shape((0..<4).map { ("a\($0)", Self.day0) }) == [nil, nil, nil, nil])
    }

    @Test("big same-day batch + small other-day set: batch first (soonest), then singles")
    func mixedDays() {
        let items = (0..<6).map { ("a\($0)", Self.day0) } + (0..<3).map { ("b\($0)", Self.day3) }
        #expect(Self.shape(items) == [6, nil, nil, nil])
    }

    @Test("two large same-day batches sort soonest-first regardless of input order")
    func twoBatches() {
        // Later day's items listed FIRST in input; sort still puts the
        // earlier day's batch first.
        let items = (0..<5).map { ("z\($0)", Self.day3) } + (0..<7).map { ("a\($0)", Self.day0) }
        #expect(Self.shape(items) == [7, 5])
    }

    @Test("threshold is honored: 4-item day stays individual, 5-item day batches")
    func thresholdBoundary() {
        let items = (0..<4).map { ("a\($0)", Self.day0) } + (0..<5).map { ("b\($0)", Self.day3) }
        #expect(Self.shape(items) == [nil, nil, nil, nil, 5])
    }
}
