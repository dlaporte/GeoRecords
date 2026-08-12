import SwiftUI
import UniformTypeIdentifiers

/// Shown when user has completed setup but has no records
/// Offers options to scan photos, restore from backup, or explicitly start fresh
struct NoRecordsView: View {
    @Environment(\.dismiss) var dismiss
    let onScanPhotos: () -> Void
    /// Explicit "begin from zero" choice — releases the data-restore gate so
    /// automatic record tracking resumes. Optional so previews stay simple.
    var onStartFresh: (() -> Void)? = nil

    @State private var showFilePicker = false
    @State private var showImportConfirm = false
    @State private var showImportResult = false
    @State private var importResultMessage = ""
    @State private var pendingBackupURL: URL?
    @State private var backupInfo: (recordCount: Int, regionCount: Int, exportDate: Date, deviceName: String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 40)

                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: "map")
                            .font(.system(size: 70))
                            .foregroundColor(.orange)

                        Text("No Records Found")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Import your geographical records to get started tracking your adventures.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Primary option: Scan Photos
                    VStack(spacing: 12) {
                        Button(action: {
                            dismiss()
                            onScanPhotos()
                        }) {
                            HStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 28))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Scan Photo Library")
                                        .font(.headline)
                                    Text("Find records from your geotagged photos")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.body)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        Text("Recommended")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)

                    // Divider
                    HStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)
                        Text("or")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 32)

                    // Secondary option: Restore from Backup
                    VStack(spacing: 16) {
                        Button(action: {
                            showFilePicker = true
                        }) {
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 24))
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Restore from Backup")
                                        .font(.headline)
                                    Text("Import a .georecords backup file")
                                        .font(.caption)
                                        .opacity(0.8)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.body)
                                    .opacity(0.6)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(UIColor.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }

                        Text("Or open a .georecords file from the Files app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)

                    // Explicit escape hatch: without it, declining both restore options
                    // leaves record tracking suspended with no way to re-enable it
                    if let onStartFresh = onStartFresh {
                        Button {
                            onStartFresh()
                            dismiss()
                        } label: {
                            Text("Start Fresh — track from scratch")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .underline()
                        }
                    }

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.georecordsBackup, .json],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Restore from Backup?", isPresented: $showImportConfirm) {
                Button("Restore") { performImport() }
                Button("Cancel", role: .cancel) { clearBackupInfo() }
            } message: {
                Text(backupImportMessage)
            }
            .alert("Import Complete", isPresented: $showImportResult) {
                Button("OK") { dismiss() }
            } message: {
                Text(importResultMessage)
            }
        }
    }

    private var backupImportMessage: String {
        if let info = backupInfo {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: info.exportDate)

            var contents: [String] = []
            if info.recordCount > 0 {
                contents.append("\(info.recordCount) record\(info.recordCount == 1 ? "" : "s")")
            }
            if info.regionCount > 0 {
                contents.append("\(info.regionCount) visited region\(info.regionCount == 1 ? "" : "s")")
            }

            let contentsString = contents.isEmpty ? "no data" : contents.joined(separator: " and ")
            return "This backup contains \(contentsString) from \(info.deviceName), exported on \(dateString)."
        } else {
            return "Restore from this backup file?"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importResultMessage = "Unable to access the selected file."
                showImportResult = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            // Copy to temp location
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("georecords")

            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                pendingBackupURL = tempURL

                // Get backup info
                if let info = BackupManager.shared.getBackupInfo(from: tempURL) {
                    backupInfo = info
                    showImportConfirm = true
                } else {
                    importResultMessage = "Could not read backup file. It may be corrupted or invalid."
                    showImportResult = true
                }
            } catch {
                importResultMessage = "Failed to read backup file: \(error.localizedDescription)"
                showImportResult = true
            }

        case .failure(let error):
            importResultMessage = "Failed to select file: \(error.localizedDescription)"
            showImportResult = true
        }
    }

    private func performImport() {
        guard let url = pendingBackupURL else { return }

        Task {
            if let result = await BackupManager.shared.importBackup(from: url) {
                await MainActor.run {
                    importResultMessage = BackupManager.importResultMessage(for: result)
                    showImportResult = true
                    clearBackupInfo()
                }
            } else {
                await MainActor.run {
                    importResultMessage = "Failed to import backup. The file may be corrupted or incompatible."
                    showImportResult = true
                    clearBackupInfo()
                }
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func clearBackupInfo() {
        // Clean up temp file if it exists
        if let url = pendingBackupURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingBackupURL = nil
        backupInfo = nil
    }
}

#Preview {
    NoRecordsView(onScanPhotos: {})
}
