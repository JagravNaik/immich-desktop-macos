import XCTest
@testable import ImmichMacApp

final class MemoryPlaybackTests: XCTestCase {
  func testPlaybackSequenceWrapsInBothDirections() {
    var sequence = MemoryPlaybackSequence()

    sequence.advance(by: -1, itemCount: 3)
    XCTAssertEqual(sequence.index, 2)

    sequence.advance(by: 1, itemCount: 3)
    XCTAssertEqual(sequence.index, 0)
  }

  func testPlaybackSequenceHandlesEmptyAndShrinkingLists() {
    var sequence = MemoryPlaybackSequence()
    sequence.advance(by: -1, itemCount: 0)
    XCTAssertEqual(sequence.index, 0)

    sequence.advance(by: -1, itemCount: 4)
    XCTAssertEqual(sequence.index, 3)
    sequence.advance(by: 1, itemCount: 2)
    XCTAssertEqual(sequence.index, 0)

    sequence.reset()
    XCTAssertEqual(sequence.index, 0)
  }
}
