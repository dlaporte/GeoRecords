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

    /// When true, show scan-range options before starting (manual import entry points).
    /// The setup wizard starts its own full scan and never shows this.
    var allowScanOptions: Bool = false
    @State private var hasStartedScan = false

    private func startScan(from startDate: Date?, includeRecords: Bool, includeRegions: Bool) {
        hasStartedScan = true
        Task {
            await scanner.scanPhotoLibrary(
                homeCoordinate: settings.homeCoordinate,
                startDate: startDate,
                includeRecords: includeRecords,
                includeRegions: includeRegions
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allowScanOptions && !hasStartedScan && !scanner.isScanning && !scanner.isProcessing && !scanner.hasWizardRecords {
                    ScanOptionsForm(onStart: startScan)
                } else if scanner.isScanning {
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
                } else if scanner.isProcessing {
                    // Post-scan processing
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Processing Results...")
                            .font(.headline)

                        VStack(spacing: 8) {
                            Text("Organizing \(scanner.photosWithLocation) photos into records")
                                .font(.subheadline)
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

                        if allowScanOptions {
                            Button("Scan Again") {
                                // Safe to reset here: this branch mounts no views that
                                // index into the scanner's candidate arrays
                                scanner.cancelAndReset()
                                hasStartedScan = false
                            }
                            .buttonStyle(.borderedProminent)
                        }

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

                        if allowScanOptions {
                            Button("Scan Again") {
                                scanner.cancelAndReset()
                                hasStartedScan = false
                            }
                            .buttonStyle(.borderedProminent)
                        }

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
                            // State reset happens in the presenter's onDismiss — clearing
                            // wizard arrays while this hierarchy is still mounted lets
                            // SwiftUI re-render views whose selections index cleared arrays
                            dismiss()
                        }
                    }
                }
            }
            .toolbarBackground(scanner.isWizardMode ? .hidden : .visible, for: .navigationBar)
            .alert("Success!", isPresented: $showSuccess) {
                Button("Done") {
                    dismiss()
                }
            } message: {
                Text(completionMessage)
            }
        }
    }

    /// Build the completion message including records, countries, and states
    private var completionMessage: String {
        var parts: [String] = []

        if importedCount > 0 {
            parts.append("\(importedCount) record\(importedCount == 1 ? "" : "s")")
        }

        if importedCountryCount > 0 {
            parts.append("\(importedCountryCount) countr\(importedCountryCount == 1 ? "y" : "ies")")
        }

        if importedStateCount > 0 {
            parts.append("\(importedStateCount) state\(importedStateCount == 1 ? "" : "s")")
        }

        if parts.isEmpty {
            return "Import complete!"
        } else if parts.count == 1 {
            return "Imported \(parts[0]) from your photo library!"
        } else if parts.count == 2 {
            return "Imported \(parts[0]) and \(parts[1]) from your photo library!"
        } else {
            let lastPart = parts.removeLast()
            return "Imported \(parts.joined(separator: ", ")), and \(lastPart) from your photo library!"
        }
    }

    private func importRecords() {
        isImporting = true

        // Count confirmed regions before import
        importedCountryCount = scanner.discoveredCountries.filter { $0.confirmed }.count
        importedStateCount = scanner.discoveredStates.filter { $0.confirmed }.count

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

// MARK: - Scan Options

/// Pre-scan options for manual photo imports: entire library, or only photos
/// taken after a user-chosen date (useful for filling a known gap quickly)
private struct ScanOptionsForm: View {
    let onStart: (Date?, _ includeRecords: Bool, _ includeRegions: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var limitByDate = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var includeRecords = true
    @State private var includeRegions = true

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Scan Your Photo Library")
                .font(.title2)
                .fontWeight(.bold)

            Text("GeoRecords will look through your geotagged photos for records and visited regions.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Toggle("Only scan photos after a date", isOn: $limitByDate.animation())

                if limitByDate {
                    DatePicker(
                        "Start date",
                        selection: $startDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                }

                Divider()

                // "Stats" and "history" are derived from records, so these two toggles
                // cover everything the scan can produce
                Toggle("Records", isOn: $includeRecords)
                Toggle("Regions (states & countries)", isOn: $includeRegions)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .padding(.horizontal)

            Button {
                onStart(limitByDate ? startDate : nil, includeRecords, includeRegions)
            } label: {
                Text(limitByDate ? "Scan Photos Since \(startDate.formatted(date: .abbreviated, time: .omitted))" : "Scan Entire Library")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(includeRecords || includeRegions ? Color.blue : Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(!includeRecords && !includeRegions)
            .padding(.horizontal)

            Button("Cancel") {
                dismiss()
            }
            .foregroundColor(.secondary)

            Spacer()
        }
    }
}
