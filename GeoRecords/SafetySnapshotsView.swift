import SwiftUI

/// Lists the automatic safety snapshots taken before destructive operations
/// (Delete All Records, restores, Start Fresh) and lets the user restore one —
/// the local escape hatch when an iCloud restore can't deliver the records back.
struct SafetySnapshotsView: View {
    @State private var snapshots: [BackupManager.SafetySnapshot] = []
    @State private var pendingRestore: BackupManager.SafetySnapshot?
    @State private var isRestoring = false
    @State private var resultMessage = ""
    @State private var showResult = false

    var body: some View {
        List {
            if snapshots.isEmpty {
                Text("No automatic snapshots yet. One is saved on this device before every destructive operation, such as Delete All Records or restoring a backup.")
                    .foregroundColor(.secondary)
            } else {
                Section {
                    ForEach(snapshots) { snapshot in
                        Button {
                            pendingRestore = snapshot
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snapshot.reasonLabel)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(snapshot.exportDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(snapshot.contentsDescription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isRestoring {
                                    ProgressView()
                                } else {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .disabled(isRestoring)
                    }
                } footer: {
                    Text("Restoring replaces the records currently on this device with the snapshot's contents, then syncs them to iCloud.")
                }
            }
        }
        .navigationTitle("Automatic Snapshots")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snapshots = BackupManager.shared.listSafetySnapshots()
        }
        .alert("Restore this snapshot?", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        ), presenting: pendingRestore) { snapshot in
            Button("Restore") { restore(snapshot) }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { snapshot in
            Text("Saved \(snapshot.exportDate.formatted(date: .abbreviated, time: .shortened)) — \(snapshot.contentsDescription). This replaces the records currently on this device.")
        }
        .alert("Snapshot Restore", isPresented: $showResult) {
            Button("OK") {}
        } message: {
            Text(resultMessage)
        }
    }

    private func restore(_ snapshot: BackupManager.SafetySnapshot) {
        isRestoring = true
        pendingRestore = nil
        Task {
            let result = await BackupManager.shared.importBackup(from: snapshot.url)
            await MainActor.run {
                isRestoring = false
                resultMessage = result.map { BackupManager.importResultMessage(for: $0) }
                    ?? "Failed to restore the snapshot. The file may be corrupted."
                showResult = true
                // importBackup writes its own pre-restore snapshot; refresh the list
                snapshots = BackupManager.shared.listSafetySnapshots()
            }
        }
    }
}

#Preview {
    NavigationStack {
        SafetySnapshotsView()
    }
}
