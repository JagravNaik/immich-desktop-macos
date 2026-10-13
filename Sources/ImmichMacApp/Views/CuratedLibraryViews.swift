#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

// MARK: - Card

/// A Years/Months card: a full-bleed key photo with 10 pt corners, a top gradient, and the
/// title/subtitle drawn over it. Moving the pointer across the card skims through photos from the
/// period (`PXCuratedLibrarySkimmingController`); leaving the card returns to the key photo.
struct CuratedLibraryCard: View {
  let items: [AppState.PhotoItem]
  let keyItem: AppState.PhotoItem
  let title: String
  let subtitle: String?
  let titleFont: Font
  let context: AppState.ThumbnailContext?
  let store: ThumbnailStore
  let action: () -> Void

  @State private var skimIndex: Int?
  @State private var isHovered = false

  private static let maximumSkimItems = 12

  private var skimItems: [AppState.PhotoItem] {
    let stills = items.filter { !$0.isVideo }
    guard stills.count > 1 else { return [] }
    let count = min(stills.count, Self.maximumSkimItems)
    return (0..<count).map { stills[$0 * (stills.count - 1) / max(count - 1, 1)] }
  }

  private var displayedItem: AppState.PhotoItem {
    if let skimIndex, skimItems.indices.contains(skimIndex) {
      return skimItems[skimIndex]
    }
    return keyItem
  }

  var body: some View {
    Button(action: action) {
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          AssetThumbnailView(item: displayedItem, context: context, store: store)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()

          LinearGradient(
            colors: [.black.opacity(0.5), .black.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: min(CuratedLibrary.headerGradientHeight, geometry.size.height))
          .allowsHitTesting(false)

          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(titleFont)
              .lineLimit(1)
            if let subtitle {
              Text(subtitle)
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.85)
                .lineLimit(1)
            }
          }
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
          .padding(.horizontal, 16)
          .padding(.top, 14)

          if skimIndex != nil, skimItems.count > 1 {
            skimIndicator
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
              .padding(10)
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            let fraction = min(max(location.x / max(geometry.size.width, 1), 0), 0.9999)
            skimIndex = skimItems.isEmpty ? nil : Int(fraction * CGFloat(skimItems.count))
          case .ended:
            skimIndex = nil
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: CuratedLibrary.cardCornerRadius, style: .continuous))
      .scaleEffect(isHovered ? 1.005 : 1)
      .animation(ImmichMotion.Curves.photosStandard, value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(.isButton)
  }

  /// Photos' skimming hint: a thin bar showing the position within the period.
  private var skimIndicator: some View {
    GeometryReader { bar in
      let count = max(skimItems.count, 1)
      let width = bar.size.width / CGFloat(count)
      Capsule()
        .fill(.white.opacity(0.9))
        .frame(width: max(width, 6), height: 3)
        .offset(x: CGFloat(skimIndex ?? 0) * width)
    }
    .frame(height: 3)
    .background(Capsule().fill(.white.opacity(0.3)))
  }
}

// MARK: - Years

struct CuratedYearsView: View {
  let sections: [AppState.LibrarySection]
  let context: AppState.ThumbnailContext?
  let store: ThumbnailStore
  let onSelectYear: (AppState.LibrarySection) -> Void

  var body: some View {
    GeometryReader { geometry in
      let isLandscape = geometry.size.width >= geometry.size.height
      let columns = CuratedLibrary.yearColumns(yearCount: sections.count, isLandscape: isLandscape)
      let cardSize = CuratedLibrary.yearCardSize(container: geometry.size, columns: columns)
      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(cardSize.width), spacing: CuratedLibrary.yearCardSpacing), count: columns),
          spacing: CuratedLibrary.yearCardSpacing
        ) {
          ForEach(sections) { section in
            if let key = CuratedLibrary.keyItem(in: section.items) {
              CuratedLibraryCard(
                items: section.items,
                keyItem: key,
                title: section.title,
                subtitle: nil,
                titleFont: .system(size: 34, weight: .bold),
                context: context,
                store: store,
                action: { onSelectYear(section) }
              )
              .frame(width: cardSize.width, height: cardSize.height)
              .id(section.id)
            }
          }
        }
        .padding(.horizontal, CuratedLibrary.cardHorizontalInset)
        .padding(.top, 16)
        .padding(.bottom, CuratedLibrary.yearCardSpacing)
        .frame(maxWidth: .infinity)
      }
    }
  }
}

// MARK: - Months

