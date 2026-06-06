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
        let storageTables = validateStorage(manifest.storage, issues: &issues)
        validateSources(manifest.sources, requirementIDs: requirementIDs, issues: &issues)
        validateViews(manifest.views, storageTables: storageTables, issues: &issues)
        validateActions(
            manifest.actions,
            requirementIDs: requirementIDs,
            storageTables: storageTables,
            issues: &issues
        )
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
    ) -> [String: Set<String>] {
        guard let storage else { return [:] }
        var tableNames = Set<String>()
        var tables: [String: Set<String>] = [:]
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
            tables[table.name] = columnNames
        }
        return tables
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

    private static func validateViews(
        _ views: [WorkspaceAppViewSpec],
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (viewIndex, view) in views.enumerated() {
            let path = "/views/\(viewIndex)"
            validateUniqueIdentifier(
                view.id,
                path: "\(path)/id",
                label: "View ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(view.type, path: "\(path)/type", label: "View type", issues: &issues)
            if let table = view.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }

            var widgetIDs = Set<String>()
            for (widgetIndex, widget) in view.widgets.enumerated() {
                let widgetPath = "\(path)/widgets/\(widgetIndex)"
                validateUniqueIdentifier(
                    widget.id,
                    path: "\(widgetPath)/id",
                    label: "Widget ID",
                    seen: &widgetIDs,
                    issues: &issues
                )
                validateIdentifier(widget.type, path: "\(widgetPath)/type", label: "Widget type", issues: &issues)
                if widget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(blocker("\(widgetPath)/label", "Widget label is required."))
                }
                validateWidgetBinding(
                    widget,
                    path: widgetPath,
                    viewTable: view.table,
                    storageTables: storageTables,
                    issues: &issues
                )
            }
        }
    }

    private static func validateWidgetBinding(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        viewTable: String?,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let table = widget.table ?? viewTable
        switch widget.type {
        case "metric", "chart":
            guard let table else {
                issues.append(blocker("\(path)/table", "Storage-backed widget must reference a table."))
                return
            }
            validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            if let field = widget.field {
                validateStorageFieldReference(field, table: table, path: "\(path)/field", storageTables: storageTables, issues: &issues)
            }
            if let groupBy = widget.groupBy {
                validateStorageFieldReference(groupBy, table: table, path: "\(path)/groupBy", storageTables: storageTables, issues: &issues)
            }
        default:
            break
        }
    }

    private static func validateStorageTableReference(
        _ table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if storageTables[table] == nil {
            issues.append(blocker(path, "References unknown storage table '\(table)'."))
        }
    }

    private static func validateStorageFieldReference(
        _ field: String,
        table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let columns = storageTables[table] else { return }
        if !columns.contains(field) {
            issues.append(blocker(path, "References unknown field '\(field)' on storage table '\(table)'."))
        }
    }

    private static func validateActions(
        _ actions: [WorkspaceAppActionSpec],
        requirementIDs: Set<String>,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        var actionIDs = Set<String>()
        for (index, action) in actions.enumerated() {
            let path = "/actions/\(index)"
            validateUniqueIdentifier(
                action.id,
                path: "\(path)/id",
                label: "Action ID",
                seen: &seen,
                issues: &issues
            )
            if !action.id.isEmpty {
                actionIDs.insert(action.id)
            }
            validateIdentifier(action.type, path: "\(path)/type", label: "Action type", issues: &issues)
            if let requirementRef = action.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Action references unknown requirement '\(requirementRef)'."))
            }
            if let table = action.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }
            if action.type == "artifact.export",
               let format = action.exportFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !format.isEmpty,
               !["csv", "json"].contains(format) {
                issues.append(blocker("\(path)/exportFormat", "Artifact export format must be csv or json."))
            }
            if action.type == "task.createDraft",
               action.taskGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/taskGoal", "Task draft action must declare a task goal."))
            }
        }

        for (index, action) in actions.enumerated() where action.type == "pipeline.run" {
            let path = "/actions/\(index)"
            if action.steps.isEmpty {
                issues.append(blocker("\(path)/steps", "Pipeline action must declare at least one step."))
            }
            for (stepIndex, stepID) in action.steps.enumerated() {
                let stepPath = "\(path)/steps/\(stepIndex)"
                validateIdentifier(stepID, path: stepPath, label: "Pipeline step action ID", issues: &issues)
                if stepID == action.id {
                    issues.append(blocker(stepPath, "Pipeline action cannot include itself as a step."))
                } else if !actionIDs.contains(stepID) {
                    issues.append(blocker(stepPath, "Pipeline step references unknown action '\(stepID)'."))
                }
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
