import XCTest

final class SSHRouteTests: XCTestCase {
    func testExistingConnectionsDecodeWithoutJumpHost() throws {
        let old = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"old","host":"server","port":22,"username":"user","keyIDs":[],"savePassword":false}
        """
        let decoded = try JSONDecoder().decode(SavedConnection.self, from: Data(old.utf8))
        XCTAssertNil(decoded.jumpHostID)
        XCTAssertEqual(try SSHRoute.resolve(decoded, in: []), [decoded])
    }

    func testRoutePreservesEachHostsPortAndUsername() throws {
        let first = SavedConnection(host: "bastion.example", port: 52149, username: "alice")
        let second = SavedConnection(host: "inside.example", username: "bob", jumpHostID: first.id)
        let target = SavedConnection(host: "private.example", username: "charlie", jumpHostID: second.id)
        XCTAssertEqual(try SSHRoute.resolve(target, in: [target, first, second]), [first, second, target])
        XCTAssertEqual(try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(target)), target)
    }

    func testCyclesAndDeletedJumpHostsFailClosed() {
        var a = SavedConnection(host: "a", username: "alice")
        let b = SavedConnection(host: "b", username: "bob", jumpHostID: a.id)
        a.jumpHostID = b.id
        XCTAssertThrowsError(try SSHRoute.resolve(a, in: [a, b]))
        XCTAssertThrowsError(try SSHRoute.resolve(a, in: [a]))
        a.jumpHostID = a.id
        XCTAssertThrowsError(try SSHRoute.resolve(a, in: [a]))
    }
}