struct CuratedMonthsView: View {
  let sections: [AppState.LibrarySection]
  let context: AppState.ThumbnailContext?
  let store: ThumbnailStore
  let onSelectMonth: (AppState.LibrarySection) -> Void
  var onSectionAppear: (AppState.LibrarySection) -> Void = { _ in }

  private struct YearGroup: Identifiable {
    let year: String
    let months: [AppState.LibrarySection]
    var id: String { "year-\(year)" }
  }

  private var yearGroups: [YearGroup] {
    var groups: [YearGroup] = []
    for section in sections {
      let year = String(section.id.prefix(4))
      if groups.last?.year == year {
        groups[groups.count - 1] = YearGroup(year: year, months: groups[groups.count - 1].months + [section])
      } else {
        groups.append(YearGroup(year: year, months: [section]))
      }
    }
    return groups
  }

  var body: some View {
    GeometryReader { geometry in
      let contentWidth = max(geometry.size.width - CuratedLibrary.cardHorizontalInset * 2, 1)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: CuratedLibrary.monthCardSpacing, pinnedViews: [.sectionHeaders]) {
          ForEach(yearGroups) { group in
            Section {
              let byID = Dictionary(uniqueKeysWithValues: group.months.map { ($0.id, $0) })
              ForEach(CuratedLibrary.monthRows(sections: group.months.map { ($0.id, $0.itemCount) })) { row in
                monthRow(row, sections: byID, width: contentWidth)
                  .padding(.horizontal, CuratedLibrary.cardHorizontalInset)
              }
            } header: {
              chapterHeader(group.year)
                .id(group.id)
            }
          }
        }
        .padding(.bottom, CuratedLibrary.monthCardSpacing)
      }
    }
  }

  /// Photos' floating year chapter header (`PXCuratedLibraryChapterHeaderLayoutSpec`).
  private func chapterHeader(_ year: String) -> some View {
    Text(year)
      .font(.system(size: 28, weight: .bold))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, CuratedLibrary.cardHorizontalInset)
      .padding(.top, 12)
      .padding(.bottom, 8)
      .background(.bar)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func monthRow(_ row: CuratedLibrary.MonthRow, sections: [String: AppState.LibrarySection], width: CGFloat) -> some View {
    let spacing = CuratedLibrary.monthCardSpacing
    let height = CuratedLibrary.monthRowHeight(kind: row.kind, width: width)
    let cards = row.sectionIDs.compactMap { sections[$0] }
    switch row.kind {
    case .heroLeading, .heroTrailing:
      let hero = row.kind == .heroLeading ? cards.first : cards.last
      let small = row.kind == .heroLeading ? Array(cards.dropFirst()) : Array(cards.dropLast())
      let heroWidth = (width - spacing) * 2 / 3
      let smallWidth = width - spacing - heroWidth
      HStack(spacing: spacing) {
        if row.kind == .heroTrailing { stack(small, width: smallWidth, height: height) }
        if let hero { monthCard(hero, isHero: true).frame(width: heroWidth, height: height) }
        if row.kind == .heroLeading { stack(small, width: smallWidth, height: height) }
      }
    case .pair:
      HStack(spacing: spacing) {
        ForEach(cards) { monthCard($0, isHero: false).frame(width: (width - spacing) / 2, height: height) }
      }
    case .single:
      if let card = cards.first {
        monthCard(card, isHero: true).frame(width: width, height: height)
      }
    }
  }

  private func stack(_ cards: [AppState.LibrarySection], width: CGFloat, height: CGFloat) -> some View {
    let spacing = CuratedLibrary.monthCardSpacing
    return VStack(spacing: spacing) {
      ForEach(cards) { monthCard($0, isHero: false).frame(width: width, height: (height - spacing) / 2) }
    }
  }

  @ViewBuilder
  private func monthCard(_ section: AppState.LibrarySection, isHero: Bool) -> some View {
    if let key = CuratedLibrary.keyItem(in: section.items) {
      let monthName = section.title.split(separator: " ").first.map(String.init) ?? section.title
      let place = CuratedLibrary.placeSummary(for: section.items)
      CuratedLibraryCard(
        items: section.items,
        keyItem: key,
        title: place ?? monthName,
        subtitle: place == nil ? "\(section.itemCount.formatted()) \(section.itemCount == 1 ? "Item" : "Items")" : CuratedLibrary.dateRange(for: section.items),
        titleFont: .system(size: isHero ? 24 : 18, weight: .bold),
        context: context,
        store: store,
        action: { onSelectMonth(section) }
      )
      .id(section.id)
      .onAppear { onSectionAppear(section) }
    }
  }
}
#endif
