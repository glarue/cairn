import Foundation
import Testing
@testable import CairnCore

@Suite("CairnSettings")
struct CairnSettingsTests {

    @Test("defaults match the documented factory values")
    func defaultsMatchDocumented() {
        let d = CairnSettings.defaults
        #expect(d.maxDeletePercent == 1.0)
        #expect(d.minDeleteFloor == 5)
        #expect(d.notifyOnAbort == true)
        #expect(d.verboseLogging == false)
        #expect(d.deletionStrictness == .strict)
        #expect(d.quarantineDays == 14)
        #expect(d.iCloudDownloadLimitMB == 100)
        #expect(d.iCloudMaxEverBytesMB == nil)
    }

    @Test("auto-trash eligibility: Cautious is manual, Balanced + Autonomous auto-trash")
    func autoTrashEligibility() {
        #expect(DeletionStrictness.strict.autoTrashesEligibleCandidates == false)
        #expect(DeletionStrictness.trusting.autoTrashesEligibleCandidates == true)
        #expect(DeletionStrictness.autonomous.autoTrashesEligibleCandidates == true)
        // The default is Cautious, so auto-trash is OFF out of the box —
        // deleting server photos automatically is opt-in.
        #expect(CairnSettings.defaults.deletionStrictness.autoTrashesEligibleCandidates == false)
    }

    @Test("quarantineDaysRange covers the documented 0...90 span")
    func quarantineDaysRangeIsDocumented() {
        #expect(CairnSettings.quarantineDaysRange == 0...90)
        #expect(CairnSettings.quarantineDaysRange.contains(CairnSettings.defaults.quarantineDays))
    }

    @Test("DeletionStrictness encodes as its raw string for stable on-disk format")
    func strictnessRawValueIsStable() throws {
        let strict = try JSONEncoder().encode(DeletionStrictness.strict)
        let trusting = try JSONEncoder().encode(DeletionStrictness.trusting)
        #expect(String(data: strict, encoding: .utf8) == #""strict""#)
        #expect(String(data: trusting, encoding: .utf8) == #""trusting""#)
    }

    @Test("round-trip encode-decode preserves every field, including new ones")
    func roundTripPreservesEveryField() throws {
        let original = CairnSettings(
            maxDeletePercent: 2.5,
            minDeleteFloor: 11,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 30,
            iCloudDownloadLimitMB: 250,
            iCloudMaxEverBytesMB: 2048
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.quarantineDays == 30)
        #expect(decoded.deletionStrictness == .strict)
        #expect(decoded.iCloudDownloadLimitMB == 250)
        #expect(decoded.iCloudMaxEverBytesMB == 2048)
    }

