import XCTest
@testable import SinComboCore

final class SigningIdentityTests: XCTestCase {
    func testRequirement() {
        XCTAssertNil(SigningIdentity.requirement(for: []))
        XCTAssertNil(SigningIdentity.requirement(for: [""]))
        XCTAssertEqual(
            SigningIdentity.requirement(for: ["aa", "BB"]),
            #"certificate leaf = H"AA" or certificate leaf = H"BB""#
        )
    }

    func testAccepts() {
        XCTAssertTrue(SigningIdentity.accepts("6af0", among: ["6AF0"]))
        XCTAssertFalse(SigningIdentity.accepts("6AF0", among: ["0000"]))
        XCTAssertFalse(SigningIdentity.accepts("6AF0", among: []))
    }

    func testUnsignedBundleHasNoLeafCertificate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sincombo-unsigned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(SigningIdentity.leafHashes(of: dir), [])
    }
}
