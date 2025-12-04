import SwiftUI
import MapKit

struct HomePickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var locationManager: LocationManager

    @State private var position: MapCameraPosition
    @State private var currentCoordinate: CLLocationCoordinate2D
    @State private var showAlert = false

    init() {
        let defaultCoord = CLLocationCoordinate2D(latitude: 38.897957, longitude: -77.036560)
        // Initialize with default position (will be updated in onAppear)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: defaultCoord,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )))
        _currentCoordinate = State(initialValue: defaultCoord)
    }

    var body: some View {
        VStack {
            MapReader { reader in
                Map(position: $position) {
                    Marker("", coordinate: currentCoordinate)
                        .tint(.red)
                }
                .frame(height: 300)
                .cornerRadius(10)
                .padding()
                .onTapGesture { position in
                    if let coordinate = reader.convert(position, from: .local) {
                        withAnimation {
                            currentCoordinate = coordinate
                        }
                    }
                }
            }
            .onAppear {
                // Initialize position with home coordinate from environment object
                if let homeCoord = settings.homeCoordinate {
                    currentCoordinate = homeCoord
                    position = .region(MKCoordinateRegion(
                        center: homeCoord,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }

            Text("Selected Location:")
                .font(.headline)
            Text("Lat: \(currentCoordinate.latitude, specifier: "%.4f"), Lon: \(currentCoordinate.longitude, specifier: "%.4f")")
                .padding(.bottom)

            Button("Use Current Location") {
                if let currentLocation = locationManager.currentLocation {
                    debugLog("Using current location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
                    withAnimation {
                        currentCoordinate = currentLocation.coordinate
                        position = .region(MKCoordinateRegion(
                            center: currentLocation.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        ))
                    }
                } else {
                    debugLog("No current location available!")
                    showAlert = true
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.horizontal)
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Location Unavailable"), message: Text("We could not determine your current location. Please ensure Location Services are enabled and try again."), dismissButton: .default(Text("OK")))
            }
            
            Button("Set Home Location") {
                settings.homeCoordinate = currentCoordinate
                settings.saveSettings()
                dismiss()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Select Home Location")
        .onAppear {
            debugLog("HomePickerView appeared. Current position center: \(currentCoordinate.latitude), \(currentCoordinate.longitude)")
            if let current = locationManager.currentLocation {
                debugLog("LocationManager.currentLocation: \(current.coordinate.latitude), \(current.coordinate.longitude)")
            } else {
                debugLog("LocationManager.currentLocation is nil.")
            }
        }
    }
}

struct HomePickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            HomePickerView()
                .environmentObject(SettingsManager.shared)
                .environmentObject(LocationManager.shared)
        }
    }
}
