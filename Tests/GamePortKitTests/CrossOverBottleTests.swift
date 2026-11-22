import XCTest
@testable import GamePortKit

final class CrossOverBottleTests: XCTestCase {
    func testBottleProfileIDsAreSafeAndStable() {
        let item = CrossOverBottleLaunchItem(bottleName: "My Steam (2)", bottlePath: URL(fileURLWithPath: "/x"),
                                             title: "G", kind: .steam(appID: 945360))
        XCTAssertEqual(GamePort.bottleProfileID(item), "cx-my-steam-2-945360")
    }

    func testOnlySteamGamesCanBeAdopted() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-cx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let kit = GamePort(paths: Paths(root: temp))
        let item = CrossOverBottleLaunchItem(bottleName: "B", bottlePath: temp, title: "Battle.net", kind: .battleNet)
        XCTAssertThrowsError(try kit.adoptCrossOverBottleGame(item))
        let missing = CrossOverBottleLaunchItem(bottleName: "B", bottlePath: temp.appendingPathComponent("nope"),
                                                title: "G", kind: .steam(appID: 945360))
        XCTAssertThrowsError(try kit.adoptCrossOverBottleGame(missing), "a bottle without drive_c is refused")
        XCTAssertNil(kit.bottleProfile(for: missing))
    }
}
