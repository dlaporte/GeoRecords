import Foundation
import CoreData
import WidgetKit

/// Coalesces widget timeline reloads. Record and region writes arrive in bursts (a
/// wizard import, a border crossing that sets several records at once), and
/// WidgetKit budgets reloads per day, so callers request a reload and a single one
/// happens once the burst settles.
@MainActor
final class WidgetReloader {
    static let shared = WidgetReloader()

    private let delay: Duration
    private let perform: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var saveObserver: NSObjectProtocol?

    init(delay: Duration = .seconds(3),
         perform: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.delay = delay
        self.perform = perform
    }

    /// Ask for a reload; repeated requests within `delay` collapse into one
    func requestReload() {
        pending?.cancel()
        pending = Task { [delay, perform] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // superseded by a newer request
            }
            perform()
        }
    }

    /// Reload after any save that touches record/region rows. Daily-stat rows are
    /// saved on every location fix and the widgets never show them, so those saves
    /// are ignored. (Rows arriving via iCloud sync merge without a local save; the
    /// widgets' hourly refresh covers that.)
    func observeSaves(of context: NSManagedObjectContext) {
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: context, queue: .main
        ) { [weak self] notification in
            guard Self.changedRecordRows(in: notification) else { return }
            Task { @MainActor [weak self] in
                self?.requestReload()
            }
        }
    }

    private nonisolated static func changedRecordRows(in notification: Notification) -> Bool {
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            if let objects = notification.userInfo?[key] as? Set<NSManagedObject>,
               objects.contains(where: { $0.entity.name == "RecordHistoryEntry" }) {
                return true
            }
        }
        return false
    }
}
