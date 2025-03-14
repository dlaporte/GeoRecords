import SwiftUI
import CoreLocation

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @ObservedObject var settings = SettingsManager.shared
    
    /// Formats the entry's value based on its type.
    func formattedValue() -> String {
        let type = (entry.recordType ?? "unknown").lowercased()
        if type.contains("north") || type.contains("south") || type.contains("east") || type.contains("west") {
            return String(format: "%.2f°", entry.value)
        } else if type.contains("up") || type.contains("down") {
            if settings.unitSystem == .imperial {
                let altitudeFeet = entry.value * 3.28084
                return String(format: "%.0f ft", altitudeFeet)
            } else {
                return String(format: "%.2f m", entry.value)
            }
        } else if type.contains("from home") {
            if settings.unitSystem == .imperial {
                let miles = entry.value / 5280.0
                return String(format: "%.2f mi", miles)
            } else {
                let meters = entry.value / 3.28084
                if meters >= 1000 {
                    let km = meters / 1000.0
                    return String(format: "%.2f km", km)
                } else {
                    return String(format: "%.0f m", meters)
                }
            }
        } else {
            return String(format: "%.6f", entry.value)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Type: \(entry.recordType ?? "Unknown")")
                .font(.headline)
            Text("Value: \(formattedValue())")
            
            if settings.unitSystem == .imperial {
                let altitudeFeet = entry.altitude * 3.28084
                Text("Altitude: \(String(format: "%.2f ft", altitudeFeet))")
            } else {
                Text("Altitude: \(String(format: "%.2f m", entry.altitude))")
            }
            
            if let timestamp = entry.timestamp {
                Text("Date: \(timestamp, formatter: dateFormatter)")
            }
            
            let lat = entry.latitude
            let lon = entry.longitude
            Button(action: {
                if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)") {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Open in Maps (\(lat), \(lon))")
                    .foregroundColor(.blue)
            }
            
            if let locationName = entry.locationName {
                Text("Location: \(locationName)")
            }
            
            // New: Display Distance from Home
            if let homeCoord = settings.homeCoordinate {
                let recordLocation = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
                let homeLocation = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
                let distanceMeters = recordLocation.distance(from: homeLocation)
                if settings.unitSystem == .imperial {
                    let miles = distanceMeters / 1609.344
                    Text(String(format: "Distance from Home: %.2f mi", miles))
                } else {
                    Text(String(format: "Distance from Home: %.0f m", distanceMeters))
                }
            } else {
                Text("Distance from Home: N/A")
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle(entry.recordType ?? "Detail")
    }
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()
