import XCTest
@testable import PopKitCore

final class ExclusionRulesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "PopKitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsExcludePasswordManagers() {
        let rules = ExclusionRules(defaults: defaults)
        XCTAssertTrue(rules.isExcluded("com.apple.keychainaccess"))
        XCTAssertFalse(rules.isExcluded("com.apple.TextEdit"))
        XCTAssertFalse(rules.isExcluded(nil))
    }

    func testMatchingIgnoresCase() {
        let rules = ExclusionRules(defaults: defaults)
        XCTAssertTrue(rules.isExcluded("COM.APPLE.LOGINWINDOW"))
    }

    func testPauseSuppressesEverything() {
        let rules = ExclusionRules(defaults: defaults)
        XCTAssertFalse(rules.shouldSuppress(frontmostBundleID: "com.apple.TextEdit"))
        rules.isPaused = true
        XCTAssertTrue(rules.shouldSuppress(frontmostBundleID: "com.apple.TextEdit"))
    }

    func testExcludeAndIncludePersist() {
        let rules = ExclusionRules(defaults: defaults)
        rules.exclude("com.apple.Terminal")
        rules.exclude("com.apple.terminal")  // no duplicate
        XCTAssertEqual(rules.excludedBundleIDs.filter { $0.lowercased() == "com.apple.terminal" }.count, 1)
        XCTAssertTrue(ExclusionRules(defaults: defaults).isExcluded("com.apple.Terminal"))

        rules.include("com.apple.Terminal")
        XCTAssertFalse(rules.isExcluded("com.apple.Terminal"))
        XCTAssertTrue(rules.isExcluded("com.apple.keychainaccess"))
    }
}
