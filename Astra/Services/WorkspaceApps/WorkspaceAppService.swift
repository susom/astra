import CryptoKit
import Foundation
import SwiftData

enum WorkspaceAppServiceError: LocalizedError, Equatable {
    case invalidManifest([WorkspaceAppManifestValidationReport.Issue])
    case emptyWorkspacePath
    case encodeFailed(String)
    case storageFailed(String)

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

    @MainActor
    func createApp(
        manifest: WorkspaceAppManifest,
        in workspace: Workspace,
        modelContext: ModelContext,
        status: WorkspaceAppLifecycleStatus = .draft
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
            dependencyStatus: manifest.requirements.isEmpty ? .ready : .unresolved,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: appID),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: appID),
            manifestDigest: Self.digest(for: manifestData),
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(app)
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

    nonisolated static func encodeManifest(_ manifest: WorkspaceAppManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    nonisolated static func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
