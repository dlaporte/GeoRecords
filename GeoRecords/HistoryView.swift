import SwiftUI
import CoreData

struct HistoryView: View {
    // Fetch history entries sorted by timestamp (newest first)
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RecordHistoryEntry.timestamp, ascending: false)],
        animation: .default
    )
    private var historyEntries: FetchedResults<RecordHistoryEntry>
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if historyEntries.isEmpty {
                        Text("No history available")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(historyEntries) { entry in
                            NavigationLink(destination: HistoryDetailView(entry: entry)) {
                                HistoryCard(entry: entry)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("History")
        }
    }
}

struct HistoryCard: View {
    let entry: RecordHistoryEntry
    
    /// Formats the record's value based on its type.
    private func formattedValue() -> String {
        let type = entry.recordType ?? "Unknown"
        
        if type.contains("North") ||
           type.contains("South") ||
           type.contains("East") ||
           type.contains("West") {
            return String(format: "%.2f°", entry.value)
        } else if type.contains("Up") || type.contains("Down") {
            let converted = (SettingsManager.shared.unitSystem == .imperial) ? entry.value * 3.28084 : entry.value
            return "\(Int(round(converted))) \(SettingsManager.shared.unitSystem == .imperial ? "ft" : "m")"
        } else if type == "Furthest from Home" {
            if SettingsManager.shared.unitSystem == .imperial {
                let miles = entry.value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = entry.value / 3.28084
                if meters >= 1000 {
                    let km = meters / 1000.0
                    return String(format: "%.2f km", km)
                } else {
                    return "\(Int(round(meters))) m"
                }
            }
        } else {
            return String(format: "%.6f", entry.value)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.recordType ?? "Unknown")
                .font(.headline)
            Text(formattedValue())
                .font(.body)
                .foregroundColor(.secondary)
            Text("\(entry.timestamp!, formatter: historyDateFormatter)")
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

private let historyDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
