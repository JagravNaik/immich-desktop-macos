import XCTest
@testable import ImmichMacApp

final class VideoTrimTests: XCTestCase {
  func testValidatedRangeClampsEndpointsToMediaDuration() {
    XCTAssertEqual(
      VideoTrimRange.validated(start: -2, end: 14, duration: 10),
      VideoTrimRange(start: 0, end: 10)
    )
  }

  func testValidatedRangeRejectsEmptyAndReversedRanges() {
    XCTAssertNil(VideoTrimRange.validated(start: 4, end: 4, duration: 10))
    XCTAssertNil(VideoTrimRange.validated(start: 7, end: 3, duration: 10))
    XCTAssertNil(VideoTrimRange.validated(start: 11, end: 15, duration: 10))
  }

  func testValidatedRangeRejectsInvalidDurationOrEndpoints() {
    XCTAssertNil(VideoTrimRange.validated(start: 0, end: 1, duration: 0))
    XCTAssertNil(VideoTrimRange.validated(start: 0, end: 1, duration: .infinity))
    XCTAssertNil(VideoTrimRange.validated(start: .nan, end: 1, duration: 10))
  }
}
