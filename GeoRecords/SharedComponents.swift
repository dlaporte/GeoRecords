//
//  SharedComponents.swift
//  GeoRecords
//
//  Shared UI components and helpers used across multiple views
//

import SwiftUI
import Photos
import CoreLocation

// MARK: - Card Sizing

/// Encapsulates responsive sizing values for record cards
/// Used by both RecordsView and MapsTabView for consistent card layouts.
/// Compact when the vertical size class is compact (any phone in landscape,
/// iPhone Duo folded in landscape); read it from `@Environment(\.cardSizing)`
struct CardSizing {
    let isCompact: Bool

    init(vertical: UserInterfaceSizeClass?) {
        isCompact = vertical == .compact
    }

    var cardSpacing: CGFloat { isCompact ? 8 : 12 }
    var iconSize: CGFloat { isCompact ? 32 : 44 }
    var valueFontSize: CGFloat { isCompact ? 24 : 36 }
    var photoSize: CGFloat { isCompact ? 80 : 120 }
    var cardPadding: CGFloat { isCompact ? 12 : 16 }
    /// The same 16 pt the picker, map and detail rows keep from the edge
    var horizontalPadding: CGFloat { 16 }
    var contentSpacing: CGFloat { isCompact ? 6 : 12 }
}

// MARK: - Record Photo Thumbnail

/// Displays a photo thumbnail for a record, with multiple fallback loading strategies
/// Used by both RecordsView and MapsTabView
// MARK: - Capsule pill

/// The capsule the Regions tab's "Not yet" button wears, shared by the History
/// filter chips and the filter panel's pills: caption text in a tertiary fill,
/// white on the accent colour when on
extension View {
    func capsulePill(on: Bool, roomy: Bool = false) -> some View {
        self
            .font(roomy ? .subheadline : .caption)
            .fontWeight(.medium)
            .foregroundColor(on ? .white : .secondary)
            .padding(.horizontal, roomy ? 12 : 8)
            .padding(.vertical, roomy ? 7 : 4)
            .background(Capsule().fill(on ? Color.accentColor : Color(UIColor.tertiarySystemFill)))
    }
}

struct RecordPhotoThumbnail: View {
    let recordId: UUID
    let photoAssetIdentifier: String?
    let photoCloudIdentifier: String?
    let photoData: Data?  // Legacy fallback
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let sizing: CardSizing

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .clipShape(RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12))
            } else {
                RoundedRectangle(cornerRadius: sizing.isCompact ? 8 : 12)
                    .fill(Color(UIColor.tertiarySystemGroupedBackground))
                    .frame(width: sizing.photoSize, height: sizing.photoSize)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.7)
                    )
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    /// The photo source the cached thumbnail must have been rendered from to be valid
    private var expectedThumbnailSource: String? {
        if let photoAssetIdentifier = photoAssetIdentifier { return photoAssetIdentifier }
        if photoData != nil { return ThumbnailCache.embeddedPhotoSource }
        return nil
    }

    private func loadThumbnail() async {
        let cache = ThumbnailCache.shared

        // Exact provenance match: the cached thumbnail was rendered from the record's
        // CURRENT photo — trust it. (Fallback-matched thumbnails must not stick forever;
        // that made cards show a different photo than the detail view.)
        if let cached = cache.loadValidatedThumbnail(for: recordId, expectedSource: expectedThumbnailSource) {
            loadedImage = cached
            return
        }

        // Provenance mismatch or missing (pre-update caches, fallback-matched assets):
        // show the stale thumbnail immediately — never blank a previously-working card —
        // then re-resolve at most once per session below.
        if let stale = cache.loadThumbnail(for: recordId) {
            loadedImage = stale
        }

        guard cache.shouldRevalidate(recordId) else { return }

        // Resolve via Photos: local ID → cloud ID → timestamp/location
        if let identifier = photoAssetIdentifier {
            if let result = await PhotoReferenceManager.shared.fetchThumbnailWithSource(
                identifier: identifier,
                cloudIdentifier: photoCloudIdentifier,
                timestamp: timestamp,
                coordinate: coordinate
            ) {
                loadedImage = result.image
                // Re-cache with provenance: pre-update caches heal to exact-match here;
                // fallback matches self-heal once the record's real asset is available
                cache.saveThumbnail(from: result.image, for: recordId, source: result.sourceIdentifier)
                return
            }
        }

        // Fallback to legacy embedded photo data
        if loadedImage == nil, let data = photoData, let image = UIImage(data: data) {
            loadedImage = image
            cache.saveThumbnail(from: image, for: recordId, source: ThumbnailCache.embeddedPhotoSource)
        }
        // Resolution failed: whatever stale thumbnail we showed above stays visible
    }
}