    @Test("legacy JSON without iCloudMaxEverBytesMB decodes as nil (hard ceiling off)")
    func legacyJSONMissingHardCeilingUsesDefault() throws {
        // A settings blob written before the hard-ceiling field existed.
        // Must decode without throwing and keep the feature disabled.
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting",
            "quarantineDays": 14,
            "iCloudDownloadLimitMB": 50
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.iCloudMaxEverBytesMB == nil)
        #expect(decoded.iCloudDownloadLimitMB == 50)
    }

    @Test("legacy JSON without quarantineDays decodes with the default value")
    func legacyJSONMissingQuarantineDaysUsesDefault() throws {
        // A settings blob written before the quarantine field existed. The
        // custom init(from:) must tolerate the missing key.
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "strict"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.quarantineDays == CairnSettings.defaults.quarantineDays)
        #expect(decoded.deletionStrictness == .strict)
        #expect(decoded.maxDeletePercent == 1.0)
    }

    @Test("legacy JSON without deletionStrictness falls back to the current default")
    func legacyJSONMissingStrictnessUsesDefault() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.deletionStrictness == CairnSettings.defaults.deletionStrictness)
        #expect(decoded.quarantineDays == CairnSettings.defaults.quarantineDays)
    }

    @Test("indexingScope defaults to .fullLibrary")
    func indexingScopeDefaultsFullLibrary() {
        #expect(CairnSettings.defaults.indexingScope == .fullLibrary)
        #expect(CairnSettings.defaults.indexingScope.isRestricted == false)
    }

    @Test("timeDisplayFormat defaults to .system")
    func timeDisplayFormatDefaultsSystem() {
        #expect(CairnSettings.defaults.timeDisplayFormat == .system)
    }

    @Test("hashConcurrency defaults to 4 within the documented 1...16 range")
    func hashConcurrencyDefaultsAndRange() {
        #expect(CairnSettings.defaults.hashConcurrency == 4)
        #expect(CairnSettings.hashConcurrencyRange == 1...16)
        #expect(CairnSettings.hashConcurrencyRange.contains(CairnSettings.defaults.hashConcurrency))
    }

    @Test("legacy JSON without hashConcurrency decodes with the default value")
    func legacyJSONMissingHashConcurrencyUsesDefault() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.hashConcurrency == CairnSettings.defaults.hashConcurrency)
    }

    @Test("clampedHashConcurrency forces out-of-range values into the slider bounds")
    func clampedHashConcurrencyHonorsRange() {
        func clamped(_ raw: Int) -> Int {
            var s = CairnSettings.defaults
            s.hashConcurrency = raw
            return s.clampedHashConcurrency
        }
        #expect(clamped(0) == 1)     // below floor (and the serial-opt-out boundary)
        #expect(clamped(-5) == 1)    // a garbage persisted/poke value
        #expect(clamped(1) == 1)
        #expect(clamped(8) == 8)     // in-range passes through
        #expect(clamped(16) == 16)
        #expect(clamped(99) == 16)   // above ceiling
    }

    @Test("legacy JSON without timeDisplayFormat decodes as .system")
    func legacyJSONMissingTimeFormatUsesSystem() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.timeDisplayFormat == .system)
    }

    @Test("timeDisplayFormat round-trips through Codable for every case")
    func timeDisplayFormatRoundTripsAllCases() throws {
        for format in TimeDisplayFormat.allCases {
            let settings = CairnSettings(timeDisplayFormat: format)
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
            #expect(decoded.timeDisplayFormat == format)
        }
    }

    @Test("useIncrementalServerSync defaults to false (initial roll-out is opt-in)")
    func useIncrementalServerSyncDefaultsFalse() {
        #expect(CairnSettings.defaults.useIncrementalServerSync == false)
    }

    @Test("legacy JSON without useIncrementalServerSync decodes as false")
    func legacyJSONMissingIncrementalSyncDefaultsFalse() throws {
        // The plan flips the default once a release cycle of beta
        // soak-testing surfaces no regressions. Until then, decoding
        // legacy payloads as `false` matches the install-default and
        // keeps the existing paginated path in charge.
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.useIncrementalServerSync == false)
    }

    @Test("useIncrementalServerSync round-trips both true and false")
    func useIncrementalServerSyncRoundTrips() throws {
        for value in [true, false] {
            let original = CairnSettings(useIncrementalServerSync: value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
            #expect(decoded.useIncrementalServerSync == value)
        }
    }

    @Test("fastInitialScan defaults to false (opt-in via onboarding)")
    func fastInitialScanDefaultsFalse() {
        // The optimization is a meaningful tradeoff (faster setup vs
        // cairn-verified checksums everywhere); the user picks at
        // onboarding rather than getting it silently. Default off
        // keeps existing installs on the well-understood path.
        #expect(CairnSettings.defaults.fastInitialScan == false)
    }

    @Test("legacy JSON without fastInitialScan decodes as false (opt-in)")
    func legacyJSONMissingFastInitialScanDefaultsFalse() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.fastInitialScan == false)
    }

    @Test("fastInitialScan round-trips both true and false")
    func fastInitialScanRoundTrips() throws {
        for value in [true, false] {
            let original = CairnSettings(fastInitialScan: value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
            #expect(decoded.fastInitialScan == value)
        }
    }

    @Test("propagationMaxAgeDays defaults to nil (off)")
    func propagationMaxAgeDaysDefaultsNil() {
        #expect(CairnSettings.defaults.propagationMaxAgeDays == nil)
    }

    @Test("legacy JSON without propagationMaxAgeDays decodes as nil")
    func legacyJSONMissingPropagationMaxAgeDecodesNil() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.propagationMaxAgeDays == nil)
    }

    @Test("propagationMaxAgeDays round-trips a real value and nil")
    func propagationMaxAgeDaysRoundTrips() throws {
        for value in [nil, 30, 365, 3650] as [Int?] {
            let original = CairnSettings(propagationMaxAgeDays: value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
            #expect(decoded.propagationMaxAgeDays == value)
        }
    }

    @Test("propagationMaxAgeDaysRange covers the documented 30...3650 span")
    func propagationMaxAgeDaysRangeIsDocumented() {
        #expect(CairnSettings.propagationMaxAgeDaysRange == 30...3650)
    }

    @Test("keepScreenAwakeDuringSync defaults to true (on for first sync)")
    func keepScreenAwakeDuringSyncDefaultsTrue() {
        #expect(CairnSettings.defaults.keepScreenAwakeDuringSync == true)
    }

    @Test("legacy JSON without keepScreenAwakeDuringSync decodes as true (matches fresh-install behavior)")
    func legacyJSONMissingKeepScreenAwakeDecodesTrue() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting"
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.keepScreenAwakeDuringSync == true)
    }

    @Test("keepScreenAwakeDuringSync round-trips both true and false")
    func keepScreenAwakeDuringSyncRoundTrips() throws {
        for value in [true, false] {
            let original = CairnSettings(keepScreenAwakeDuringSync: value)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
            #expect(decoded.keepScreenAwakeDuringSync == value)
        }
    }

    @Test("legacy JSON without indexingScope decodes as .fullLibrary")
    func legacyJSONMissingIndexingScopeUsesFullLibrary() throws {
        let legacyJSON = """
        {
            "maxDeletePercent": 1.0,
            "minDeleteFloor": 5,
            "notifyOnAbort": true,
            "verboseLogging": false,
            "deletionStrictness": "trusting",
            "quarantineDays": 14
        }
        """
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.indexingScope == .fullLibrary)
    }

    @Test(".selectedAlbums round-trips with stable on-disk shape")
    func selectedAlbumsRoundTrips() throws {
        let original = CairnSettings(
            indexingScope: .selectedAlbums(["AB12-camera-roll", "EF56-family"])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
        #expect(decoded.indexingScope == .selectedAlbums(["AB12-camera-roll", "EF56-family"]))
        #expect(decoded.indexingScope.albumLocalIdentifiers == ["AB12-camera-roll", "EF56-family"])
        #expect(decoded.indexingScope.isRestricted)
    }

    @Test(".selectedAlbums with empty set is a valid degraded state")
    func selectedAlbumsEmptyRoundTrips() throws {
        let original = CairnSettings(indexingScope: .selectedAlbums([]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CairnSettings.self, from: data)
        #expect(decoded.indexingScope == .selectedAlbums([]))
        #expect(decoded.indexingScope.isRestricted)
        #expect(decoded.indexingScope.albumLocalIdentifiers.isEmpty)
    }

    @Test("IndexingScope encodes as a tagged-payload object, not Swift's synthesized form")
    func indexingScopeOnDiskShapeIsTaggedPayload() throws {
        // The custom encoding produces `{"kind":"selectedAlbums","albums":[...]}`
        // rather than the synthesized `{"selectedAlbums":{"_0":[...]}}`.
        // Lock this in so the on-disk format stays stable across Swift
        // version bumps that might affect synthesized enum coding.
        let value = IndexingScope.selectedAlbums(["A", "B"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(data: encoder.encode(value), encoding: .utf8) ?? ""
        #expect(json.contains("\"kind\":\"selectedAlbums\""))
        #expect(json.contains("\"albums\":[\"A\",\"B\"]"))

        let fullJSON = try String(data: encoder.encode(IndexingScope.fullLibrary), encoding: .utf8) ?? ""
        #expect(fullJSON == #"{"kind":"fullLibrary"}"#)
    }
}

@Suite("JSONFileSettingsStore")
struct JSONFileSettingsStoreTests {

    private func tempPath() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "settings-\(UUID().uuidString).json")
    }

    @Test("missing file loads as defaults")
    func missingLoadsDefaults() async throws {
        let store = JSONFileSettingsStore(path: tempPath())
        let loaded = try await store.load()
        #expect(loaded == .defaults)
    }

    @Test("save + load round-trips every field")
    func roundTripPreservesFields() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileSettingsStore(path: path)
        let custom = CairnSettings(
            maxDeletePercent: 3.5,
            minDeleteFloor: 42,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 21
        )
        try await store.save(custom)

        let loaded = try await store.load()
        #expect(loaded == custom)
        #expect(loaded.maxDeletePercent == 3.5)
        #expect(loaded.minDeleteFloor == 42)
        #expect(loaded.notifyOnAbort == false)
        #expect(loaded.verboseLogging == true)
        #expect(loaded.deletionStrictness == .strict)
        #expect(loaded.quarantineDays == 21)
    }

    @Test("saved settings survive across store instances at the same path")
    func survivesAcrossInstances() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = JSONFileSettingsStore(path: path)
        let custom = CairnSettings(
            maxDeletePercent: 2.25,
            minDeleteFloor: 10,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 7
        )
        try await first.save(custom)

        let second = JSONFileSettingsStore(path: path)
        #expect(try await second.load() == custom)
    }

    @Test("save replaces previous contents — no merging with prior state")
    func saveReplacesPrevious() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let store = JSONFileSettingsStore(path: path)

        let first = CairnSettings(
            maxDeletePercent: 9.0,
            minDeleteFloor: 99,
            notifyOnAbort: false,
            verboseLogging: true,
            deletionStrictness: .strict,
            quarantineDays: 60
        )
        try await store.save(first)

        // Second save flips everything back toward defaults; the expectation
        // is that load() returns exactly `second`, not a field-wise merge
        // with `first`.
        let second = CairnSettings(
            maxDeletePercent: 0.5,
            minDeleteFloor: 1,
            notifyOnAbort: true,
            verboseLogging: false,
            deletionStrictness: .trusting,
            quarantineDays: 0
        )
        try await store.save(second)

        let loaded = try await store.load()
        #expect(loaded == second)
        #expect(loaded != first)
    }
}
