import SwiftUI
import MapKit
import CoreLocation

/// View for entering location coordinates manually or by search
struct CoordinatePickerView: View {
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var mapPosition: MapCameraPosition
    @Environment(\.dismiss) var dismiss

    @State private var inputMode: InputMode = .search
    @State private var locationSearchText = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSearching = false
    @State private var searchResults: [CLPlacemark] = []

    enum InputMode: String, CaseIterable {
        case search = "Search"
        case coordinates = "Coordinates"
    }

    var body: some View {
        Form {
            Section {
                Picker("Input Method", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if inputMode == .search {
                Section(header: Text("Search for Location")) {
                    TextField("Enter city, address, or place name", text: $locationSearchText)
                        .autocapitalization(.words)
                        .onChange(of: locationSearchText) { oldValue, newValue in
                            // Clear results when user types
                            searchResults = []
                        }

                    Text("Example: \"Paris, France\" or \"Eiffel Tower\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button(action: {
                        searchLocation()
                    }) {
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                Text("Searching...")
                                    .padding(.leading, 8)
                                Spacer()
                            }
                        } else {
                            Text("Search")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(locationSearchText.isEmpty || isSearching)
                }

                if !searchResults.isEmpty {
                    Section(header: Text("Search Results")) {
                        ForEach(searchResults.indices, id: \.self) { index in
                            Button(action: {
                                selectLocation(searchResults[index])
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formatPlacemarkName(searchResults[index]))
                                        .foregroundColor(.primary)
                                    if let subtitle = formatPlacemarkSubtitle(searchResults[index]) {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Section(header: Text("Enter Coordinates")) {
                    HStack {
                        Text("Latitude:")
                        TextField("40.7128", text: $latitudeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Longitude:")
                        TextField("-74.0060", text: $longitudeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }

                    Text("Latitude range: -90 to 90")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Longitude range: -180 to 180")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Set Location") {
                        validateAndSet()
                    }
                    .disabled(latitudeText.isEmpty || longitudeText.isEmpty)
                }
            }
        }
        .navigationTitle("Enter Location")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func searchLocation() {
        isSearching = true
        searchResults = []
        let geocoder = CLGeocoder()

        geocoder.geocodeAddressString(locationSearchText) { placemarks, error in
            isSearching = false

            if let error = error {
                errorMessage = "Could not find location: \(error.localizedDescription)"
                showError = true
                return
            }

            guard let placemarks = placemarks, !placemarks.isEmpty else {
                errorMessage = "No results found for '\(locationSearchText)'"
                showError = true
                return
            }

            searchResults = placemarks
        }
    }

    private func selectLocation(_ placemark: CLPlacemark) {
        guard let location = placemark.location else { return }

        let newCoordinate = location.coordinate
        coordinate = newCoordinate
        mapPosition = .region(MKCoordinateRegion(
            center: newCoordinate,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
        ))

        dismiss()
    }

    private func formatPlacemarkName(_ placemark: CLPlacemark) -> String {
        if let name = placemark.name {
            return name
        }
        if let locality = placemark.locality {
            return locality
        }
        return "Unknown Location"
    }

    private func formatPlacemarkSubtitle(_ placemark: CLPlacemark) -> String? {
        var components: [String] = []

        if let locality = placemark.locality, placemark.name != locality {
            components.append(locality)
        }
        if let adminArea = placemark.administrativeArea {
            components.append(adminArea)
        }
        if let country = placemark.country {
            components.append(country)
        }

        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    private func validateAndSet() {
        guard let lat = Double(latitudeText), let lon = Double(longitudeText) else {
            errorMessage = "Please enter valid numbers for latitude and longitude"
            showError = true
            return
        }

        guard lat >= -90 && lat <= 90 else {
            errorMessage = "Latitude must be between -90 and 90"
            showError = true
            return
        }

        guard lon >= -180 && lon <= 180 else {
            errorMessage = "Longitude must be between -180 and 180"
            showError = true
            return
        }

        let newCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        coordinate = newCoordinate
        mapPosition = .region(MKCoordinateRegion(
            center: newCoordinate,
            span: MKCoordinateSpan(latitudeDelta: defaultMapLatDelta, longitudeDelta: defaultMapLonDelta)
        ))

        dismiss()
    }
}
