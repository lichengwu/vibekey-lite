import XCTest
@testable import VibeKeyLiteCore

final class VibeKeyAppProfileSwitcherTests: XCTestCase {
    private let mapping: [String: ProfileID] = [
        "com.apple.Terminal": .a,
        "com.apple.Safari": .b,
    ]

    func testMappedAppSwitches() {
        XCTAssertEqual(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.apple.Safari", mapping: mapping, currentProfile: .a
            ),
            .b
        )
        XCTAssertEqual(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.apple.Terminal", mapping: mapping, currentProfile: .b
            ),
            .a
        )
    }

    func testAlreadyActiveProfileDoesNotSwitch() {
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.apple.Safari", mapping: mapping, currentProfile: .b
            )
        )
    }

    func testUnmappedAppKeepsCurrentProfile() {
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.unknown.App", mapping: mapping, currentProfile: .a
            )
        )
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.unknown.App", mapping: mapping, currentProfile: .b
            )
        )
    }

    func testNilOrEmptyBundleIDIsIgnored() {
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: nil, mapping: mapping, currentProfile: .a
            )
        )
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "", mapping: mapping, currentProfile: .a
            )
        )
    }

    func testEmptyMappingDisablesFeature() {
        XCTAssertNil(
            VibeKeyAppProfileSwitcher.targetProfile(
                frontmostBundleID: "com.apple.Safari", mapping: [:], currentProfile: .a
            )
        )
    }

    // MARK: - Persist-or-rollback contract

    func testApplySwitchPersistsTargetOnSuccess() {
        var persisted: [ProfileID] = []
        let result = VibeKeyAppProfileSwitcher.applySwitch(
            target: .b, currentProfile: .a
        ) { profile in
            persisted.append(profile)
            return true
        }
        XCTAssertEqual(result, .b)
        XCTAssertEqual(persisted, [.b])
    }

    func testApplySwitchRollsBackOnPersistFailure() {
        let result = VibeKeyAppProfileSwitcher.applySwitch(
            target: .b, currentProfile: .a
        ) { _ in false }
        XCTAssertEqual(result, .a, "failed persist must keep the previous profile")
    }

    func testApplySwitchNoTargetDoesNotPersist() {
        var persistCalls = 0
        let result = VibeKeyAppProfileSwitcher.applySwitch(
            target: nil, currentProfile: .a
        ) { _ in
            persistCalls += 1
            return true
        }
        XCTAssertEqual(result, .a)
        XCTAssertEqual(persistCalls, 0)
    }

    func testApplySwitchSameProfileDoesNotPersist() {
        var persistCalls = 0
        let result = VibeKeyAppProfileSwitcher.applySwitch(
            target: .a, currentProfile: .a
        ) { _ in
            persistCalls += 1
            return true
        }
        XCTAssertEqual(result, .a)
        XCTAssertEqual(persistCalls, 0)
    }
}

final class VibeKeyAppActivationDebouncerTests: XCTestCase {
    func testSingleActivationFires() {
        var debouncer = VibeKeyAppActivationDebouncer()
        let token = debouncer.activate("com.apple.Terminal")
        XCTAssertEqual(debouncer.fire(generation: token), "com.apple.Terminal")
    }

    func testRapidStormOnlyLastSurvives() {
        var debouncer = VibeKeyAppActivationDebouncer()
        let first = debouncer.activate("com.apple.Safari")
        let second = debouncer.activate("com.apple.Terminal")
        let third = debouncer.activate("com.microsoft.VSCode")
        // Stale timers fire nothing.
        XCTAssertNil(debouncer.fire(generation: first))
        XCTAssertNil(debouncer.fire(generation: second))
        XCTAssertEqual(debouncer.fire(generation: third), "com.microsoft.VSCode")
    }

    func testFireConsumesPendingOnce() {
        var debouncer = VibeKeyAppActivationDebouncer()
        let token = debouncer.activate("com.apple.Terminal")
        XCTAssertEqual(debouncer.fire(generation: token), "com.apple.Terminal")
        XCTAssertNil(debouncer.fire(generation: token), "second fire must be empty")
    }

    func testNilActivationIsCarriedThrough() {
        var debouncer = VibeKeyAppActivationDebouncer()
        let token = debouncer.activate(nil)
        XCTAssertNil(debouncer.fire(generation: token))
    }
}

final class AppProfileMappingConfigTests: XCTestCase {
    func testLegacyConfigWithoutMappingDecodesToEmpty() throws {
        // A config.json written before M1 has no appProfileMapping key.
        let legacy = """
        {
          "activeProfile": "a",
          "profileA": {},
          "profileB": {},
          "needsHardwareSync": true,
          "offlineProfile": "a"
        }
        """
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.appProfileMapping, [:])
        XCTAssertEqual(config.activeProfile, .a)
    }

    func testMappingRoundTrip() throws {
        var config = AppConfiguration.default
        config.appProfileMapping = [
            "com.apple.Terminal": .a,
            "com.microsoft.VSCode": .b,
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(decoded.appProfileMapping, config.appProfileMapping)
    }

    func testDefaultMappingIsEmpty() {
        XCTAssertEqual(AppConfiguration.default.appProfileMapping, [:])
    }

    func testInvalidProfileValueInMappingFailsDecoding() {
        let bad = """
        {
          "activeProfile": "a",
          "profileA": {},
          "profileB": {},
          "appProfileMapping": {"com.apple.Terminal": "c"}
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(AppConfiguration.self, from: Data(bad.utf8))
        )
    }
}