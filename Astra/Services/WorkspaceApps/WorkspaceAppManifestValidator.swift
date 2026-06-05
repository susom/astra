import Foundation

struct WorkspaceAppManifestValidationReport: Equatable {
    struct Issue: Equatable {
        enum Severity: String, Equatable {
            case blocker
            case warning
        }

        var severity: Severity
        var path: String
        var message: String
    }

    var issues: [Issue]

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var isValid: Bool {
        blockers.isEmpty
    }
}

enum WorkspaceAppManifestValidator {
    static func validate(_ manifest: WorkspaceAppManifest) -> WorkspaceAppManifestValidationReport {
        var issues: [WorkspaceAppManifestValidationReport.Issue] = []

        if manifest.schemaVersion < 1 {
            issues.append(blocker("/schemaVersion", "Schema version must be at least 1."))
        }
        validateIdentifier(manifest.app.id, path: "/app/id", label: "App ID", issues: &issues)
        if manifest.app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(blocker("/app/name", "App name is required."))
        }

        let requirementIDs = validateRequirements(manifest.requirements, issues: &issues)
        validateStorage(manifest.storage, issues: &issues)
        validateSources(manifest.sources, requirementIDs: requirementIDs, issues: &issues)
        validateActions(manifest.actions, requirementIDs: requirementIDs, issues: &issues)
        validateAutomations(manifest.automations, actionIDs: Set(manifest.actions.map(\.id)), issues: &issues)
        validatePermissions(manifest.permissions, issues: &issues)

        return WorkspaceAppManifestValidationReport(issues: issues)
    }

    private static func validateRequirements(
        _ requirements: [WorkspaceAppRequirement],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        for (index, requirement) in requirements.enumerated() {
            let path = "/requirements/\(index)"
            validateUniqueIdentifier(
                requirement.id,
                path: "\(path)/id",
                label: "Requirement ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(requirement.contract, path: "\(path)/contract", label: "Contract", issues: &issues)
            if requirement.operations.isEmpty {
                issues.append(blocker("\(path)/operations", "Requirement must declare at least one operation."))
            }
            for (operationIndex, operation) in requirement.operations.enumerated() {
                validateIdentifier(
                    operation,
                    path: "\(path)/operations/\(operationIndex)",
                    label: "Operation",
                    issues: &issues
                )
            }
        }
        return seen
    }

    private static func validateStorage(
        _ storage: WorkspaceAppStorageSchema?,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let storage else { return }
        var tableNames = Set<String>()
        for (tableIndex, table) in storage.tables.enumerated() {
            let tablePath = "/storage/tables/\(tableIndex)"
            validateUniqueIdentifier(
                table.name,
                path: "\(tablePath)/name",
                label: "Table name",
                seen: &tableNames,
                issues: &issues
            )
            if table.columns.isEmpty {
                issues.append(blocker("\(tablePath)/columns", "Storage table must declare at least one column."))
            }
            var columnNames = Set<String>()
            for (columnIndex, column) in table.columns.enumerated() {
                let columnPath = "\(tablePath)/columns/\(columnIndex)"
                validateUniqueIdentifier(
                    column.name,
                    path: "\(columnPath)/name",
                    label: "Column name",
                    seen: &columnNames,
                    issues: &issues
                )
                validateIdentifier(column.type, path: "\(columnPath)/type", label: "Column type", issues: &issues)
            }
        }
    }

    private static func validateSources(
        _ sources: [WorkspaceAppSource],
        requirementIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (index, source) in sources.enumerated() {
            let path = "/sources/\(index)"
            validateUniqueIdentifier(
                source.id,
                path: "\(path)/id",
                label: "Source ID",
                seen: &seen,
                issues: &issues
            )
            if let requirementRef = source.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Source references unknown requirement '\(requirementRef)'."))
            }
        }
    }

    private static func validateActions(
        _ actions: [WorkspaceAppActionSpec],
        requirementIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (index, action) in actions.enumerated() {
            let path = "/actions/\(index)"
            validateUniqueIdentifier(
                action.id,
                path: "\(path)/id",
                label: "Action ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(action.type, path: "\(path)/type", label: "Action type", issues: &issues)
            if let requirementRef = action.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Action references unknown requirement '\(requirementRef)'."))
            }
        }
    }

    private static func validateAutomations(
        _ automations: [WorkspaceAppAutomationSpec],
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (index, automation) in automations.enumerated() {
            let path = "/automations/\(index)"
            validateUniqueIdentifier(
                automation.id,
                path: "\(path)/id",
                label: "Automation ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(automation.type, path: "\(path)/type", label: "Automation type", issues: &issues)
            if automation.enabledByDefault {
                issues.append(blocker("\(path)/enabledByDefault", "Imported or generated automations must default disabled."))
            }
            if let action = automation.action, !actionIDs.contains(action) {
                issues.append(blocker("\(path)/action", "Automation references unknown action '\(action)'."))
            }
        }
    }

    private static func validatePermissions(
        _ permissions: WorkspaceAppPermissions,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if !permissions.externalWrites.isEmpty,
           permissions.defaultMode == .readOnly || permissions.defaultMode == .draftOnly {
            issues.append(warning(
                "/permissions/defaultMode",
                "External writes are declared but the default mode prevents submitting them."
            ))
        }
    }

    private static func validateUniqueIdentifier(
        _ value: String,
        path: String,
        label: String,
        seen: inout Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        validateIdentifier(value, path: path, label: label, issues: &issues)
        guard !value.isEmpty else { return }
        if !seen.insert(value).inserted {
            issues.append(blocker(path, "\(label) '\(value)' is duplicated."))
        }
    }

    private static func validateIdentifier(
        _ value: String,
        path: String,
        label: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append(blocker(path, "\(label) is required."))
            return
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            issues.append(blocker(path, "\(label) may contain only letters, numbers, dot, underscore, or hyphen."))
        }
    }

    private static func blocker(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .blocker, path: path, message: message)
    }

    private static func warning(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .warning, path: path, message: message)
    }
}
