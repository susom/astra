import CryptoKit
import Foundation
import SwiftData

enum WorkspaceAppServiceError: LocalizedError, Equatable {
    case invalidManifest([WorkspaceAppManifestValidationReport.Issue])
    case emptyWorkspacePath
    case encodeFailed(String)
    case storageFailed(String)
    case missingDependencyBinding(String)
    case missingAutomation(String)
    case missingContractImplementation(String)
    case incompatibleContractImplementation(requirementID: String, implementationID: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app manifest is invalid.\n\(messages)"
        case .emptyWorkspacePath:
            return "Workspace path is empty."
        case .encodeFailed(let message):
            return "Could not encode workspace app manifest: \(message)"
        case .storageFailed(let message):
            return "Could not initialize workspace app storage: \(message)"
        case .missingDependencyBinding(let requirementID):
            return "Workspace app dependency requirement '\(requirementID)' was not found."
        case .missingAutomation(let automationID):
            return "Workspace app automation '\(automationID)' was not found."
        case .missingContractImplementation(let implementationID):
            return "Workspace app contract implementation '\(implementationID)' was not found."
        case .incompatibleContractImplementation(let requirementID, let implementationID):
            return "Contract implementation '\(implementationID)' does not satisfy requirement '\(requirementID)'."
        }
    }
}

struct WorkspaceAppCreationResult {
    var app: WorkspaceApp
    var manifestURL: URL
}

struct WorkspaceAppService {
    var fileManager: FileManager = .default
    var storageService = WorkspaceAppStorageService()
    var contractRegistry = WorkspaceAppContractRegistry()

