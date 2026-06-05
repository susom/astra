import Foundation

struct WorkspaceAppStorageTableSnapshot: Equatable {
    var name: String
    var columns: [String]
    var rows: [[String: WorkspaceAppStorageValue]]
    var errorMessage: String?

    var rowCount: Int {
        rows.count
    }
}

struct WorkspaceAppDetailDataSnapshot: Equatable {
    var manifest: WorkspaceAppManifest?
    var storageTables: [WorkspaceAppStorageTableSnapshot]
    var errorMessage: String?

    static let empty = WorkspaceAppDetailDataSnapshot(
        manifest: nil,
        storageTables: [],
        errorMessage: nil
    )
}

struct WorkspaceAppDetailDataLoader {
    var fileManager: FileManager = .default
    var storageService = WorkspaceAppStorageService()

    func load(app: WorkspaceApp, workspace: Workspace?) -> WorkspaceAppDetailDataSnapshot {
        guard let workspace, !workspace.primaryPath.isEmpty else {
            return WorkspaceAppDetailDataSnapshot(
                manifest: nil,
                storageTables: [],
                errorMessage: "Workspace path is unavailable."
            )
        }

        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
            let tables = (manifest.storage?.tables ?? []).map { table in
                tableSnapshot(table, databaseURL: databaseURL)
            }
            return WorkspaceAppDetailDataSnapshot(
                manifest: manifest,
                storageTables: tables,
                errorMessage: nil
            )
        } catch {
            return WorkspaceAppDetailDataSnapshot(
                manifest: nil,
                storageTables: [],
                errorMessage: "Could not load app manifest."
            )
        }
    }

    private func tableSnapshot(
        _ table: WorkspaceAppStorageTable,
        databaseURL: URL
    ) -> WorkspaceAppStorageTableSnapshot {
        do {
            let rows = fileManager.fileExists(atPath: databaseURL.path)
                ? try storageService.records(in: table.name, databaseURL: databaseURL)
                : []
            return WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: rows,
                errorMessage: nil
            )
        } catch {
            return WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: [],
                errorMessage: "Could not read table records."
            )
        }
    }
}
