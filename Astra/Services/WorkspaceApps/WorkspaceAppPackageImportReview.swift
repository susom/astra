import Foundation

struct WorkspaceAppPackageDependencyMapping: Identifiable, Equatable {
    var id: String { requirement.id }
    var requirement: WorkspaceAppPackageContractRequirement
    var familyName: String
    var selectedImplementation: WorkspaceAppContractImplementation?
    var candidateImplementations: [WorkspaceAppContractImplementation]

    var isRequired: Bool {
        !requirement.optional
    }

    var isMapped: Bool {
        selectedImplementation != nil || requirement.optional
    }

    var statusLabel: String {
        if let selectedImplementation {
            return "Mapped to \(selectedImplementation.provider)"
        }
        return requirement.optional ? "Optional missing" : "Needs mapping"
    }

    var operationSummary: String {
        requirement.operations.joined(separator: ", ")
    }
}

struct WorkspaceAppPackageImportReview: Identifiable, Equatable {
    var id = UUID()
    var packageURL: URL
    var report: WorkspaceAppPackageValidationReport
    var dependencyMappings: [WorkspaceAppPackageDependencyMapping]

    init(
        id: UUID = UUID(),
        packageURL: URL,
        report: WorkspaceAppPackageValidationReport,
        registry: WorkspaceAppContractRegistry = WorkspaceAppContractRegistry()
    ) {
        self.id = id
        self.packageURL = packageURL
        self.report = report
        self.dependencyMappings = Self.buildDependencyMappings(
            requirements: report.package?.requiredContracts ?? [],
            registry: registry
        )
    }

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
        dependencyMappings.filter(\.isRequired).map(\.requirement)
    }

    var optionalDependencies: [WorkspaceAppPackageContractRequirement] {
        dependencyMappings.filter { !$0.isRequired }.map(\.requirement)
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

    var hasUnresolvedRequiredDependencies: Bool {
        dependencyMappings.contains { $0.isRequired && !$0.isMapped }
    }

    private static func buildDependencyMappings(
        requirements: [WorkspaceAppPackageContractRequirement],
        registry: WorkspaceAppContractRegistry
    ) -> [WorkspaceAppPackageDependencyMapping] {
        requirements.map { requirement in
            let workspaceRequirement = WorkspaceAppRequirement(
                id: requirement.id,
                contract: requirement.contract,
                minVersion: requirement.minVersion,
                operations: requirement.operations,
                providerHint: requirement.providerHint,
                providerRequired: requirement.providerRequired,
                optional: requirement.optional
            )
            let resolution = registry.resolve(workspaceRequirement)
            return WorkspaceAppPackageDependencyMapping(
                requirement: requirement,
                familyName: registry.family(id: requirement.contract)?.displayName ?? requirement.contract,
                selectedImplementation: resolution.selectedImplementation,
                candidateImplementations: resolution.implementations
            )
        }
    }
}

enum WorkspaceAppPackageImportReviewer {
    static func review(
        packageURL: URL,
        service: WorkspaceAppPackageService = WorkspaceAppPackageService(),
        registry: WorkspaceAppContractRegistry = WorkspaceAppContractRegistry()
    ) -> WorkspaceAppPackageImportReview {
        WorkspaceAppPackageImportReview(
            packageURL: packageURL,
            report: service.validatePackage(at: packageURL),
            registry: registry
        )
    }
}
