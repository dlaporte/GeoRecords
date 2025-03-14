import SwiftUI

struct ContentView: View {
    @EnvironmentObject var deepLinkManager: DeepLinkManager
    @ObservedObject var recordManager = RecordManager.shared
    
    // Controls navigation triggered by deep link.
    @State private var navigateToDetail: Bool = false
    @State private var selectedRecord: RecordDetail? = nil
    
    var body: some View {
        NavigationView {
            TabView {
                RecordsView()
                    .tabItem {
                        Label("Records", systemImage: "doc.text")
                    }
                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock")
                    }
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .onReceive(deepLinkManager.$recordType) { recordType in
                if let type = recordType {
                    // Look up the corresponding record from RecordManager.
                    selectedRecord = recordForType(type)
                    navigateToDetail = (selectedRecord != nil)
                    // Reset deep link state after handling.
                    deepLinkManager.recordType = nil
                }
            }
            // Hidden NavigationLink triggered by the deep link.
            .background(
                NavigationLink(
                    destination: destinationView(),
                    isActive: $navigateToDetail,
                    label: { EmptyView() }
                )
            )
        }
    }
    
    // Returns the record for a given record type.
    func recordForType(_ type: String) -> RecordDetail? {
        switch type {
        case "Furthest North": return recordManager.furthestNorth
        case "Furthest South": return recordManager.furthestSouth
        case "Furthest East":  return recordManager.furthestEast
        case "Furthest West":  return recordManager.furthestWest
        case "Furthest Up":    return recordManager.furthestUp
        case "Furthest Down":  return recordManager.furthestDown
        case "Furthest from Home": return recordManager.furthestFromHome
        default: return nil
        }
    }
    
    @ViewBuilder
    func destinationView() -> some View {
        if let record = selectedRecord {
            RecordDetailView(record: record)
        } else {
            EmptyView()
        }
    }
}
