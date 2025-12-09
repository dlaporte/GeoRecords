import SwiftUI
import CoreLocation
import MapKit

/// Shared content view for displaying record details
/// Used by both RecordDetailView and HistoryDetailView to eliminate duplication
struct DetailContentView: View {
    let record: RecordDetail
    let onSaveNotes: (String?) -> Void

    @EnvironmentObject var settings: SettingsManager
    @Environment(\.openURL) var openURL

    @State private var isEditingNotes = false
    @State private var notesText: String = ""

    private var mapPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: record.coordinate,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
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
                    let altitudeFeet = record.altitude * metersToFeet
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

                // Notes Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Notes")
                            .font(.headline)
                        Spacer()
                        if !isEditingNotes {
                            Button(record.notes == nil ? "Add Notes" : "Edit") {
                                isEditingNotes = true
                            }
                            .font(.caption)
                        }
                    }

                    if isEditingNotes {
                        TextEditor(text: $notesText)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)

                        HStack {
                            Button("Cancel") {
                                notesText = record.notes ?? ""
                                isEditingNotes = false
                            }
                            .foregroundColor(.secondary)

                            Spacer()

                            Button("Save") {
                                saveNotes()
                            }
                            .fontWeight(.semibold)
                        }
                    } else {
                        if let notes = record.notes, !notes.isEmpty {
                            Text(notes)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        } else {
                            Text("No notes added")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 4)

                // Display Distance from Home
                if let distanceText = FormatUtils.formatDistanceFromHome(
                    from: record.coordinate,
                    to: settings.homeCoordinate,
                    unitSystem: settings.unitSystem
                ) {
                    Text("Distance from Home: \(distanceText)")
                } else {
                    Text("Distance from Home: N/A")
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            notesText = record.notes ?? ""
        }
    }

    private func saveNotes() {
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes = trimmedNotes.isEmpty ? nil : trimmedNotes

        onSaveNotes(finalNotes)
        isEditingNotes = false
    }
}
