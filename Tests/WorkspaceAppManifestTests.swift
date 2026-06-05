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
                WorkspaceAppViewSpec(id: "dashboard", type: "dashboard", title: "Enrollment Reconciliation")
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
