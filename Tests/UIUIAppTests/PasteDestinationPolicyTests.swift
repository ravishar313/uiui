import ApplicationServices
import XCTest
@testable import UIUI

final class PasteDestinationPolicyTests: XCTestCase {
    func testUnknownAndContainerRolesAllowNormalPasteWhenAXCannotDescribeEditor() {
        for role: String? in [nil, kAXGroupRole, "AXWebArea", "CustomEditor"] {
            XCTAssertTrue(TextDestinationPolicy.allowsPaste(role: role, subrole: nil, enabled: nil, containsProtectedContent: nil))
        }
    }

    func testPositiveProtectionVetoesEvenWhenTheRoleIsUnknown() {
        for role: String? in [nil, kAXGroupRole, "CustomEditor"] {
            XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: role, subrole: kAXSecureTextFieldSubrole, enabled: nil, containsProtectedContent: nil))
            XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: role, subrole: nil, enabled: false, containsProtectedContent: nil))
            XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: role, subrole: nil, enabled: nil, containsProtectedContent: true))
        }
    }
}
