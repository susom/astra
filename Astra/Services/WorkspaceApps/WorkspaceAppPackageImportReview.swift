import Foundation

struct WorkspaceAppPackageImportReview: Identifiable, Equatable {
    var id = UUID()
    var packageURL: URL
    var report: WorkspaceAppPackageValidationReport

    var packageName: String {
        report.package?.appName ?? report.manifest?.app.name ?? packageURL.lastPathComponent
    }

    var packageID: String {
        report.package?.packageID ?? "Unknown package"
    }

    var version: String {
        report.package?.version ?? "Unknown version"
    }

    var minimumASTRAVersion: String {
        report.package?.minimumASTRAVersion ?? "Unknown"
    }

    var permissionMode: WorkspaceAppPermissionMode {
        report.manifest?.permissions.defaultMode ?? .readOnly
    }

    var requiredDependencies: [WorkspaceAppPackageContractRequirement] {
        report.package?.requiredContracts.filter { !$0.optional } ?? []
    }

    var optionalDependencies: [WorkspaceAppPackageContractRequirement] {
        report.package?.requiredContracts.filter(\.optional) ?? []
    }

    var storageTables: [WorkspaceAppStorageTable] {
        report.manifest?.storage?.tables ?? []
    }

    var automationCount: Int {
        report.manifest?.automations.count ?? 0
    }

    var canInstall: Bool {
        report.canInstall
    }
}

enum WorkspaceAppPackageImportReviewer {
    static func review(packageURL: URL, service: WorkspaceAppPackageService = WorkspaceAppPackageService()) -> WorkspaceAppPackageImportReview {
        WorkspaceAppPackageImportReview(
            packageURL: packageURL,
            report: service.validatePackage(at: packageURL)
        )
    }
}
