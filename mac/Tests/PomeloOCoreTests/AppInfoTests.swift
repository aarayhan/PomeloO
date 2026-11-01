import XCTest
@testable import PomeloOCore

final class AppInfoTests: XCTestCase {
    func testAppNameIsPomeloO() {
        XCTAssertEqual(AppInfo.name, "PomeloO")
    }
}
