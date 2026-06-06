import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Source Resolver")
struct WorkspaceAppSourceResolverTests {
    @Test("resolver reads declared app storage sources")
    func resolverReadsDeclaredAppStorageSources() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Storage Sources", primaryPath: root.path)
        let manifest = Self.storageManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        let storage = WorkspaceAppStorageService()
        try storage.applySchema(try #require(manifest.storage), databaseURL: databaseURL)
        try storage.insertRecord(
            ["id": .text("item-1"), "name": .text("Apples"), "quantity": .integer(6)],
            into: "items",
            databaseURL: databaseURL
        )

        let result = try WorkspaceAppSourceResolver().resolve(
            sourceID: "inventory",
            app: app,
            workspace: workspace,
            manifest: manifest
        )

        #expect(result.sourceID == "inventory")
        #expect(result.rows.count == 1)
        #expect(result.rows[0]["name"] == .text("Apples"))
        #expect(result.rows[0]["quantity"] == .integer(6))
        #expect(result.implementationID == "app-storage-native")
        #expect(result.provider == "astra")
        #expect(result.outputSummary.contains("app storage table 'items'"))
    }

    @Test("resolver reads mocked capability contract sources through mapped bindings")
    func resolverReadsMockedCapabilitySourcesThroughBindings() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = Self.reconciliationManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let bindings = [
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                requirementID: "sourceWarehouse",
                contract: "tabularQuery.read",
                operations: ["runReadOnlyQuery"],
                optional: false,
                status: .mapped,
                implementationID: "bigquery-read-task-backed",
                provider: "bigQuery",
                transport: .taskBacked
            ),
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                requirementID: "targetRecords",
                contract: "recordProject.read",
                operations: ["readRecords"],
                optional: false,
                status: .mapped,
                implementationID: "redcap-read-task-backed",
                provider: "redcap",
                transport: .taskBacked
            )
        ]
        let resolver = WorkspaceAppSourceResolver(
            capabilityClient: MockCapabilitySourceClient(rowsBySourceID: [
                "warehouse_latest": [
                    ["participant_id": .text("P-001"), "mrn": .text("1001")]
                ],
                "redcap_records": [
                    ["participant_id": .text("P-002"), "record_id": .text("2")]
                ]
            ])
        )

        let warehouse = try resolver.resolve(
            sourceID: "warehouse_latest",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: bindings
        )
        let redcap = try resolver.resolve(
            sourceID: "redcap_records",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: bindings
        )

        #expect(warehouse.rows == [["participant_id": .text("P-001"), "mrn": .text("1001")]])
        #expect(warehouse.requirementID == "sourceWarehouse")
        #expect(warehouse.implementationID == "bigquery-read-task-backed")
        #expect(warehouse.provider == "bigQuery")
        #expect(redcap.rows == [["participant_id": .text("P-002"), "record_id": .text("2")]])
        #expect(redcap.requirementID == "targetRecords")
        #expect(redcap.implementationID == "redcap-read-task-backed")
        #expect(redcap.provider == "redcap")
    }

    @Test("resolver blocks capability sources without mapped dependencies")
    func resolverBlocksCapabilitySourcesWithoutMappedDependencies() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = Self.reconciliationManifest()
        let app = Self.app(for: manifest, workspace: workspace)

        #expect(throws: WorkspaceAppSourceResolutionError.missingMappedBinding("sourceWarehouse")) {
            try WorkspaceAppSourceResolver().resolve(
                sourceID: "warehouse_latest",
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: []
            )
        }
    }

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-source-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func app(for manifest: WorkspaceAppManifest, workspace: Workspace) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
    }

    static func storageManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "inventory-app", name: "Inventory"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "quantity", type: "integer")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "inventory", mode: "read", sourceRef: "items")
            ]
        )
    }

    static func reconciliationManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "recon", name: "Reconciliation"),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    operations: ["runReadOnlyQuery"],
                    providerHint: "bigQuery"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    operations: ["readRecords"],
                    providerHint: "redcap"
                )
            ],
            sources: [
                WorkspaceAppSource(
                    id: "warehouse_latest",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    tableRef: "clinical.enrollment_candidates"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    mode: "read",
                    projectRef: "enrollment"
                )
            ]
        )
    }
}

private struct MockCapabilitySourceClient: WorkspaceAppCapabilitySourceClient {
    var rowsBySourceID: [String: [[String: WorkspaceAppStorageValue]]]

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        rowsBySourceID[source.id] ?? []
    }
}
