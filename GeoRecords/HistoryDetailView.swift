import SwiftUI
import CoreLocation
import MapKit

struct HistoryDetailView: View {
    let entry: RecordHistoryEntry
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.openURL) var openURL

    private var recordDetail: RecordDetail {
        RecordDetail(
            value: entry.value,
            timestamp: entry.timestamp ?? Date(),
            coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            altitude: entry.altitude,
            locationName: entry.locationName,
            recordType: entry.recordType ?? "Unknown"
        )
    }

    private var mapPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Photo if available
                if let photoData = entry.photoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 250)
                        .clipped()
                        .cornerRadius(10)
                        .padding(.bottom, 8)
                }

                // Map showing the record location
                Map(position: .constant(mapPosition)) {
                    Marker(entry.recordType ?? "Record", coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude))
                        .tint(.blue)
                }
                .frame(height: 250)
                .cornerRadius(10)
                .padding(.bottom, 8)

                Text("Record Type: \(entry.recordType ?? "Unknown")")
                    .font(.headline)
                Text("Value: \(recordDetail.formattedValue(unitSystem: settings.unitSystem))")
            
            if settings.unitSystem == .imperial {
                let altitudeFeet = entry.altitude * 3.28084
                Text("Altitude: \(String(format: "%.2f ft", altitudeFeet))")
            } else {
                Text("Altitude: \(String(format: "%.2f m", entry.altitude))")
            }
            
            if let timestamp = entry.timestamp {
                Text("Date: \(timestamp, formatter: detailDateFormatter)")
            }
            
            let lat = entry.latitude
            let lon = entry.longitude
            Button(action: {
                if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                    openURL(url)
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
                        if distanceMeters >= 1000 {
                            let km = distanceMeters / 1000.0
                            Text(String(format: "Distance from Home: %.2f km", km))
                        } else {
                            Text(String(format: "Distance from Home: %.0f m", distanceMeters))
                        }
                    }
                } else {
                    Text("Distance from Home: N/A")
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle(entry.recordType ?? "Detail")
    }
}
