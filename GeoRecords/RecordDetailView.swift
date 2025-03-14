import SwiftUI
import CoreLocation

struct RecordDetailView: View {
    let record: RecordDetail
    @ObservedObject var settings = SettingsManager.shared
    
    /// Formats the record's main value based on its type.
    func formattedValue() -> String {
        let type = record.recordType.lowercased()
        if type.contains("north") || type.contains("south") || type.contains("east") || type.contains("west") {
            // Cardinal directions: show degrees.
            return String(format: "%.2f°", record.value)
        } else if type.contains("up") || type.contains("down") {
            // Altitude: if Imperial, convert to feet; otherwise, use meters.
            if settings.unitSystem == .imperial {
                let altitudeFeet = record.value * 3.28084
                return String(format: "%.0f ft", altitudeFeet)
            } else {
                return String(format: "%.2f m", record.value)
            }
        } else if type.contains("from home") {
            // Furthest from Home: canonical data is in feet.
            if settings.unitSystem == .imperial {
                let miles = record.value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = record.value / 3.28084
                if meters >= 1000 {
                    let km = meters / 1000.0
                    return String(format: "%.2f km", km)
                } else {
                    return String(format: "%.0f m", meters)
                }
            }
        } else {
            return String(format: "%.6f", record.value)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Type: \(record.recordType)")
                .font(.headline)
            Text("Value: \(formattedValue())")
            
            if settings.unitSystem == .imperial {
                let altitudeFeet = record.altitude * 3.28084
                Text("Altitude: \(String(format: "%.2f ft", altitudeFeet))")
            } else {
                Text("Altitude: \(String(format: "%.2f m", record.altitude))")
            }
            
            Text("Timestamp: \(record.timestamp, formatter: dateFormatter)")
            
            Button(action: {
                let lat = record.coordinate.latitude
                let lon = record.coordinate.longitude
                if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)") {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Open in Maps (\(record.coordinate.latitude), \(record.coordinate.longitude))")
                    .foregroundColor(.blue)
            }
            
            if let locationName = record.locationName {
                Text("Location: \(locationName)")
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle(record.recordType)
    }
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()
