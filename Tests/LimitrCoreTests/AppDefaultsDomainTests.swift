import XCTest
@testable import LimitrCore

final class AppDefaultsDomainTests: XCTestCase {
    /// The regression this exists for. `swift run LimitrApp` produces an unbundled
    /// executable, and `UserDefaults.standard` then keys off the process name instead of a
    /// bundle identifier — a second, empty account list that reads exactly like a first
    /// run. Everything the development build saves lands there and never reaches the
    /// packaged app's domain, while the account directories the lost profiles named stay on
    /// disk holding Keychain credentials nothing can address any more.
    func testRedirectsAnUnbundledBuildToThePackagedDomain() {
        XCTAssertEqual(AppDefaultsDomain.override(bundleIdentifier: nil), AppDefaultsDomain.name)
    }

    /// A bundled build's standard domain already *is* its bundle identifier. Asking for a
    /// suite with that same name is explicitly undefined, so the override has to stay out
    /// of the way.
    func testLeavesTheBundledBuildOnItsStandardDomain() {
        XCTAssertNil(AppDefaultsDomain.override(bundleIdentifier: AppDefaultsDomain.name))
    }

    /// A sandbox build deliberately runs on its own identifier to keep its accounts away
    /// from the real ones, so it must keep the domain it was given.
    func testLeavesAnyOtherBundledIdentifierAlone() {
        XCTAssertNil(AppDefaultsDomain.override(bundleIdentifier: "com.yogaesamahendra.limitr.sandbox"))
    }
}
