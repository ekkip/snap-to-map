import CoreData

/// Local Core Data stack (no CloudKit yet). Use **`NSPersistentCloudKitContainer`** later with the same model name.
final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer
    private var saveObserver: NSObjectProtocol?

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "SnapToMapModel")
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.url = URL(fileURLWithPath: "/dev/null")
            container.persistentStoreDescriptions = [description]
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        migrateLegacyFilesIfNeeded()

        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let saved = notification.object as? NSManagedObjectContext,
                  saved !== self.container.viewContext else { return }
            self.container.viewContext.mergeChanges(fromContextDidSave: notification)
        }
    }

    deinit {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
    }

    /// Run before any UI loads overlays so **`restore`** sees imported rows.
    private func migrateLegacyFilesIfNeeded() {
        container.viewContext.performAndWait {
            do {
                let didImport = try OverlayLibrary.importLegacyJSONAndPNGsIfStoreEmpty(context: container.viewContext)
                if container.viewContext.hasChanges {
                    try container.viewContext.save()
                    if didImport {
                        OverlayLibrary.deleteLegacyOverlayFileBundleIfPresent()
                    }
                }
            } catch {
                container.viewContext.rollback()
            }
        }
    }
}
