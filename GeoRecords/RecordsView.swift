import SwiftUI

struct RecordsView: View {
    @ObservedObject var recordManager = RecordManager.shared
    @ObservedObject var settings = SettingsManager.shared
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    RecordCard(
                        title: "Furthest North",
                        record: recordManager.furthestNorth,
                        settings: settings,
                        formatValue: { value in
                            // Format as degrees with a degree symbol.
                            return String(format: "%.2f°", value)
                        }
                    )
                    RecordCard(
                        title: "Furthest South",
                        record: recordManager.furthestSouth,
                        settings: settings,
                        formatValue: { value in
                            return String(format: "%.2f°", value)
                        }
                    )
                    RecordCard(
                        title: "Furthest East",
                        record: recordManager.furthestEast,
                        settings: settings,
                        formatValue: { value in
                            return String(format: "%.2f°", value)
                        }
                    )
                    RecordCard(
                        title: "Furthest West",
                        record: recordManager.furthestWest,
                        settings: settings,
                        formatValue: { value in
                            return String(format: "%.2f°", value)
                        }
                    )
                    RecordCard(
                        title: "Furthest Up",
                        record: recordManager.furthestUp,
                        settings: settings,
                        formatValue: { value in
                            let converted = (settings.unitSystem == .imperial) ? value * 3.28084 : value
                            return "\(Int(round(converted))) \(settings.unitSystem == .imperial ? "ft" : "m")"
                        }
                    )
                    RecordCard(
                        title: "Furthest Down",
                        record: recordManager.furthestDown,
                        settings: settings,
                        formatValue: { value in
                            let converted = (settings.unitSystem == .imperial) ? value * 3.28084 : value
                            return "\(Int(round(converted))) \(settings.unitSystem == .imperial ? "ft" : "m")"
                        }
                    )
                    RecordCard(
                        title: "Furthest from Home",
                        record: recordManager.furthestFromHome,
                        settings: settings,
                        formatValue: { value in
                            if settings.unitSystem == .imperial {
                                let miles = value / 5280.0
                                return String(format: "%.2f mi", miles)
                            } else {
                                // Convert value from feet to meters.
                                let meters = value / 3.28084
                                if meters >= 1000 {
                                    let km = meters / 1000.0
                                    return String(format: "%.2f km", km)
                                } else {
                                    return "\(Int(round(meters))) m"
                                }
                            }
                        }
                    )
                }
                .padding()
            }
            .navigationTitle("Records")
        }
    }
}

struct RecordCard: View {
    let title: String
    let record: RecordDetail?
    let settings: SettingsManager
    /// A closure that returns a formatted string for a given numeric value.
    let formatValue: (Double) -> String
    
    var body: some View {
        Group {
            if let record = record {
                NavigationLink(destination: RecordDetailView(record: record)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)
                        
                        Text(formatValue(record.value))
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        Text("\(record.timestamp, formatter: recordDateFormatter)")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(UIColor.systemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text("No record yet")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(UIColor.systemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
    }
}

private let recordDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
