import SwiftUI
import MapKit

struct HomePickerView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var locationManager = LocationManager.shared  // Assumes currentLocation is published
    
    @State private var region: MKCoordinateRegion
    @State private var showAlert = false
    
    init() {
        let initialCoordinate = SettingsManager.shared.homeCoordinate
            ?? CLLocationCoordinate2D(latitude: 38.897957, longitude: -77.036560)
        _region = State(initialValue: MKCoordinateRegion(center: initialCoordinate,
                                                         span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    }
    
    var body: some View {
        VStack {
            Map(coordinateRegion: $region, annotationItems: [AnnotationItem(coordinate: region.center)]) { item in
                MapMarker(coordinate: item.coordinate, tint: .red)
            }
            .frame(height: 300)
            .cornerRadius(10)
            .padding()
            
            Text("Selected Location:")
                .font(.headline)
            Text("Lat: \(region.center.latitude, specifier: "%.4f"), Lon: \(region.center.longitude, specifier: "%.4f")")
                .padding(.bottom)
            
            Button("Use Current Location") {
                if let currentLocation = locationManager.currentLocation {
                    print("Using current location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
                    withAnimation {
                        region.center = currentLocation.coordinate
                    }
                } else {
                    print("No current location available!")
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
                settings.homeCoordinate = region.center
                presentationMode.wrappedValue.dismiss()
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
            print("HomePickerView appeared. Current region center: \(region.center.latitude), \(region.center.longitude)")
            if let current = locationManager.currentLocation {
                print("LocationManager.currentLocation: \(current.coordinate.latitude), \(current.coordinate.longitude)")
            } else {
                print("LocationManager.currentLocation is nil.")
            }
        }
    }
}

struct AnnotationItem: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
}

struct HomePickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HomePickerView()
        }
    }
}
