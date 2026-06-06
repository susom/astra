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
    @Test("app storage update and delete actions mutate records with primary key input")
    func appStorageUpdateAndDeleteActionsMutateRecordsWithPrimaryKeyInput() throws {
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

        let updateResult = try WorkspaceAppActionExecutor().execute(
            actionID: "updateItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: [
                    "id": .text("item-1"),
                    "name": .text("Oranges"),
                    "category": .text("Citrus")
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

        #expect(updateResult.outputSummary == "Updated 1 record in items.")
        #expect(queryResult.rows.count == 1)
        #expect(queryResult.rows[0]["name"] == .text("Oranges"))
        #expect(queryResult.rows[0]["category"] == .text("Citrus"))

        #expect(throws: WorkspaceAppActionExecutionError.permissionDenied(
            "Destructive action 'deleteItem' requires explicit confirmation before execution."
        )) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "deleteItem",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(
                    table: "items",
                    record: ["id": .text("item-1")]
                ),
                modelContext: fixture.context
            )
        }

        let deleteResult = try WorkspaceAppActionExecutor().execute(
            actionID: "deleteItem",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(
                table: "items",
                record: ["id": .text("item-1")],
                confirmedDestructive: true
            ),
            modelContext: fixture.context
        )
        let finalQuery = try WorkspaceAppActionExecutor().execute(
            actionID: "listItems",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(table: "items"),
            modelContext: fixture.context
        )

        #expect(deleteResult.outputSummary == "Deleted 1 record from items.")
        #expect(finalQuery.rows.isEmpty)
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
    @Test("task create and run actions queue linked AgentTasks")
    func taskCreateAndRunActionsQueueLinkedAgentTasks() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "runReviewTask",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        let task = try #require(try fixture.context.fetch(FetchDescriptor<AgentTask>()).first {
            $0.id == result.run.linkedTaskID
        })
        #expect(task.status == .queued)
        #expect(task.workspace?.id == fixture.workspace.id)
        #expect(task.title == "Run grocery review")
        #expect(task.goal == "Run the grocery review workflow and summarize the required follow-up.")
        #expect(task.inputs.contains("Created from Workspace App 'Grocery Actions' (grocery-actions)."))
        #expect(result.outputSummary == "Queued task 'Run grocery review'.")
        #expect(result.run.status == .completed)
        #expect(result.run.linkedTaskID == task.id)

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
        #expect(events.contains { event in
            event.type == "workspaceApp.task.created" &&
            event.payload.contains(task.id.uuidString)
        })
    }

    @MainActor
    @Test("capability read actions resolve mapped sources")
    func capabilityReadActionsResolveMappedSources() throws {
        let fixture = try Self.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            requirementID: "warehouse",
            contract: "tabularQuery.read",
            operations: ["runReadOnlyQuery"],
            optional: false,
            status: .mapped,
            implementationID: "bigquery-read-task-backed",
            provider: "bigQuery",
            transport: .taskBacked
        )
        let executor = WorkspaceAppActionExecutor(
            sourceResolver: WorkspaceAppSourceResolver(
                capabilityClient: MockWorkspaceAppCapabilitySourceClient(rowsBySourceID: [
                    "warehouseLatest": [
                        ["participant_id": .text("P-001"), "updated_at": .text("2026-06-05")]
                    ]
                ])
            )
        )

        let result = try executor.execute(
            actionID: "readWarehouse",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(limit: 25),
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.rows == [["participant_id": .text("P-001"), "updated_at": .text("2026-06-05")]])
        #expect(result.outputSummary.contains("warehouseLatest"))
        #expect(result.outputSummary.contains("bigquery-read-task-backed"))

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains {
            $0.type == "workspaceApp.capability.read" &&
                $0.payload.contains("\"sourceID\":\"warehouseLatest\"") &&
                $0.payload.contains("\"implementationID\":\"bigquery-read-task-backed\"") &&
                $0.payload.contains("\"provider\":\"bigQuery\"") &&
                $0.payload.contains("\"rowCount\":1")
        })
    }

    @MainActor
    @Test("pipeline actions execute declared steps in one app run")
    func pipelineActionsExecuteDeclaredStepsInOneAppRun() throws {
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
            actionID: "exportPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.run.actionID == "exportPipeline")
        #expect(result.run.linkedArtifactPath?.hasSuffix("/.astra/apps/grocery-actions/exports/items.csv") == true)
        #expect(result.outputSummary.contains("Pipeline 'exportPipeline' completed 2 steps."))
        #expect(result.outputSummary.contains("listItems: Read 1 records from items."))
        #expect(result.outputSummary.contains("exportItems: Exported items.csv."))

        let events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == result.run.id }
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("listItems") })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
        #expect(events.contains { $0.type == "workspaceApp.artifact.exported" && $0.payload.contains("items.csv") })
    }

    @MainActor
    @Test("pipeline human approval gates block until confirmed")
    func pipelineHumanApprovalGatesBlockUntilConfirmed() throws {
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

        #expect(throws: WorkspaceAppActionExecutionError.approvalRequired("approvalGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "approvalPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                modelContext: fixture.context
            )
        }

        let blockedRun = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
            .first { $0.actionID == "approvalPipeline" })
        #expect(blockedRun.status == .blocked)
        #expect(blockedRun.linkedArtifactPath == nil)

        var blockedEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == blockedRun.id }
        #expect(blockedEvents.contains {
            $0.type == "workspaceApp.approval.requested" && $0.payload.contains("Approve exporting grocery data?")
        })
        #expect(!blockedEvents.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })

        let approvedResult = try WorkspaceAppActionExecutor().execute(
            actionID: "approvalPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(confirmedApproval: true),
            modelContext: fixture.context
        )

        #expect(approvedResult.run.status == .completed)
        #expect(approvedResult.outputSummary.contains("approvalGate: Approval gate 'approvalGate' confirmed."))
        #expect(approvedResult.outputSummary.contains("exportItems: Exported items.csv."))
        #expect(approvedResult.run.linkedArtifactPath?.contains("items.csv") == true)

        blockedEvents = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == approvedResult.run.id }
        #expect(blockedEvents.contains { $0.type == "workspaceApp.approval.confirmed" })
        #expect(blockedEvents.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("approvalGate") })
        #expect(blockedEvents.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
    }

    @MainActor
    @Test("pipeline expression gates block until input satisfies condition")
    func pipelineExpressionGatesBlockUntilInputSatisfiesCondition() throws {
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

        #expect(throws: WorkspaceAppActionExecutionError.gateBlocked("readyGate")) {
            try WorkspaceAppActionExecutor().execute(
                actionID: "readyPipeline",
                app: fixture.app,
                workspace: fixture.workspace,
                manifest: fixture.manifest,
                input: WorkspaceAppActionInput(record: ["status": .text("draft")]),
                modelContext: fixture.context
            )
        }

        let blockedRun = try #require(try fixture.context.fetch(FetchDescriptor<WorkspaceAppRun>())
            .first { $0.actionID == "readyPipeline" })
        #expect(blockedRun.status == .blocked)
        #expect(blockedRun.linkedArtifactPath == nil)

        var events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == blockedRun.id }
        #expect(events.contains {
            $0.type == "workspaceApp.gate.blocked" &&
                $0.payload.contains("\"field\":\"status\"") &&
                $0.payload.contains("\"actualValue\":\"draft\"") &&
                $0.payload.contains("\"expectedValue\":\"ready\"")
        })
        #expect(!events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })

        let passedResult = try WorkspaceAppActionExecutor().execute(
            actionID: "readyPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            input: WorkspaceAppActionInput(record: ["status": .text("ready")]),
            modelContext: fixture.context
        )

        #expect(passedResult.run.status == .completed)
        #expect(passedResult.outputSummary.contains("readyGate: Expression gate 'readyGate' passed."))
        #expect(passedResult.outputSummary.contains("exportItems: Exported items.csv."))
        #expect(passedResult.run.linkedArtifactPath?.contains("items.csv") == true)

        events = try fixture.context.fetch(FetchDescriptor<WorkspaceAppRunEvent>())
            .filter { $0.runID == passedResult.run.id }
        #expect(events.contains { $0.type == "workspaceApp.gate.passed" })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("readyGate") })
        #expect(events.contains { $0.type == "workspaceApp.pipeline.step.completed" && $0.payload.contains("exportItems") })
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
                ),
                WorkspaceAppRequirement(
                    id: "warehouse",
                    contract: "tabularQuery.read",
                    operations: ["runReadOnlyQuery"],
                    providerHint: "bigQuery"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "warehouseLatest",
                    requirementRef: "warehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    tableRef: "clinical.enrollment_candidates"
                )
            ],
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
                    operation: "queryRecords",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "updateItem",
                    type: "appStorage.update",
                    label: "Update Item",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "deleteItem",
                    type: "appStorage.delete",
                    label: "Delete Item",
                    table: "items"
                ),
                WorkspaceAppActionSpec(
                    id: "createReviewTask",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review grocery records",
                    taskGoal: "Review the grocery records and propose the next shopping task."
                ),
                WorkspaceAppActionSpec(
                    id: "runReviewTask",
                    type: "task.createAndRun",
                    label: "Run Review Task",
                    taskTitle: "Run grocery review",
                    taskGoal: "Run the grocery review workflow and summarize the required follow-up."
                ),
                WorkspaceAppActionSpec(
                    id: "readWarehouse",
                    type: "capability.read",
                    label: "Read Warehouse",
                    requirementRef: "warehouse",
                    operation: "runReadOnlyQuery",
                    sourceRef: "warehouseLatest"
                ),
                WorkspaceAppActionSpec(
                    id: "exportItems",
                    type: "artifact.export",
                    label: "Export Items",
                    table: "items",
                    exportFormat: "csv"
                ),
                WorkspaceAppActionSpec(
                    id: "exportPipeline",
                    type: "pipeline.run",
                    label: "Export Pipeline",
                    steps: ["listItems", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "approvalGate",
                    type: "gate.humanApproval",
                    label: "Approve Export",
                    approvalPrompt: "Approve exporting grocery data?",
                    approvalDecisions: ["approve", "reject"]
                ),
                WorkspaceAppActionSpec(
                    id: "approvalPipeline",
                    type: "pipeline.run",
                    label: "Approval Pipeline",
                    steps: ["approvalGate", "exportItems"]
                ),
                WorkspaceAppActionSpec(
                    id: "readyGate",
                    type: "gate.expression",
                    label: "Ready Gate",
                    gateField: "status",
                    gateOperator: "equals",
                    gateValue: .text("ready")
                ),
                WorkspaceAppActionSpec(
                    id: "readyPipeline",
                    type: "pipeline.run",
                    label: "Ready Pipeline",
                    steps: ["readyGate", "exportItems"]
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

private struct MockWorkspaceAppCapabilitySourceClient: WorkspaceAppCapabilitySourceClient {
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
