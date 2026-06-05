import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Detail Data Loader")
struct WorkspaceAppDetailDataLoaderTests {
    @Test("loader reads manifest storage tables and app records")
    func loaderReadsManifestStorageTablesAndAppRecords() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-detail-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Grocery", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery",
                name: "Grocery Tracker",
                description: "Track grocery records."
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "quantity", type: "integer")
                ])
            ])
        )
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)

        let storageService = WorkspaceAppStorageService()
        try storageService.applySchema(try #require(manifest.storage), databaseURL: databaseURL)
        try storageService.insertRecord([
            "id": .text("item-1"),
            "name": .text("Apples"),
            "quantity": .integer(6)
        ], into: "items", databaseURL: databaseURL)
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )

        let snapshot = WorkspaceAppDetailDataLoader().load(app: app, workspace: workspace)

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.manifest == manifest)
        #expect(snapshot.storageTables.count == 1)
        #expect(snapshot.storageTables[0].name == "items")
        #expect(snapshot.storageTables[0].columns == ["id", "name", "quantity"])
        #expect(snapshot.storageTables[0].rows.count == 1)
        #expect(snapshot.storageTables[0].rows[0]["name"] == .text("Apples"))
        #expect(snapshot.storageTables[0].rows[0]["quantity"] == .integer(6))
    }

    @Test("loader returns a visible error when manifest is unavailable")
    func loaderReturnsVisibleErrorWhenManifestUnavailable() {
        let workspace = Workspace(name: "Missing", primaryPath: "/tmp/missing-\(UUID().uuidString)")
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "missing-app",
            name: "Missing App",
            manifestRelativePath: ".astra/apps/missing-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/missing-app",
            manifestDigest: "digest"
        )

        let snapshot = WorkspaceAppDetailDataLoader().load(app: app, workspace: workspace)

        #expect(snapshot.manifest == nil)
        #expect(snapshot.storageTables.isEmpty)
        #expect(snapshot.errorMessage == "Could not load app manifest.")
    }
}
