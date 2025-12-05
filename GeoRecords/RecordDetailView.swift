import SwiftUI
import CoreLocation
import MapKit

struct RecordDetailView: View {
    let record: RecordDetail
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var recordManager: RecordManager
    @Environment(\.openURL) var openURL
    @Environment(\.dismiss) var dismiss

    @State private var showDeleteAlert = false

    private var mapPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: record.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Show photo if available, otherwise show map
                if let photoData = record.photoData,
                   let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 250)
                        .clipped()
                        .cornerRadius(10)
                        .padding(.bottom, 8)
                } else {
                    // Map showing the record location (only if no photo)
                    Map(position: .constant(mapPosition)) {
                        Marker(record.recordType, coordinate: record.coordinate)
                            .tint(.blue)
                    }
                    .frame(height: 250)
                    .cornerRadius(10)
                    .padding(.bottom, 8)
                }

                Text("Record Type: \(record.recordType)")
                    .font(.headline)
                Text("Value: \(record.formattedValue(unitSystem: settings.unitSystem))")

                if settings.unitSystem == .imperial {
                    let altitudeFeet = record.altitude * 3.28084
                    Text("Altitude: \(String(format: "%.2f ft", altitudeFeet))")
                } else {
                    Text("Altitude: \(String(format: "%.2f m", record.altitude))")
                }

                Text("Date: \(record.timestamp, formatter: detailDateFormatter)")

                let lat = record.coordinate.latitude
                let lon = record.coordinate.longitude
                Button(action: {
                    if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                        openURL(url)
                    }
                }) {
                    Text("Open in Maps (\(lat), \(lon))")
                        .foregroundColor(.blue)
                }

                if let locationName = record.locationName {
                    Text("Location: \(locationName)")
                }

                // Display Distance from Home
                if let homeCoord = settings.homeCoordinate {
                    let recordLocation = CLLocation(latitude: record.coordinate.latitude, longitude: record.coordinate.longitude)
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
        .navigationTitle(record.recordType)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete Record?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteRecord()
            }
        } message: {
            Text("Are you sure you want to delete this \(record.recordType) record? This action cannot be undone.")
        }
    }

    private func deleteRecord() {
        // Delete from Core Data history
        RecordHistoryManager.shared.deleteRecord(recordId: record.id)

        // Clear from RecordManager in-memory using the helper method
        recordManager.setRecord(type: record.recordType, timeFrame: record.timeFrame, record: nil)

        // Reload records from history to get the next best record
        recordManager.loadRecordsFromHistory()

        dismiss()
    }
}
