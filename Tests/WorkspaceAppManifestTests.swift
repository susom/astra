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

    @Test("manifest validation rejects task draft actions without a goal")
    func validationRejectsTaskDraftActionsWithoutGoal() {
        var manifest = Self.reconciliationManifest()
        manifest.actions = [
            WorkspaceAppActionSpec(
                id: "create_review",
                type: "task.createDraft",
                label: "Create Review Task"
            )
        ]

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/actions/0/taskGoal" && $0.message.contains("task goal")
        })
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

    @Test("manifest encoding preserves native widget specs")
    func manifestEncodingPreservesNativeWidgetSpecs() throws {
        let manifest = Self.reconciliationManifest()
        let data = try WorkspaceAppService.encodeManifest(manifest)
        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        let view = try #require(decoded.views.first)
        let widget = try #require(view.widgets.first)

        #expect(view.table == "review_items")
        #expect(widget.id == "review_count")
        #expect(widget.type == "metric")
        #expect(widget.table == nil)
        #expect(widget.aggregation == "count")
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

        let manifest = Self.reconciliationManifest()
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
        #expect(result.app.dependencyStatus == .unresolved)

        let data = try Data(contentsOf: result.manifestURL)
        #expect(result.app.manifestDigest == WorkspaceAppService.digest(for: data))

        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        #expect(decoded == manifest)

        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps[0].workspaceID == workspace.id)
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
