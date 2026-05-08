import CoreData

/// Local Core Data stack (no CloudKit yet). Use **`NSPersistentCloudKitContainer`** later with the same model name.
final class PersistenceController {
    static let shared = PersistenceController()
    /// Optional startup maintenance pass for rebuilding baked-derived disk assets from source rows.
    /// Keep `false` for normal app runs; set to `true` when you want to clear stale baked files/tiles.
    private static let clearAllBakedDataAtStartup = true

    let container: NSPersistentContainer
    private var saveObserver: NSObjectProtocol?

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "SnapToMapModel")
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.url = URL(fileURLWithPath: "/dev/null")
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            container.persistentStoreDescriptions = [description]
        } else {
            for description in container.persistentStoreDescriptions {
                description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
                description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        container.viewContext.performAndWait {
            try? OverlayLibrary.migrateOverlayBoundingBoxesIfNeeded(context: container.viewContext)
            if Self.clearAllBakedDataAtStartup {
                _ = try? OverlayLibrary.clearAllBakedDerivedData(context: container.viewContext, clearTileCache: true)
            }
        }

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
}
