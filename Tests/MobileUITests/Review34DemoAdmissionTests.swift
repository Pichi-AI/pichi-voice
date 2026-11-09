import XCTest
#if canImport(Review34DemoAdmissionSupport)
@testable import Review34DemoAdmissionSupport
#endif

final class Review34DemoAdmissionTests: XCTestCase {
    func testPreparedGuestAdmissionRejectsWrongRevisionAndOccupiedState() {
        let sha = "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
        func check(_ revision: String? = sha, _ flag: String? = "prepared-final-page-only",
                   _ pad: Bool = true, _ out: Bool = true, _ idle: Bool = true, _ empty: Bool = true) -> Bool {
            Review34DemoAdmission.admitted(revision: revision, optIn: flag, isPad: pad,
                signedOut: out, idle: idle, credentialsEmpty: empty)
        }
        XCTAssertTrue(check())
        XCTAssertFalse(check("older")); XCTAssertFalse(check(nil)); XCTAssertFalse(check(sha, nil))
        XCTAssertFalse(check(sha, "prepared-final-page-only", false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, true, false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, true, true, false))
    }

    func testUnknownCredentialStateIsNeverAdmittedAsEmpty() {
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: nil, placeholder: "Password"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: nil, placeholder: nil))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "synthetic user input", placeholder: "Password"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "••••", placeholder: "Password"))
    }

    func testKnownEmptyAndVisiblePlaceholderAreAdmitted() {
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "", placeholder: nil))
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "Password", placeholder: "Password"))
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "Пароль", placeholder: "Пароль"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "Password", placeholder: nil))
    }
}