    @MainActor
    func createApp(
        manifest: WorkspaceAppManifest,
        in workspace: Workspace,
        modelContext: ModelContext,
        status: WorkspaceAppLifecycleStatus = .draft,
        sourcePackageID: String? = nil,
        sourcePackageVersion: String? = nil,
        sourcePackageDigest: String? = nil
    ) throws -> WorkspaceAppCreationResult {
        let report = WorkspaceAppManifestValidator.validate(manifest)
        guard report.isValid else {
            throw WorkspaceAppServiceError.invalidManifest(report.blockers)
        }
        guard !workspace.primaryPath.isEmpty else {
            throw WorkspaceAppServiceError.emptyWorkspacePath
        }

        let appID = manifest.app.id
        let dataDirectory = WorkspaceFileLayout.appDataDirectory(workspacePath: workspace.primaryPath, appID: appID)
        let manifestPath = WorkspaceFileLayout.appManifestFile(workspacePath: workspace.primaryPath, appID: appID)
        let databasePath = WorkspaceFileLayout.appDatabaseFile(workspacePath: workspace.primaryPath, appID: appID)
        try fileManager.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

        let manifestData: Data
        do {
            manifestData = try Self.encodeManifest(manifest)
        } catch {
            throw WorkspaceAppServiceError.encodeFailed(String(describing: error))
        }
        try manifestData.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
        if let storage = manifest.storage {
            do {
                try storageService.applySchema(storage, databaseURL: URL(fileURLWithPath: databasePath))
            } catch {
                throw WorkspaceAppServiceError.storageFailed(String(describing: error))
            }
        }

        let now = Date()
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: appID,
            name: manifest.app.name,
            icon: manifest.app.icon,
            appDescription: manifest.app.description,
            lifecycleStatus: status,
            permissionMode: manifest.permissions.defaultMode,
            dependencyStatus: .ready,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: appID),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: appID),
            manifestDigest: Self.digest(for: manifestData),
            sourcePackageID: sourcePackageID,
            sourcePackageVersion: sourcePackageVersion,
            sourcePackageDigest: sourcePackageDigest,
            createdAt: now,
            updatedAt: now
        )
        let bindings = dependencyBindings(
            for: manifest.requirements,
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: appID,
            now: now
        )
        let automations = automationStates(
            for: manifest.automations,
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: appID,
            now: now
        )
        app.dependencyStatus = dependencyStatus(for: bindings)
        modelContext.insert(app)
        for binding in bindings {
            modelContext.insert(binding)
        }
        for automation in automations {
            modelContext.insert(automation)
        }
        workspace.updatedAt = now
        try modelContext.save()

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_manifest",
            "result": "created",
            "workspace_id": workspace.id.uuidString,
            "app_id": appID,
            "manifest": URL(fileURLWithPath: manifestPath).lastPathComponent
        ])

        return WorkspaceAppCreationResult(app: app, manifestURL: URL(fileURLWithPath: manifestPath))
    }

    private func dependencyBindings(
        for requirements: [WorkspaceAppRequirement],
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        now: Date
    ) -> [WorkspaceAppDependencyBinding] {
        contractRegistry.resolveAll(requirements).map { resolution in
            let selected = resolution.selectedImplementation
            return WorkspaceAppDependencyBinding(
                workspaceID: workspaceID,
                appID: appID,
                appLogicalID: appLogicalID,
                requirementID: resolution.requirement.id,
                contract: resolution.requirement.contract,
                operations: resolution.requirement.operations,
                optional: resolution.requirement.optional,
                status: bindingStatus(for: resolution),
                implementationID: selected?.id,
                provider: selected?.provider,
                transport: selected?.transport,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private func automationStates(
        for automations: [WorkspaceAppAutomationSpec],
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        now: Date
    ) -> [WorkspaceAppAutomationState] {
        automations.map { automation in
            WorkspaceAppAutomationState(
                workspaceID: workspaceID,
                appID: appID,
                appLogicalID: appLogicalID,
                automationID: automation.id,
                automationType: automation.type,
                actionID: automation.action,
                isEnabled: false,
                status: .disabled,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private func bindingStatus(
        for resolution: WorkspaceAppContractResolution
    ) -> WorkspaceAppDependencyBindingStatus {
        if resolution.selectedImplementation != nil {
            return .mapped
        }
        return resolution.requirement.optional ? .optionalMissing : .missingRequired
    }

    private func dependencyStatus(
        for bindings: [WorkspaceAppDependencyBinding]
    ) -> WorkspaceAppDependencyStatus {
        guard !bindings.isEmpty else { return .ready }
        if bindings.contains(where: { $0.status == .missingRequired }) {
            return .missingRequired
        }
        return .ready
    }

    @MainActor
    func openApp(
        _ app: WorkspaceApp,
        in workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        app.lastOpenedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app",
            "result": "opened",
            "app_id": app.logicalID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func refreshApp(
        _ app: WorkspaceApp,
        in workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        app.lastRefreshedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app",
            "result": "refreshed",
            "app_id": app.logicalID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func dependencyBindings(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppDependencyBinding] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate<WorkspaceAppDependencyBinding> { binding in
                binding.appID == appID
            },
            sortBy: [SortDescriptor(\.requirementID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    func remapDependencyBinding(
        app: WorkspaceApp,
        requirementID: String,
        implementationID: String?,
        workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        let bindings = try dependencyBindings(for: app, modelContext: modelContext)
        guard let binding = bindings.first(where: { $0.requirementID == requirementID }) else {
            throw WorkspaceAppServiceError.missingDependencyBinding(requirementID)
        }

        if let implementationID {
            guard let implementation = contractRegistry.implementation(id: implementationID) else {
                throw WorkspaceAppServiceError.missingContractImplementation(implementationID)
            }
            guard contractRegistry.satisfies(binding: binding, implementation: implementation) else {
                throw WorkspaceAppServiceError.incompatibleContractImplementation(
                    requirementID: requirementID,
                    implementationID: implementationID
                )
            }
            binding.status = .mapped
            binding.implementationID = implementation.id
            binding.provider = implementation.provider
            binding.transport = implementation.transport
        } else {
            binding.status = binding.optional ? .optionalMissing : .missingRequired
            binding.implementationID = nil
            binding.provider = nil
            binding.transport = nil
        }

        binding.updatedAt = now
        app.dependencyStatus = dependencyStatus(for: bindings)
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_dependency_binding",
            "result": "remapped",
            "app_id": app.logicalID,
            "requirement_id": requirementID,
            "implementation_id": implementationID ?? "none",
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func automationStates(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppAutomationState] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate<WorkspaceAppAutomationState> { automation in
                automation.appID == appID
            },
            sortBy: [SortDescriptor(\.automationID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    func setAutomationEnabled(
        app: WorkspaceApp,
        automationID: String,
        isEnabled: Bool,
        workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        let states = try automationStates(for: app, modelContext: modelContext)
        guard let automation = states.first(where: { $0.automationID == automationID }) else {
            throw WorkspaceAppServiceError.missingAutomation(automationID)
        }

        automation.isEnabled = isEnabled
        automation.status = isEnabled ? .enabled : .disabled
        automation.updatedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_automation_state",
            "result": isEnabled ? "enabled" : "disabled",
            "app_id": app.logicalID,
            "automation_id": automationID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    nonisolated static func encodeManifest(_ manifest: WorkspaceAppManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    nonisolated static func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
