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
    @Test("artifact export actions write linked CSV files from app storage")
    func artifactExportActionsWriteLinkedCSVFilesFromAppStorage() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
            actionID: "addItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Apples, Gala"),
                    "category": .text("Produce")
                ]
            ),
            modelContext: fixture.context
        )

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        #expect(path.hasSuffix("/.astra/apps/grocery-actions/exports/items.csv"))
        #expect(csv == "id,name,category\nitem-1,\"Apples, Gala\",Produce\n")
        #expect(result.outputSummary == "Exported items.csv.")

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.artifact.exported" &&
                event.payload.contains("items.csv")
        })
    }

    @MainActor
    @Test("artifact export actions write linked JSON files from app storage")
    func artifactExportActionsWriteLinkedJSONFilesFromAppStorage() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try WorkspaceAppActionExecutor().execute(
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

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "exportItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(exportFormat: "json"),
            modelContext: fixture.context
        )

        let path = try #require(result.run.linkedArtifactPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rows = try JSONDecoder().decode([[String: WorkspaceAppStorageValue]].self, from: data)
        #expect(path.hasSuffix("/.astra/apps/grocery-actions/exports/items.json"))
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Apples"))
    }

    @MainActor
    @Test("task create draft actions create linked AgentTask drafts")
    func taskCreateDraftActionsCreateLinkedAgentTaskDrafts() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .draftOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "createReviewTask",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first {
            $0.id == result.run.linkedTaskID
        })
        #expect(task.status == .draft)
        #expect(task.workspace?.id == fixture.workspace.id)
        #expect(task.title == "Review grocery records")
        #expect(task.goal == "Review the grocery records and propose the next shopping task.")
        #expect(task.inputs.contains("Created from Workspace App 'Grocery Actions' (grocery-actions)."))
        #expect(result.outputSummary == "Created draft task 'Review grocery records'.")
        #expect(result.run.status == .completed)
        #expect(result.run.linkedTaskID == task.id)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.task.created" &&
                event.payload.contains(task.id.uuidString)
        })
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
    @Test("read-only apps block task draft actions")
    func readOnlyAppsBlockTaskDraftActions() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Read-only workspace apps cannot perform local write action 'createReviewTask'."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "createReviewTask",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        #expect(try fixture.context.fetch(FetchDescriptor<AgentTask>()).isEmpty)
        let run = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>()).first)
        #expect(run.status == .blocked)
        #expect(run.linkedTaskID == nil)
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
                ),
                WorkspaceAppActionSpec(
                    id: "createReviewTask",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review grocery records",
                    taskGoal: "Review the grocery records and propose the next shopping task."
                ),
                WorkspaceAppActionSpec(
                    id: "exportItems",
                    type: "artifact.export",
                    label: "Export Items",
                    table: "items",
                    exportFormat: "csv"
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
