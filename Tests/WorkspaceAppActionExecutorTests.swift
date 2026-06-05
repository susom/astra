import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Action Executor")
struct WorkspaceAppActionExecutorTests {
    @MainActor
    @Test("app storage insert and query actions create durable app runs")
    func appStorageInsertAndQueryActionsCreateDurableRuns() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let insertResult = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )
        let queryResult = try WorkspaceAppActionExecutor().execute(
            actionID: "listItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(table: "items"),
            modelContext: fixture.context
        )

        #expect(insertResult.run.status == .completed)
        #expect(insertResult.outputSummary == "Inserted 1 record into items.")
        #expect(queryResult.rows.count == 1)
        #expect(queryResult.rows[0]["name"] == .text("Apples"))
        #expect(queryResult.run.status == .completed)
        #expect(fixture.app.lastRunAt != nil)

        let runs = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.appID == fixture.app.id && $0.workspaceID == fixture.workspace.id })

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.count == 4)
        #expect(events.contains { $0.type == "workspaceApp.action.started" && $0.actionID == "addItem" })
        #expect(events.contains { $0.type == "workspaceApp.action.completed" && $0.actionID == "listItems" })
    }

    @MainActor
    @Test("read-only apps block local write actions and record blocked runs")
    func readOnlyAppsBlockLocalWriteActionsAndRecordBlockedRuns() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Read-only workspace apps cannot perform local write action 'addItem'."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "addItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text("item-1"), "name": .text("Apples")]
                ),
                modelContext: fixture.context
            )
        }

        let rows = try WorkspaceAppStorageService().records(
            in: "items",
            databaseURL: URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: fixture.workspace.primaryPath,
                appID: fixture.app.logicalID
            ))
        )
        #expect(rows.isEmpty)

        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .blocked)
        #expect(run.completedAt != nil)
        #expect(run.errorMessage?.contains("Read-only workspace apps") == true)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { $0.type == "workspaceApp.action.blocked" })
    }

    @MainActor
    @Test("missing actions fail with a recorded app run")
    func missingActionsFailWithRecordedAppRun() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.missingAction("missing")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "missing",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .failed)
        #expect(run.actionID == "missing")
    }

    @MainActor
    static func makePublishedApp(
        permissionMode: WorkspaceAppPermissionMode
    ) throws -> (
        root: URL,
        container: ModelContainer,
        context: ModelContext,
        workspace: Workspace,
        app: WorkspaceApp,
        manifest: WorkspaceAppManifest
    ) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Actions", primaryPath: root.path)
        context.insert(workspace)

        let manifest = groceryManifest(permissionMode: permissionMode)
        let result = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )

        return (root, container, context, workspace, result.app, manifest)
    }

    static func groceryManifest(permissionMode: WorkspaceAppPermissionMode) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-actions",
                name: "Grocery Actions",
                icon: "cart"
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["insertRecord", "queryRecords"]
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "items", type: "table", title: "Items")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "addItem",
                    type: "appStorage.insert",
                    label: "Add Item",
                    requirementRef: "localRecords",
                    operation: "insertRecord"
                ),
                WorkspaceAppActionSpec(
                    id: "listItems",
                    type: "appStorage.query",
                    label: "List Items",
                    requirementRef: "localRecords",
                    operation: "queryRecords"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: permissionMode
            )
        )
    }
}
