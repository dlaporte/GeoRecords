import SwiftUI
import Photos
import CoreLocation

struct ImportPreviewView: View {
    @EnvironmentObject var scanner: PhotoLibraryScanner
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.dismiss) var dismiss
    @State private var isImporting = false
    @State private var showSuccess = false
    @State private var importedCount = 0
    @State private var importedCountryCount = 0
    @State private var importedStateCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if scanner.isScanning {
                    // Scanning progress
                    VStack(spacing: 20) {
                        ProgressView(value: scanner.progress) {
                            Text("Scanning Photo Library...")
                                .font(.headline)
                        }
                        .padding()

                        VStack(spacing: 8) {
                            Text("Scanned \(scanner.scannedPhotos) of \(scanner.totalPhotos) photos")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Text("\(scanner.photosWithLocation) photos with location data")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if scanner.discoveredCountryCount > 0 || scanner.discoveredStateCount > 0 {
                                Text("\(scanner.discoveredCountryCount) countries, \(scanner.discoveredStateCount) states found")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                } else if let errorMessage = scanner.errorMessage {
                    // Error state
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)

                        Text(errorMessage)
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Button("Close") {
                            dismiss()
                        }
                        .padding()
                    }
                    .padding()
                } else if !scanner.isConfirming && scanner.discoveredRecords.isEmpty && !scanner.hasWizardRecords {
                    // No records found (neither legacy nor wizard mode has records)
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)

                        Text("No Records Found")
                            .font(.headline)

                        Text("We couldn't find any photos with location data that would set new records.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Close") {
                            dismiss()
                        }
                        .padding()
                    }
                    .padding()
                } else if scanner.isConfirming {
                    // Wizard-based confirmation flow
                    ImportWizardView(
                        scanner: scanner,
                        onImport: {
                            importRecords()
                        }
                    )
                    .environmentObject(settings)
                } else {
                    // Confirmation complete - show summary and import button
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                            .padding(.top, 40)

                        Text("Confirmation Complete!")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("You've selected \(scanner.confirmedRecords.count) record(s) to import")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Spacer()

                        // Import button
                        Button(action: {
                            importRecords()
                        }) {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Text("Import \(scanner.confirmedRecords.count) Record(s)")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isImporting || scanner.confirmedRecords.isEmpty)
                        .padding()
                    }
                }
            }
            .navigationTitle(scanner.isWizardMode ? "" : "Import Records from Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !scanner.isWizardMode || !scanner.isImporting {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            .toolbarBackground(scanner.isWizardMode ? .hidden : .visible, for: .navigationBar)
            .alert("Success!", isPresented: $showSuccess) {
                Button("View Records") {
                    dismiss()
                }
            } message: {
                Text("Imported \(importedCount) records from your photo library!")
            }
        }
    }

    private func importRecords() {
        isImporting = true

        Task {
            await scanner.importSelectedRecords { count in
                importedCount = count
                isImporting = false
                showSuccess = true
                // Suppression is now handled inside importSelectedRecords() after all records are imported
            }
        }
    }
}
