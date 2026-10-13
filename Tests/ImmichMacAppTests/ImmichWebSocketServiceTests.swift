import XCTest
@testable import ImmichMacApp

final class ImmichWebSocketServiceTests: XCTestCase {
  @MainActor
  func testReleaseVersionsNormalizeVersionObjects() throws {
    let versions = try XCTUnwrap(
      ImmichWebSocketService.releaseVersions(from: [
        "releaseVersion": ["major": 3, "minor": 3, "patch": 1, "prerelease": "rc.2"],
        "serverVersion": ["major": 3, "minor": 2, "patch": 0],
      ])
    )

    XCTAssertEqual(versions.releaseVersion, "3.3.1-rc.2")
    XCTAssertEqual(versions.serverVersion, "3.2.0")
  }

  @MainActor
  func testReleaseVersionsAllowMissingPrereleaseAndServerVersion() throws {
    let versions = try XCTUnwrap(
      ImmichWebSocketService.releaseVersions(from: [
        "releaseVersion": ["major": 4, "minor": 0, "patch": 0],
      ])
    )

    XCTAssertEqual(versions.releaseVersion, "4.0.0")
    XCTAssertNil(versions.serverVersion)
  }

  @MainActor
  func testReleaseVersionsRejectMalformedReleaseVersion() {
    XCTAssertNil(
      ImmichWebSocketService.releaseVersions(from: [
        "releaseVersion": ["major": 3, "minor": 3, "patch": 1, "prerelease": "01"],
      ])
    )
  }

  @MainActor
  func testEngineIOHeartbeatRespondsToServerPingWithPongOnly() {
    XCTAssertEqual(
      ImmichWebSocketService.engineIOHeartbeatResponse(toServerPacket: "2"),
      "3"
    )
    XCTAssertEqual(
      ImmichWebSocketService.engineIOHeartbeatResponse(toServerPacket: "2probe"),
      "3probe"
    )
    XCTAssertNil(ImmichWebSocketService.engineIOHeartbeatResponse(toServerPacket: "3"))
    XCTAssertNil(ImmichWebSocketService.engineIOHeartbeatResponse(toServerPacket: "40"))
  }
}