// MARK: - Record Card Header

/// Standard header component for record cards showing icon, type, and date
/// Used by RecordsView and potentially other card-based views
struct RecordCardHeader: View {
    let recordType: String
    let timestamp: Date
    let sizing: CardSizing

    var body: some View {
        HStack(spacing: sizing.isCompact ? 8 : 12) {
            Image(systemName: FormatUtils.iconForRecordType(recordType))
                .font(sizing.isCompact ? .title3 : .title)
                .foregroundColor(FormatUtils.colorForRecordType(recordType))
                .frame(width: sizing.iconSize, height: sizing.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(recordType)
                    .font(sizing.isCompact ? .caption : .headline)
                    .fontWeight(.semibold)
                Text(mediumDateFormatter.string(from: timestamp))
                    .font(sizing.isCompact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Empty Region State View

/// Generic empty state view for region tabs
/// Used by MapsTabView to show when no regions have been visited
struct EmptyRegionStateView: View {
    let regionPluralName: String
    let iconName: String

    /// Initialize with a RegionType
    init(regionType: RegionType) {
        self.regionPluralName = regionType.pluralName
        self.iconName = regionType == .state ? "map" : "globe"
    }

    /// Initialize for continents (which don't use RegionType enum)
    init(forContinents: Bool) {
        self.regionPluralName = "continents"
        self.iconName = "globe"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No \(regionPluralName.lowercased()) visited yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Visit new places to see them here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - TimeFrame Picker

/// A specific past month selectable in the timeframe picker
struct MonthSelection: Hashable {
    let year: Int
    let month: Int

    var startDate: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// e.g. "Jul 2026"
    var displayName: String {
        guard let date = startDate else { return "\(year)-\(month)" }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// The month containing the given date
    static func containing(_ date: Date) -> MonthSelection? {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        return MonthSelection(year: year, month: month)
    }
}

/// The stats period a summary notification promises to show.
/// Precise notifications embed the concrete year/month at scheduling time; the
/// repeating fallback notifications can only say "previousMonth"/"previousYear",
/// which resolve relative to when the user taps.
enum StatsDeepLinkPeriod: Equatable {
    case month(MonthSelection)
    case year(Int)

    static func resolve(period: String?, year: Int?, month: Int?, now: Date = Date()) -> StatsDeepLinkPeriod? {
        if let month {
            guard (1...12).contains(month), let year else { return nil }
            return .month(MonthSelection(year: year, month: month))
        }
        if let year {
            return .year(year)
        }

        let calendar = Calendar.current
        switch period {
        case "previousMonth":
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return MonthSelection.containing(previous).map { .month($0) }
        case "previousYear":
            return .year(calendar.component(.year, from: now) - 1)
        default:
            return nil
        }
    }
}

/// Cutoff for keeping daily stat rows: the start of the PREVIOUS month.
/// The monthly summary notification on the 1st links to the month that just
/// ended, so that month's day-by-day data must survive its cleanup.
func dailyStatsRetentionCutoff(for date: Date = Date()) -> Date? {
    let calendar = Calendar.current
    guard let monthStart = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
    return calendar.date(byAdding: .month, value: -1, to: monthStart)
}

/// Segmented timeframe picker shared by RecordsView and StatisticsView.
/// The selected Year/Month segment becomes a visible pulldown for browsing
/// history (the old long-press context menu was nearly undiscoverable).
/// First tap selects the timeframe; tapping the selected segment opens the menu.
/// Pages without month history pass an empty `availableMonths`; pages without
/// new-record badges omit `badgeCount`.
/// `badgeCount` is evaluated during body; the caller must observe whatever
/// object it reads so the picker re-renders when counts change.
struct TimeFramePickerWithBadges: View {
    @Binding var selectedTimeFrame: TimeFrame
    @Binding var selectedYear: Int?
    @Binding var selectedMonth: MonthSelection?
    let availableYears: [Int]
    let availableMonths: [MonthSelection]
    let timeFrameLabel: (TimeFrame) -> String
    var yearString: (Int) -> String = { String(format: "%d", $0) }
    var badgeCount: (TimeFrame) -> Int = { _ in 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach([TimeFrame.allTime, .year, .month], id: \.self) { timeFrame in
                if selectedTimeFrame == timeFrame && hasHistoryMenu(for: timeFrame) {
                    Menu {
                        historyMenu(for: timeFrame)
                    } label: {
                        TimeFrameSegmentLabel(
                            isSelected: true,
                            label: timeFrameLabel(timeFrame),
                            badgeCount: badgeCount(timeFrame),
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    TimeFrameSegment(
                        isSelected: selectedTimeFrame == timeFrame,
                        label: timeFrameLabel(timeFrame),
                        badgeCount: badgeCount(timeFrame)
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTimeFrame = timeFrame
                        }
                    }
                }
            }
        }
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
    }

    /// The menu already leads with "This Year", so the history list holds only past years
    static func pastYears(_ years: [Int], now: Date = Date()) -> [Int] {
        let currentYear = Calendar.current.component(.year, from: now)
        return years.filter { $0 != currentYear }
    }

    /// The menu already leads with "This Month", so the history list holds only past months
    static func pastMonths(_ months: [MonthSelection], now: Date = Date()) -> [MonthSelection] {
        let current = MonthSelection.containing(now)
        return months.filter { $0 != current }
    }

    private var pastYears: [Int] { Self.pastYears(availableYears) }
    private var pastMonths: [MonthSelection] { Self.pastMonths(availableMonths) }

    private func hasHistoryMenu(for timeFrame: TimeFrame) -> Bool {
        switch timeFrame {
        case .year: return !pastYears.isEmpty
        case .month: return !pastMonths.isEmpty
        default: return false
        }
    }

    @ViewBuilder
    private func historyMenu(for timeFrame: TimeFrame) -> some View {
        switch timeFrame {
        case .year:
            Button {
                selectedYear = nil
            } label: {
                Label("This Year", systemImage: selectedYear == nil ? "checkmark" : "calendar")
            }
            Divider()
            ForEach(pastYears, id: \.self) { year in
                Button {
                    selectedYear = year
                } label: {
                    Label(yearString(year), systemImage: selectedYear == year ? "checkmark" : "calendar")
                }
            }
        case .month:
            Button {
                selectedMonth = nil
            } label: {
                Label("This Month", systemImage: selectedMonth == nil ? "checkmark" : "calendar")
            }
            Divider()
            ForEach(pastMonths, id: \.self) { month in
                Button {
                    selectedMonth = month
                } label: {
                    Label(month.displayName, systemImage: selectedMonth == month ? "checkmark" : "calendar")
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Shared segment content used by both plain segments and the pulldown segment
private struct TimeFrameSegmentLabel: View {
    let isSelected: Bool
    let label: String
    let badgeCount: Int
    var showsChevron: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color(UIColor.systemBackground) : Color.clear
            )
            .cornerRadius(6)
            .padding(2)

            // Badge indicator
            if badgeCount > 0 {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: -4, y: 4)
            }
        }
    }
}

private struct TimeFrameSegment: View {
    let isSelected: Bool
    let label: String
    let badgeCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimeFrameSegmentLabel(isSelected: isSelected, label: label, badgeCount: badgeCount)
        }
        .buttonStyle(.plain)
    }
}
