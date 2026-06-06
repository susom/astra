import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Manifest")
struct WorkspaceAppManifestTests {
    @Test("valid manifest passes validation")
    func validManifestPassesValidation() {
        let report = WorkspaceAppManifestValidator.validate(Self.reconciliationManifest())

        #expect(report.isValid)
        #expect(report.blockers.isEmpty)
    }

    @Test("manifest validation rejects duplicate IDs and unknown requirement references")
    func validationRejectsDuplicateIDsAndUnknownRequirementRefs() {
        var manifest = Self.reconciliationManifest()
        manifest.requirements.append(manifest.requirements[0])
        manifest.sources.append(WorkspaceAppSource(
            id: "orphan_source",
            requirementRef: "missingRequirement",
            operation: "runReadOnlyQuery"
        ))

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/requirements/2/id" && $0.message.contains("duplicated")
        })
        #expect(report.blockers.contains {
            $0.path == "/sources/2/requirementRef" && $0.message.contains("unknown requirement")
        })
    }

    @Test("manifest validation blocks automations that default enabled")
    func validationBlocksEnabledAutomationDefaults() {
        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "daily_refresh",
                type: "schedule",
                enabledByDefault: true,
                action: "refresh"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/automations/0/enabledByDefault"
        })
    }

    @Test("manifest validation rejects view widgets bound to unknown storage")
    func validationRejectsUnknownViewWidgetStorageBindings() {
        var manifest = Self.reconciliationManifest()
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "dashboard",
                type: "dashboard",
                title: "Dashboard",
                table: "missing_table",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "missing_metric",
                        type: "metric",
                        label: "Missing",
                        table: "review_items",
                        field: "missing_field",
                        aggregation: "sum"
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/table" && $0.message.contains("missing_table")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/field" && $0.message.contains("missing_field")
        })
    }

    @Test("manifest validation restricts WebView widgets")
    func validationRestrictsWebViewWidgets() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(id: "export_missing", type: "artifact.export", table: "review_items")
        ]
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "diagram",
                type: "dashboard",
                title: "Diagram",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "unsafe_widget",
                        type: "webView",
                        label: "Unsafe",
                        webRenderer: "customJavaScript",
                        allowedActions: ["missing_action"],
                        requiredAssets: ["/Users/alvaro/private.js"]
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/webRenderer" && $0.message.contains("not allowed")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/allowedActions/0" && $0.message.contains("unknown action")
        })
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/requiredAssets/0" && $0.message.contains("portable")
        })
    }

    @Test("manifest validation rejects empty markdown widgets")
    func validationRejectsEmptyMarkdownWidgets() {
        var manifest = Self.reconciliationManifest()
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "overview",
                type: "dashboard",
                title: "Overview",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "instructions",
                        type: "markdown",
                        label: "Instructions",
                        markdownContent: "   "
                    )
                ]
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/markdownContent" && $0.message.contains("Markdown widget content")
        })
    }


    @Test("WebView bridge only accepts declared widget action requests")
    func webViewBridgeOnlyAcceptsDeclaredWidgetActions() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(id: "export_missing", type: "artifact.export", table: "review_items"),
            WorkspaceAppActionSpec(id: "create_review", type: "task.createDraft", taskGoal: "Review missing records.")
        ]
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "diagram",
                type: "dashboard",
                title: "Diagram",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "reconciliation_flow",
                        type: "webView",
                        label: "Flow",
                        webRenderer: "mermaidDiagram",
                        allowedActions: ["export_missing"],
                        requiredAssets: ["web/reconciliation.mmd"]
                    )
                ]
            )
        ]

        let allowed = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "reconciliation_flow", actionID: "export_missing"),
            manifest: manifest
        )
        let blockedAction = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "reconciliation_flow", actionID: "create_review"),
            manifest: manifest
        )
        let blockedWidget = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "missing_widget", actionID: "export_missing"),
            manifest: manifest
        )

        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(allowed.isAllowed)
        #expect(allowed.action?.id == "export_missing")
        #expect(!blockedAction.isAllowed)
        #expect(blockedAction.issue?.message.contains("not allowed") == true)
        #expect(!blockedWidget.isAllowed)
        #expect(blockedWidget.issue?.message.contains("Unknown WebView widget") == true)
    }

    @Test("manifest validation rejects task actions without a goal")
    func validationRejectsTaskActionsWithoutGoal() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "create_review",
                type: "task.createDraft",
                label: "Create Review Task"
            ),
            WorkspaceAppActionSpec(
                id: "run_review",
                type: "task.createAndRun",
                label: "Run Review Task"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/taskGoal" && $0.message.contains("task goal")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/taskGoal" && $0.message.contains("task goal")
        })
    }

    @Test("manifest validation rejects human approval gates without prompts or decisions")
    func validationRejectsInvalidHumanApprovalGates() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "approval_gate",
                type: "gate.humanApproval",
                label: "Approval"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/approvalPrompt" && $0.message.contains("approval prompt")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/approvalDecisions" && $0.message.contains("available decisions")
        })
    }

    @Test("manifest validation rejects invalid expression gates")
    func validationRejectsInvalidExpressionGates() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "expression_gate",
                type: "gate.expression",
                label: "Ready Gate",
                gateOperator: "around"
            ),
            WorkspaceAppActionSpec(
                id: "threshold_gate",
                type: "gate.expression",
                label: "Threshold Gate",
                gateField: "score",
                gateOperator: "greaterThan"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateField" && $0.message.contains("field")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/gateOperator" && $0.message.contains("not supported")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/gateValue" && $0.message.contains("comparison value")
        })
    }

    @Test("manifest validation rejects invalid pipeline step references")
    func validationRejectsInvalidPipelineStepReferences() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(id: "refresh", type: "pipeline.run", label: "Refresh", steps: ["refresh", "missing"]),
            WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List", table: "review_items")
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/steps/0" && $0.message.contains("cannot include itself")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/steps/1" && $0.message.contains("unknown action")
        })
    }

    @Test("manifest decoding keeps legacy actions without pipeline steps compatible")
    func manifestDecodingKeepsLegacyActionsWithoutPipelineStepsCompatible() throws {
        let json = """
        {
          "schemaVersion": 1,
          "app": {"id": "legacy", "name": "Legacy", "icon": "square.grid.2x2", "description": "", "tags": [], "archetypes": []},
          "requirements": [],
          "storage": null,
          "sources": [],
          "views": [],
          "actions": [
            {"id": "legacy_action", "type": "task.createDraft", "label": "Create", "taskGoal": "Do work"}
          ],
          "automations": [],
          "permissions": {"reads": [], "writes": [], "externalWrites": [], "defaultMode": "draftOnly"}
        }
        """

        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))

        #expect(manifest.actions.count == 1)
        #expect(manifest.actions[0].steps.isEmpty)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("manifest validation rejects artifact exports with unknown table or format")
    func validationRejectsInvalidArtifactExportBindings() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "export_missing",
                type: "artifact.export",
                label: "Export",
                table: "missing_table",
                exportFormat: "xlsx"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/table" && $0.message.contains("missing_table")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/0/exportFormat" && $0.message.contains("csv or json")
        })
    }

    @Test("manifest validation rejects storage actions with unknown tables")
    func validationRejectsStorageActionsWithUnknownTables() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "update_missing",
                type: "appStorage.update",
                label: "Update",
                table: "missing_table"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/table" && $0.message.contains("missing_table")
        })
    }

    @Test("manifest validation rejects capability reads without declared sources")
    func validationRejectsCapabilityReadsWithoutDeclaredSources() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "read_missing_source",
                type: "capability.read",
                label: "Read Missing"
            ),
            WorkspaceAppActionSpec(
                id: "read_unknown_source",
                type: "capability.read",
                label: "Read Unknown",
                sourceRef: "unknown_source"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/sourceRef" && $0.message.contains("source reference")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/sourceRef" && $0.message.contains("unknown_source")
        })
    }

    @Test("manifest validation rejects capability writes without requirement or operation")
    func validationRejectsCapabilityWritesWithoutRequirementOrOperation() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "write_missing_requirement",
                type: "capability.write",
                label: "Write Missing",
                operation: "submitCreate"
            ),
            WorkspaceAppActionSpec(
                id: "write_missing_operation",
                type: "capability.write",
                label: "Write Missing Operation",
                requirementRef: "targetRecords"
            ),
            WorkspaceAppActionSpec(
                id: "write_unknown_requirement",
                type: "capability.write",
                label: "Write Unknown",
                requirementRef: "unknownWrite",
                operation: "submitCreate"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/requirementRef" && $0.message.contains("requirement reference")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/1/operation" && $0.message.contains("operation")
        })
        #expect(report.blockers.contains {
            $0.path == "/actions/2/requirementRef" && $0.message.contains("unknownWrite")
        })
    }

    @Test("manifest encoding preserves native widget specs")
    func manifestEncodingPreservesNativeWidgetSpecs() throws {
        var manifest = Self.reconciliationManifest()
        manifest.views[0].widgets.append(WorkspaceAppWidgetSpec(
            id: "review_notes",
            type: "markdown",
            label: "Review notes",
            markdownContent: "**Check** missing records before export."
        ))
        let data = try WorkspaceAppService.encodeManifest(manifest)
        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        let view = try #require(decoded.views.first)
        let widget = try #require(view.widgets.first)
        let markdown = try #require(view.widgets.last)

        #expect(view.table == "review_items")
        #expect(widget.id == "review_count")
        #expect(widget.type == "metric")
        #expect(widget.table == nil)
        #expect(widget.aggregation == "count")
        #expect(markdown.id == "review_notes")
        #expect(markdown.type == "markdown")
        #expect(markdown.markdownContent == "**Check** missing records before export.")
    }

    @Test("manifest decoding keeps legacy view specs without widgets compatible")
    func manifestDecodingKeepsLegacyViewSpecsCompatible() throws {
        let json = """
        {
          "schemaVersion": 1,
          "app": {
            "id": "legacy-app",
            "name": "Legacy App",
            "icon": "square.grid.2x2",
            "description": "",
            "tags": [],
            "archetypes": []
          },
          "requirements": [],
          "sources": [],
          "views": [
            {"id": "dashboard", "type": "dashboard", "title": "Dashboard"}
          ],
          "actions": [],
          "automations": [],
          "permissions": {
            "reads": [],
            "writes": [],
            "externalWrites": [],
            "defaultMode": "readOnly"
          }
        }
        """

        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))

        #expect(manifest.views.count == 1)
        #expect(manifest.views[0].table == nil)
        #expect(manifest.views[0].widgets.isEmpty)
    }

    @Test("manifest encoding is stable enough for digest checks")
    func manifestEncodingIsStable() throws {
        let manifest = Self.reconciliationManifest()
        let first = try WorkspaceAppService.encodeManifest(manifest)
        let second = try WorkspaceAppService.encodeManifest(manifest)

        #expect(first == second)
        #expect(WorkspaceAppService.digest(for: first) == WorkspaceAppService.digest(for: second))
    }

    @MainActor
    @Test("service writes canonical manifest and SwiftData index")
    func serviceWritesCanonicalManifestAndSwiftDataIndex() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "hourly-refresh",
                type: "schedule",
                enabledByDefault: false,
                action: "refresh"
            )
        ]
        let result = try WorkspaceAppService().createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))

        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(result.app.logicalID == "enrollment-reconciliation")
        #expect(result.app.name == "Enrollment Reconciliation")
        #expect(result.app.manifestRelativePath == ".astra/apps/enrollment-reconciliation/manifest.json")
        #expect(result.app.appDirectoryRelativePath == ".astra/apps/enrollment-reconciliation")
        #expect(result.app.permissionMode == .readOnly)
        #expect(result.app.dependencyStatus == .ready)

        let data = try Data(contentsOf: result.manifestURL)
        #expect(result.app.manifestDigest == WorkspaceAppService.digest(for: data))

        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        #expect(decoded == manifest)

        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps[0].workspaceID == workspace.id)

        let bindings = try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>())
            .sorted { $0.requirementID < $1.requirementID }
        #expect(bindings.count == 2)
        #expect(bindings[0].appID == result.app.id)
        #expect(bindings[0].appLogicalID == "enrollment-reconciliation")
        #expect(bindings[0].requirementID == "sourceWarehouse")
        #expect(bindings[0].contract == "tabularQuery.read")
        #expect(bindings[0].operations == ["describeTable", "runReadOnlyQuery"])
        #expect(bindings[0].status == .mapped)
        #expect(bindings[0].implementationID == "bigquery-read-task-backed")
        #expect(bindings[0].provider == "bigQuery")
        #expect(bindings[0].transport == .taskBacked)
        #expect(bindings[1].requirementID == "targetRecords")
        #expect(bindings[1].status == .mapped)
        #expect(bindings[1].implementationID == "redcap-read-task-backed")

        let automations = try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>())
        #expect(automations.count == 1)
        #expect(automations[0].appID == result.app.id)
        #expect(automations[0].appLogicalID == "enrollment-reconciliation")
        #expect(automations[0].automationID == "hourly-refresh")
        #expect(automations[0].automationType == "schedule")
        #expect(automations[0].actionID == "refresh")
        #expect(automations[0].isEnabled == false)
        #expect(automations[0].status == .disabled)
    }

    @MainActor
    @Test("service marks apps missing required dependencies when no compatible contract implementation exists")
    func serviceMarksAppsMissingRequiredDependencies() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-missing-dependency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let result = try WorkspaceAppService(
            contractRegistry: WorkspaceAppContractRegistry(implementations: [])
        ).createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )

        #expect(result.app.dependencyStatus == .missingRequired)
        let bindings = try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>())
        #expect(bindings.count == 2)
        #expect(bindings.allSatisfy { $0.status == .missingRequired })
        #expect(bindings.allSatisfy { $0.implementationID == nil })
    }

    @MainActor
    @Test("service remaps dependency bindings without editing the app manifest")
    func serviceRemapsDependencyBindingsWithoutEditingManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-remap-dependency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let manifest = Self.reconciliationManifest()
        let creatingService = WorkspaceAppService(
            contractRegistry: WorkspaceAppContractRegistry(implementations: [])
        )
        let result = try creatingService.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let originalManifestData = try Data(contentsOf: result.manifestURL)

        let remappingService = WorkspaceAppService()
        #expect(throws: WorkspaceAppServiceError.incompatibleContractImplementation(
            requirementID: "sourceWarehouse",
            implementationID: "redcap-read-task-backed"
        )) {
            try remappingService.remapDependencyBinding(
                app: result.app,
                requirementID: "sourceWarehouse",
                implementationID: "redcap-read-task-backed",
                workspace: workspace,
                modelContext: context
            )
        }

        try remappingService.remapDependencyBinding(
            app: result.app,
            requirementID: "sourceWarehouse",
            implementationID: "bigquery-read-task-backed",
            workspace: workspace,
            modelContext: context
        )
        #expect(result.app.dependencyStatus == .missingRequired)

        try remappingService.remapDependencyBinding(
            app: result.app,
            requirementID: "targetRecords",
            implementationID: "redcap-read-task-backed",
            workspace: workspace,
            modelContext: context
        )
        #expect(result.app.dependencyStatus == .ready)
        #expect(try Data(contentsOf: result.manifestURL) == originalManifestData)

        let bindings = try remappingService.dependencyBindings(for: result.app, modelContext: context)
        #expect(bindings.count == 2)
        #expect(bindings.allSatisfy { $0.status == .mapped })
        #expect(bindings.first { $0.requirementID == "sourceWarehouse" }?.implementationID == "bigquery-read-task-backed")
        #expect(bindings.first { $0.requirementID == "targetRecords" }?.implementationID == "redcap-read-task-backed")
    }

    @MainActor
    @Test("service enables automation state without editing the app manifest")
    func serviceEnablesAutomationStateWithoutEditingManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-enable-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        var manifest = Self.reconciliationManifest()
        manifest.automations = [
            WorkspaceAppAutomationSpec(
                id: "daily-refresh",
                type: "schedule",
                enabledByDefault: false,
                action: "refresh"
            )
        ]

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: context
        )
        let originalManifestData = try Data(contentsOf: result.manifestURL)
        let enabledAt = Date(timeIntervalSince1970: 1_800_000_000)

        try service.setAutomationEnabled(
            app: result.app,
            automationID: "daily-refresh",
            isEnabled: true,
            workspace: workspace,
            modelContext: context,
            now: enabledAt
        )

        let automations = try service.automationStates(for: result.app, modelContext: context)
        #expect(automations.count == 1)
        #expect(automations[0].isEnabled)
        #expect(automations[0].status == .enabled)
        #expect(automations[0].updatedAt == enabledAt)
        #expect(result.app.updatedAt == enabledAt)
        #expect(try Data(contentsOf: result.manifestURL) == originalManifestData)

        #expect(throws: WorkspaceAppServiceError.missingAutomation("missing")) {
            try service.setAutomationEnabled(
                app: result.app,
                automationID: "missing",
                isEnabled: true,
                workspace: workspace,
                modelContext: context
            )
        }
    }

    @MainActor
    @Test("service records app open and refresh lifecycle timestamps")
    func serviceRecordsAppOpenAndRefreshLifecycleTimestamps() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let service = WorkspaceAppService()
        let result = try service.createApp(
            manifest: Self.reconciliationManifest(),
            in: workspace,
            modelContext: context
        )
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshedAt = openedAt.addingTimeInterval(120)

        try service.openApp(result.app, in: workspace, modelContext: context, now: openedAt)
        try service.refreshApp(result.app, in: workspace, modelContext: context, now: refreshedAt)

        #expect(result.app.lastOpenedAt == openedAt)
        #expect(result.app.lastRefreshedAt == refreshedAt)
        #expect(result.app.updatedAt == refreshedAt)
        #expect(workspace.updatedAt >= openedAt)

        let fetched = try #require(try context.fetch(FetchDescriptor<WorkspaceApp>()).first)
        #expect(fetched.lastOpenedAt == openedAt)
        #expect(fetched.lastRefreshedAt == refreshedAt)
    }

    static func reconciliationManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "enrollment-reconciliation",
                name: "Enrollment Reconciliation",
                icon: "checklist.checked",
                description: "Compare warehouse records against REDCap."
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    minVersion: "1.0.0",
                    operations: ["describeTable", "runReadOnlyQuery"],
                    providerHint: "bigQuery",
                    dataClass: "sensitive"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    minVersion: "1.0.0",
                    operations: ["describeProject", "readRecords", "validateRecord"],
                    providerHint: "redcap",
                    dataClass: "sensitive"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "source_record_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "match_status", type: "text", required: true)
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "latest_candidates",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    query: "SELECT * FROM clinical.enrollment_candidates LIMIT 100"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    projectRef: "enrollment-study"
                )
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "dashboard",
                    type: "dashboard",
                    title: "Enrollment Reconciliation",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_count",
                            type: "metric",
                            label: "Review records",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "records_by_status",
                            type: "chart",
                            label: "Records by status",
                            groupBy: "match_status",
                            aggregation: "count"
                        )
                    ]
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "refresh", type: "pipeline", label: "Refresh")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["tabularQuery.read", "recordProject.read"],
                writes: ["appStorage.records"],
                defaultMode: .readOnly
            )
        )
    }
}
