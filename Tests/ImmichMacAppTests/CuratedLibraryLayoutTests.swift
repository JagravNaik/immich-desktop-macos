import CoreGraphics
import XCTest
@testable import ImmichMacApp

final class CuratedLibraryLayoutTests: XCTestCase {
  func testYearColumnsFollowPhotosThresholds() {
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 1, isLandscape: true), 1)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 3, isLandscape: true), 1)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 4, isLandscape: true), 2)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 8, isLandscape: true), 2)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 9, isLandscape: true), 3)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 5, isLandscape: false), 1)
    XCTAssertEqual(CuratedLibrary.yearColumns(yearCount: 6, isLandscape: false), 2)
  }

  func testSingleYearCardKeepsWithin80PercentOfHeightAt1Point5Aspect() {
    let size = CuratedLibrary.yearCardSize(container: CGSize(width: 1600, height: 700), columns: 1)
    XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.001)
    XCTAssertEqual(size.height, 700 * 0.8, accuracy: 0.001)
  }

  func testMultiColumnYearCardsAreSquareAndFillWidth() {
    let size = CuratedLibrary.yearCardSize(container: CGSize(width: 1000, height: 800), columns: 2)
    XCTAssertEqual(size.width, size.height, accuracy: 0.001)
    // 2 cards + 1 gap + 2 insets fill the width.
    XCTAssertEqual(size.width * 2 + CuratedLibrary.yearCardSpacing + CuratedLibrary.cardHorizontalInset * 2, 1000, accuracy: 0.001)
  }

  func testMonthRowsPromoteBusyMonthsWithoutReordering() {
    let rows = CuratedLibrary.monthRows(sections: [
      ("2024-12-01", 300), ("2024-11-01", 40), ("2024-10-01", 30),
      ("2024-09-01", 20), ("2024-08-01", 25), ("2024-07-01", 200),
      ("2024-06-01", 10), ("2024-05-01", 12),
      ("2024-04-01", 5),
    ])
    XCTAssertEqual(rows.map(\.kind), [.heroLeading, .heroTrailing, .pair, .single])
    XCTAssertEqual(rows.flatMap(\.sectionIDs), [
      "2024-12-01", "2024-11-01", "2024-10-01", "2024-09-01", "2024-08-01",
      "2024-07-01", "2024-06-01", "2024-05-01", "2024-04-01",
    ])
  }

  func testEvenMonthsBecomePairs() {
    let rows = CuratedLibrary.monthRows(sections: [("a", 10), ("b", 11), ("c", 12), ("d", 10)])
    XCTAssertEqual(rows.map(\.kind), [.pair, .pair])
  }

  func testHeroRowHeightGivesTheHeroA1Point5Aspect() {
    let width: CGFloat = 900
    let height = CuratedLibrary.monthRowHeight(kind: .heroLeading, width: width)
    let heroWidth = (width - CuratedLibrary.monthCardSpacing) * 2 / 3
    XCTAssertEqual(heroWidth / height, 1.5, accuracy: 0.001)
  }

  func testKeyItemPrefersFavoriteThenLandscapeStill() {
    func item(_ id: String, favorite: Bool = false, video: Bool = false, ratio: CGFloat = 0.75) -> AppState.PhotoItem {
      AppState.PhotoItem(
        id: id, source: .remoteAsset(id: id), title: id, date: Date(), isFavorite: favorite, isVideo: video,
        isImported: false, livePhotoVideoID: nil, latitude: nil, longitude: nil, durationText: nil,
        city: id == "a" ? "Paris" : (id == "b" ? "Lyon" : nil), country: "France", stackCount: nil,
        timeBucketKey: "2024-01-01", projectionType: nil, aspectRatio: ratio
      )
    }
    XCTAssertEqual(CuratedLibrary.keyItem(in: [item("a"), item("b", favorite: true)])?.id, "b")
    XCTAssertEqual(CuratedLibrary.keyItem(in: [item("a"), item("v", video: true, ratio: 1.8), item("c", ratio: 1.5)])?.id, "c")
    XCTAssertEqual(CuratedLibrary.placeSummary(for: [item("a"), item("a"), item("b")]), "Paris & Lyon")
    XCTAssertEqual(CuratedLibrary.placeSummary(for: [item("x")]), "France")
  }
}
