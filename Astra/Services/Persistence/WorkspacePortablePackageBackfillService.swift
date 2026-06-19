import Foundation
import SwiftData

enum WorkspacePortablePackageBackfillService {
    static let completedBackfillVersion = "workspace-config-v\(WorkspaceConfigManager.currentVersion)-portable-package-v1"

    struct BackfillResult: Sendable {
        enum Status: String, Sendable {
            case backfilled
            case skippedAlreadyCompleted
            case skippedAutoExportDisabled
            case fetchFailed
        }

        var status: Status
        var workspaceCount: Int
        var exportedCount: Int
        var skippedUnavailableCount: Int
        var skippedNoConfigCount: Int
        var failedCount: Int
        var completedVersion: String?

        var didRun: Bool {
            status == .backfilled
        }

        var didComplete: Bool {
            status == .backfilled && failedCount == 0
        }

        var auditFields: [String: String] {
            var fields: [String: String] = [
                "operation": "portable_package_backfill",
                "result": status.rawValue,
                "workspace_count": String(workspaceCount),
                "exported_count": String(exportedCount),
                "skipped_unavailable_count": String(skippedUnavailableCount),
                "skipped_no_config_count": String(skippedNoConfigCount),
                "failed_count": String(failedCount),
                "backfill_version": WorkspacePortablePackageBackfillService.completedBackfillVersion
            ]
            if let completedVersion {
                fields["completed_version"] = completedVersion
            }
            return fields
        }
    }

    @MainActor
    static func schedule(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        Task { @MainActor in
            _ = backfillIfNeeded(modelContext: modelContext, defaults: defaults)
        }
    }

    @MainActor
    @discardableResult
    static func backfillIfNeeded(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        skipAutoExport: Bool = WorkspacePersistenceCoordinator.shouldSkipAutoExport()
    ) -> BackfillResult {
        guard !skipAutoExport else {
            let result = BackfillResult(
                status: .skippedAutoExportDisabled,
                workspaceCount: 0,
                exportedCount: 0,
                skippedUnavailableCount: 0,
                skippedNoConfigCount: 0,
                failedCount: 0,
                completedVersion: defaults.string(forKey: AppStorageKeys.completedWorkspacePortablePackageBackfillVersion)
            )
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: result.auditFields, level: .debug)
            return result
        }

        let storedVersion = defaults.string(forKey: AppStorageKeys.completedWorkspacePortablePackageBackfillVersion)
        guard storedVersion != completedBackfillVersion else {
            let result = BackfillResult(
                status: .skippedAlreadyCompleted,
                workspaceCount: 0,
                exportedCount: 0,
                skippedUnavailableCount: 0,
                skippedNoConfigCount: 0,
                failedCount: 0,
                completedVersion: storedVersion
            )
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: result.auditFields, level: .debug)
            return result
        }

        var result = backfillNow(modelContext: modelContext)
        if result.failedCount == 0 {
            defaults.set(completedBackfillVersion, forKey: AppStorageKeys.completedWorkspacePortablePackageBackfillVersion)
            result.completedVersion = completedBackfillVersion
        }
        AppLogger.audit(
            .workspaceExported,
            category: "Persistence",
            fields: result.auditFields,
            level: result.failedCount == 0 ? .info : .warning
        )
        return result
    }

    @MainActor
    @discardableResult
    static func backfillNow(modelContext: ModelContext) -> BackfillResult {
        let workspaces: [Workspace]
        do {
            workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        } catch {
            let result = BackfillResult(
                status: .fetchFailed,
                workspaceCount: 0,
                exportedCount: 0,
                skippedUnavailableCount: 0,
                skippedNoConfigCount: 0,
                failedCount: 1,
                completedVersion: nil
            )
            var fields = result.auditFields
            fields["stage"] = "fetch_workspaces"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: fields, level: .error)
            return result
        }

        var exportedCount = 0
        var skippedUnavailableCount = 0
        var skippedNoConfigCount = 0
        var failedCount = 0

        for workspace in workspaces {
            let target = WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath)
            guard let url = target.url else {
                skippedUnavailableCount += 1
                AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
                    "operation": "portable_package_backfill",
                    "result": "skipped",
                    "reason": target.reason,
                    "workspace_id": workspace.id.uuidString
                ], level: .debug)
                continue
            }

            let exportResult = WorkspaceConfigManager.exportToFileResult(
                workspace: workspace,
                modelContext: modelContext,
                url: url
            )
            switch exportResult.status {
            case .exported:
                exportedCount += 1
            case .skippedNoConfig:
                skippedNoConfigCount += 1
            case .writeFailed:
                failedCount += 1
                var fields = exportResult.auditFields
                fields["operation"] = "portable_package_backfill"
                AppLogger.audit(.workspaceExported, category: "Persistence", fields: fields, level: .error)
            }
        }

        return BackfillResult(
            status: .backfilled,
            workspaceCount: workspaces.count,
            exportedCount: exportedCount,
            skippedUnavailableCount: skippedUnavailableCount,
            skippedNoConfigCount: skippedNoConfigCount,
            failedCount: failedCount,
            completedVersion: nil
        )
    }
}
