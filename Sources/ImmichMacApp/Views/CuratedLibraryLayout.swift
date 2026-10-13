import CoreGraphics
import Foundation

/// Layout rules for Photos' Years / Months / Days library zoom levels on the Mac, recovered from
/// PhotosUICore (`PXCuratedLibraryLayoutSpec`, `PXYear/MonthCardSectionBodyLayoutSpec`,
/// `PXYearsLayoutGenerator`, `PXMonthsLayoutGenerator`, `PXCuratedLibrarySettings`).
/// See docs/photos-reverse-engineering.md, "Part 5 — Library zoom levels".
enum CuratedLibrary {
  // MARK: Decoded metrics (Mac, regular size class)

  /// `PXCuratedLibraryCardSectionBodyLayoutSpec` horizontal insets on the Mac idiom.
  static let cardHorizontalInset: CGFloat = 52
  /// `spacingBetweenYearCards` (regular).
  static let yearCardSpacing: CGFloat = 36
  /// `spacingBetweenMonthCards` (regular).
  static let monthCardSpacing: CGFloat = 24
  /// `cornerRadiusForYears` / `cornerRadiusForMonths`.
  static let cardCornerRadius: CGFloat = 10
  /// `aspectRatioForRegularYears` (single column) and `multiColumnAspectRatio` (several columns).
  static let singleColumnYearAspect: CGFloat = 1.5
  static let multiColumnYearAspect: CGFloat = 1.0
  /// Single-column year cards are narrowed so their height stays within 80 % of the view.
  static let singleColumnMaxHeightFraction: CGFloat = 0.8
  /// `yearsHeaderGradientHeight` / `monthsHeaderGradientHeight`.
  static let headerGradientHeight: CGFloat = 120
  /// Days: `interitemSpacingForDays`, `spacingBetweenDays`, `cornerRadiusForDays`, `lateralMarginDays`.
  static let daysInteritemSpacing: CGFloat = 2
  static let spacingBetweenDays: CGFloat = 5
  static let daysCornerRadius: CGFloat = 0
  /// Month cards: hero cards use a 1.5 aspect, regular cards 1.0 (`PXMonthsLayoutGenerator`).
  static let heroMonthAspect: CGFloat = 1.5

  // MARK: Years

  /// `-[PXYearsLayoutGenerator updateContentSize:…]` with `useWideModularLayoutInYears = NO`:
  /// landscape windows use 3 columns from 9 years, 2 columns from 4 years, else one big card;
  /// portrait windows use 2 columns above 5 years.
  static func yearColumns(yearCount: Int, isLandscape: Bool) -> Int {
    if isLandscape {
      if yearCount >= 9 { return 3 }
      return yearCount > 3 ? 2 : 1
    }
    return yearCount > 5 ? 2 : 1
  }

  static func yearCardSize(container: CGSize, columns: Int) -> CGSize {
    let available = max(container.width - cardHorizontalInset * 2, 1)
    guard columns > 1 else {
      let width = min(available, container.height * singleColumnMaxHeightFraction * singleColumnYearAspect)
      return CGSize(width: max(width, 1), height: max(width, 1) / singleColumnYearAspect)
    }
    let width = (available + yearCardSpacing) / CGFloat(columns) - yearCardSpacing
    return CGSize(width: max(width, 1), height: max(width, 1) / multiColumnYearAspect)
  }

  // MARK: Months

  struct MonthRow: Equatable, Identifiable {
    enum Kind: Equatable {
      /// One large 2/3-width hero card and two stacked 1/3-width cards.
      case heroLeading
      case heroTrailing
      /// Two equal cards.
      case pair
      /// One full-width card.
      case single
    }

    let kind: Kind
    /// Section IDs in reading order (hero first for `.heroLeading`, last for `.heroTrailing`).
    let sectionIDs: [String]

    var id: String { sectionIDs.joined(separator: "|") }
  }

  /// Photos promotes busier months to hero cards in a modular layout. Its weights come from
  /// curation scores; this clone uses photo counts. Chronological order is always preserved.
  static func monthRows(sections: [(id: String, weight: Int)]) -> [MonthRow] {
    var rows: [MonthRow] = []
    var index = 0
    while index < sections.count {
      let remaining = sections.count - index
      if remaining >= 3 {
        let triple = Array(sections[index..<(index + 3)])
        let heaviest = triple.map(\.weight).max() ?? 0
        let others = triple.map(\.weight).sorted(by: >)
        // Promote only a month clearly busier than the rest of its row.
        let promotes = heaviest > 0 && Double(heaviest) >= Double(others[1]) * 1.5
        if promotes, triple[0].weight == heaviest {
          rows.append(MonthRow(kind: .heroLeading, sectionIDs: triple.map(\.id)))
          index += 3
          continue
        }
        if promotes, triple[2].weight == heaviest {
          rows.append(MonthRow(kind: .heroTrailing, sectionIDs: triple.map(\.id)))
          index += 3
          continue
        }
      }
      if remaining >= 2 {
        rows.append(MonthRow(kind: .pair, sectionIDs: [sections[index].id, sections[index + 1].id]))
        index += 2
      } else {
        rows.append(MonthRow(kind: .single, sectionIDs: [sections[index].id]))
        index += 1
      }
    }
    return rows
  }

  /// Row height for a months row at a given content width (insets already removed).
  static func monthRowHeight(kind: MonthRow.Kind, width: CGFloat) -> CGFloat {
    let spacing = monthCardSpacing
    switch kind {
    case .heroLeading, .heroTrailing:
      return ((width - spacing) * 2 / 3) / heroMonthAspect
    case .pair:
      return ((width - spacing) / 2) / heroMonthAspect
    case .single:
      return width / 2
    }
  }

  // MARK: Key photos and titles

  /// Stand-in for Photos' curated key asset: a favorite still if there is one, otherwise the
  /// landscape still closest to the middle of the period, otherwise the newest item.
  static func keyItem(in items: [AppState.PhotoItem]) -> AppState.PhotoItem? {
    let stills = items.filter { !$0.isVideo }
    if let favorite = stills.first(where: \.isFavorite) {
      return favorite
    }
    let landscape = stills.filter { $0.aspectRatio >= 1.2 }
    if !landscape.isEmpty {
      return landscape[landscape.count / 2]
    }
    if !stills.isEmpty {
      return stills[stills.count / 2]
    }
    return items.first
  }

  /// Up to two of the most common place names, like Photos' card titles ("San Francisco & Oakland").
  static func placeSummary(for items: [AppState.PhotoItem]) -> String? {
    var counts: [String: Int] = [:]
    for item in items {
      if let place = (item.city ?? item.country)?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
        counts[place, default: 0] += 1
      }
    }
    let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    switch ranked.count {
    case 0: return nil
    case 1: return ranked[0]
    case 2: return "\(ranked[0]) & \(ranked[1])"
    default: return "\(ranked[0]), \(ranked[1]) & More"
    }
  }

  /// "Oct 3 – 28" style range for a month or day group.
  static func dateRange(for items: [AppState.PhotoItem], calendar: Calendar = .current) -> String {
    guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return "" }
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.dateTemplate = "MMMd"
    if calendar.isDate(first, inSameDayAs: last) {
      return first.formatted(.dateTime.month(.abbreviated).day())
    }
    return formatter.string(from: first, to: last)
  }
}
