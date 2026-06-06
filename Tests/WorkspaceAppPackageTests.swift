import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Packages")
struct WorkspaceAppPackageTests {
    @Test("template export writes portable package files and checksums")
    func templateExportWritesPortablePackageFilesAndChecksums() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)

        let exportedURL = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(exportedURL == packageURL)
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/schema.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("checksums.json").path))
        #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/data/full").path))

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)
        #expect(report.canInstall)
        #expect(report.package?.packageID == "grocery-template")
        #expect(report.package?.version == "1.2.3")
        #expect(report.package?.requiredContracts.map(\.contract) == ["appStorage.records"])
        #expect(report.installState == .needsPermissionReview)
    }

    @Test("package validation blocks checksum tampering")
    func packageValidationBlocksChecksumTampering() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        try Data(#"{"tampered":true}"#.utf8).write(to: manifestURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/checksums.json/manifest.json" && $0.message.contains("Checksum")
        })
    }

    @Test("package validation blocks credential and absolute path content")
    func packageValidationBlocksCredentialAndAbsolutePathContent() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unsafe.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let unsafeURL = packageURL.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("unsafe.json")
        try FileManager.default.createDirectory(at: unsafeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"api_key":"abc","path":"/Users/alvaro1/private.csv"}"#.utf8)
            .write(to: unsafeURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.path == "/assets/unsafe.json" && $0.message.contains("credential") })
        #expect(report.blockers.contains { $0.path == "/assets/unsafe.json" && $0.message.contains("absolute local path") })
    }

    @Test("package validation marks missing required contracts for dependency mapping")
    func packageValidationMarksMissingRequiredContractsForDependencyMapping() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unmapped.astra-app", isDirectory: true)
        var manifest = Self.groceryManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "customRegistry",
                contract: "customRegistry.read",
                operations: ["readRecords"]
            )
        ]
        manifest.sources[0].requirementRef = "customRegistry"
        manifest.actions[0].requirementRef = "customRegistry"
        _ = try WorkspaceAppPackageService().exportPackage(manifest: manifest, to: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
        #expect(report.installState == .needsDependencyMapping)
    }

    @Test("package import review exposes identity dependencies permissions and storage")
    func packageImportReviewExposesPackageInspectionFields() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.canInstall)
        #expect(review.packageName == "Grocery Tracker")
        #expect(review.packageID == "grocery-template")
        #expect(review.version == "1.2.3")
        #expect(review.permissionMode == .draftOnly)
        #expect(review.requiredDependencies.map(\.contract) == ["appStorage.records"])
        #expect(review.storageTables.map(\.name) == ["items"])
        #expect(review.dependencyMappings.count == 1)
        #expect(review.dependencyMappings[0].isMapped)
        #expect(review.dependencyMappings[0].selectedImplementation?.id == "app-storage-native")
        #expect(review.dependencyMappings[0].familyName == "App Storage Records")
    }

    @Test("package import review marks required unmapped dependencies")
    func packageImportReviewMarksRequiredUnmappedDependencies() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unmapped.astra-app", isDirectory: true)
        var manifest = Self.groceryManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "customRegistry",
                contract: "customRegistry.read",
                operations: ["readRecords"]
            )
        ]
        manifest.sources[0].requirementRef = "customRegistry"
        manifest.actions[0].requirementRef = "customRegistry"
        _ = try WorkspaceAppPackageService().exportPackage(manifest: manifest, to: packageURL)

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.report.installState == .needsDependencyMapping)
        #expect(review.hasUnresolvedRequiredDependencies)
        #expect(review.dependencyMappings.count == 1)
        #expect(!review.dependencyMappings[0].isMapped)
        #expect(review.dependencyMappings[0].statusLabel == "Needs mapping")
        #expect(review.dependencyMappings[0].candidateImplementations.isEmpty)
    }

    @MainActor
    @Test("package import installs forked app with package provenance")
    func packageImportInstallsForkedAppWithPackageProvenance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let result = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        #expect(result.app.sourcePackageID == "grocery-template")
        #expect(result.app.sourcePackageVersion == "1.2.3")
        #expect(result.app.sourcePackageDigest?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: "grocery-tracker"
        )))
    }

    @MainActor
    @Test("package import assigns unique logical IDs for repeated installs")
    func packageImportAssignsUniqueLogicalIDsForRepeatedInstalls() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let first = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )
        let second = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        #expect(first.app.logicalID == "grocery-tracker")
        #expect(second.app.logicalID == "grocery-tracker-2")
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: "grocery-tracker-2"
        )))
    }

    @MainActor
    @Test("package exporter writes workspace-local portable exports without overwriting")
    func packageExporterWritesWorkspaceLocalPortableExportsWithoutOverwriting() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspace = Workspace(name: "Package Export", primaryPath: root.path)
        container.mainContext.insert(workspace)
        let created = try WorkspaceAppService().createApp(
            manifest: Self.groceryManifest(),
            in: workspace,
            modelContext: container.mainContext,
            status: .published
        )
        let exporter = WorkspaceAppPackageExporter()

        let first = try exporter.exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = try exporter.exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_001)
        )

        #expect(first.packageURL.deletingLastPathComponent().path == WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspace.primaryPath))
        #expect(first.packageURL.lastPathComponent == "grocery-tracker.astra-app")
        #expect(second.packageURL.lastPathComponent == "grocery-tracker-2.astra-app")
        #expect(first.validationReport.canInstall)
        #expect(FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("checksums.json").path))
        #expect(!FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("storage/data/full").path))
    }

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func groceryManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-tracker",
                name: "Grocery Tracker",
                icon: "cart",
                description: "Track grocery inventory and shopping lists.",
                tags: ["local", "grocery"],
                archetypes: ["localDatabase"]
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
            sources: [
                WorkspaceAppSource(
                    id: "items",
                    requirementRef: "localRecords",
                    operation: "queryRecords",
                    sourceRef: "items"
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
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: .draftOnly
            )
        )
    }
}
