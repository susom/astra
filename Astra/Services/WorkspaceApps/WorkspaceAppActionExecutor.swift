import Foundation
import SwiftData

enum WorkspaceAppActionExecutionError: LocalizedError, Equatable {
    case missingAction(String)
    case unsupportedActionType(String)
    case missingTable
    case missingRecord
    case missingPrimaryKey(String)
    case missingTaskGoal
    case missingPipelineSteps(String)
    case unsupportedExportFormat(String)
    case approvalRequired(String)
    case gateBlocked(String)
    case permissionDenied(String)
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAction(let actionID):
            "Workspace app action '\(actionID)' was not found."
        case .unsupportedActionType(let type):
            "Workspace app action type '\(type)' is not supported yet."
        case .missingTable:
            "Workspace app storage action requires a table."
        case .missingRecord:
            "Workspace app storage write action requires a record."
        case .missingPrimaryKey(let table):
            "Workspace app storage table '\(table)' must declare a primary key for this action."
        case .missingTaskGoal:
            "Workspace app task action requires a task goal."
        case .missingPipelineSteps(let actionID):
            "Workspace app pipeline action '\(actionID)' must declare at least one step."
        case .unsupportedExportFormat(let format):
            "Workspace app artifact export format '\(format)' is not supported."
        case .approvalRequired(let actionID):
            "Workspace app approval gate '\(actionID)' requires human approval before execution can continue."
        case .gateBlocked(let actionID):
            "Workspace app expression gate '\(actionID)' blocked execution."
        case .permissionDenied(let message):
            message
        case .storageFailed(let message):
            "Workspace app storage action failed: \(message)"
        }
    }
}

struct WorkspaceAppActionInput: Codable, Sendable, Equatable {
    var table: String?
    var record: [String: WorkspaceAppStorageValue]
    var limit: Int
    var exportFormat: String?
    var taskTitle: String?
    var taskGoal: String?
    var confirmedDestructive: Bool
    var confirmedApproval: Bool

    init(
        table: String? = nil,
        record: [String: WorkspaceAppStorageValue] = [:],
        limit: Int = 100,
        exportFormat: String? = nil,
        taskTitle: String? = nil,
        taskGoal: String? = nil,
        confirmedDestructive: Bool = false,
        confirmedApproval: Bool = false
    ) {
        self.table = table
        self.record = record
        self.limit = limit
        self.exportFormat = exportFormat
        self.taskTitle = taskTitle
        self.taskGoal = taskGoal
        self.confirmedDestructive = confirmedDestructive
        self.confirmedApproval = confirmedApproval
    }
}

struct WorkspaceAppActionExecutionResult: Equatable {
    var run: WorkspaceAppRun
    var rows: [[String: WorkspaceAppStorageValue]]
    var outputSummary: String
}

struct WorkspaceAppRunRecorder {
    func startRun(
        app: WorkspaceApp,
        actionID: String,
        trigger: WorkspaceAppRunTrigger,
        inputSummary: String,
        modelContext: ModelContext
    ) -> WorkspaceAppRun {
        let run = WorkspaceAppRun(
            workspaceID: app.workspaceID,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: actionID,
            trigger: trigger,
            inputSummary: inputSummary
        )
        modelContext.insert(run)
        recordEvent(
            run: run,
            type: "workspaceApp.action.started",
            payload: ["actionID": .text(actionID), "trigger": .text(trigger.rawValue)],
            modelContext: modelContext
        )
        return run
    }

    func completeRun(
        _ run: WorkspaceAppRun,
        outputSummary: String,
        modelContext: ModelContext
    ) {
        run.status = .completed
        run.completedAt = Date()
        run.outputSummary = outputSummary
        recordEvent(
            run: run,
            type: "workspaceApp.action.completed",
            payload: ["summary": .text(outputSummary)],
            modelContext: modelContext
        )
    }

    func failRun(
        _ run: WorkspaceAppRun,
        error: Error,
        blocked: Bool = false,
        modelContext: ModelContext
    ) {
        run.status = blocked ? .blocked : .failed
        run.completedAt = Date()
        run.errorMessage = String(describing: error)
        recordEvent(
            run: run,
            type: blocked ? "workspaceApp.action.blocked" : "workspaceApp.action.failed",
            payload: ["error": .text(String(describing: error))],
            modelContext: modelContext
        )
    }

    func recordEvent(
        run: WorkspaceAppRun,
        type: String,
        payload: [String: WorkspaceAppStorageValue],
        modelContext: ModelContext
    ) {
        modelContext.insert(WorkspaceAppRunEvent(
            runID: run.id,
            workspaceID: run.workspaceID,
            appID: run.appID,
            actionID: run.actionID,
            type: type,
            payload: Self.payloadString(payload)
        ))
    }

    private static func payloadString<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct WorkspaceAppActionExecutor {
    var storageService = WorkspaceAppStorageService()
    var recorder = WorkspaceAppRunRecorder()

    @MainActor
    func execute(
        actionID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput = WorkspaceAppActionInput(),
        trigger: WorkspaceAppRunTrigger = .user,
        modelContext: ModelContext
    ) throws -> WorkspaceAppActionExecutionResult {
        let run = recorder.startRun(
            app: app,
            actionID: actionID,
            trigger: trigger,
            inputSummary: inputSummary(input),
            modelContext: modelContext
        )

        do {
            let action = try actionSpec(actionID: actionID, manifest: manifest)
            try enforcePermission(for: action, app: app, input: input)
            let result = try execute(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                input: input,
                run: run,
                modelContext: modelContext
            )
            run.linkedTaskID = result.linkedTaskID
            run.linkedArtifactPath = result.linkedArtifactPath
            if let linkedTaskID = result.linkedTaskID {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.task.created",
                    payload: ["taskID": .text(linkedTaskID.uuidString)],
                    modelContext: modelContext
                )
            }
            if let linkedArtifactPath = result.linkedArtifactPath {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.artifact.exported",
                    payload: ["path": .text(linkedArtifactPath)],
                    modelContext: modelContext
                )
            }
            recorder.completeRun(run, outputSummary: result.outputSummary, modelContext: modelContext)
            app.lastRunAt = Date()
            app.updatedAt = Date()
            try modelContext.save()
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: result.rows,
                outputSummary: result.outputSummary
            )
        } catch {
            recorder.failRun(
                run,
                error: error,
                blocked: isPermissionError(error),
                modelContext: modelContext
            )
            try? modelContext.save()
            throw error
        }
    }

    private func actionSpec(actionID: String, manifest: WorkspaceAppManifest) throws -> WorkspaceAppActionSpec {
        guard let action = manifest.actions.first(where: { $0.id == actionID }) else {
            throw WorkspaceAppActionExecutionError.missingAction(actionID)
        }
        return action
    }

    private func enforcePermission(
        for action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        input: WorkspaceAppActionInput
    ) throws {
        switch effect(for: action.type) {
        case .read:
            return
        case .localWrite:
            guard app.permissionMode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform local write action '\(action.id)'."
                )
            }
        case .externalWrite:
            guard app.permissionMode == .preApproved else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "External write action '\(action.id)' requires approval before execution."
                )
            }
        case .destructive:
            guard app.permissionMode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform destructive action '\(action.id)'."
                )
            }
            guard input.confirmedDestructive else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Destructive action '\(action.id)' requires explicit confirmation before execution."
                )
            }
        }
    }

    private func execute(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        switch action.type {
        case "appStorage.insert":
            guard let table = input.table else { throw WorkspaceAppActionExecutionError.missingTable }
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            do {
                try storageService.insertRecord(input.record, into: table, databaseURL: databaseURL)
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Inserted 1 record into \(table).", nil, nil)
        case "appStorage.update":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            do {
                try storageService.updateRecord(
                    input.record,
                    in: table,
                    primaryKey: primaryKey,
                    databaseURL: databaseURL
                )
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Updated 1 record in \(table).", nil, nil)
        case "appStorage.delete":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            guard let primaryKeyValue = input.record[primaryKey] else {
                throw WorkspaceAppActionExecutionError.storageFailed(
                    String(describing: WorkspaceAppStorageError.missingPrimaryKeyValue(primaryKey))
                )
            }
            do {
                try storageService.deleteRecord(
                    from: table,
                    primaryKey: primaryKey,
                    value: primaryKeyValue,
                    databaseURL: databaseURL
                )
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Deleted 1 record from \(table).", nil, nil)
        case "appStorage.query":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            do {
                let rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
                return (rows, "Read \(rows.count) records from \(table).", nil, nil)
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
        case "artifact.export":
            let artifactURL = try exportStorageArtifact(
                action: action,
                manifest: manifest,
                input: input,
                workspace: workspace,
                app: app,
                databaseURL: databaseURL
            )
            return (
                [],
                "Exported \(artifactURL.lastPathComponent).",
                nil,
                artifactURL.path
            )
        case "task.createDraft":
            let task = try createDraftTask(
                action: action,
                manifest: manifest,
                input: input,
                workspace: workspace,
                modelContext: modelContext
            )
            return ([], "Created draft task '\(task.title)'.", task.id, nil)
        case "gate.humanApproval":
            return try executeHumanApprovalGate(
                action: action,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "gate.expression":
            return try executeExpressionGate(
                action: action,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "pipeline.run":
            return try executePipeline(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                input: input,
                run: run,
                modelContext: modelContext
            )
        default:
            throw WorkspaceAppActionExecutionError.unsupportedActionType(action.type)
        }
    }

    private func executeHumanApprovalGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let prompt = action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? action.approvalPrompt ?? "Approval required."
            : "Approval required."
        if !input.confirmedApproval {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.approval.requested",
                payload: [
                    "actionID": .text(action.id),
                    "prompt": .text(prompt),
                    "decisions": .text(action.approvalDecisions.joined(separator: ","))
                ],
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.approvalRequired(action.id)
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.approval.confirmed",
            payload: ["actionID": .text(action.id), "prompt": .text(prompt)],
            modelContext: modelContext
        )
        return ([], "Approval gate '\(action.id)' confirmed.", nil, nil)
    }

    private func executeExpressionGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !field.isEmpty,
              let gateOperator = WorkspaceAppExpressionGateOperator(
                rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              ) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }

        let actualValue = input.record[field]
        let passed = evaluateExpressionGate(
            gateOperator: gateOperator,
            actualValue: actualValue,
            expectedValue: action.gateValue
        )
        let eventPayload: [String: WorkspaceAppStorageValue] = [
            "actionID": .text(action.id),
            "field": .text(field),
            "operator": .text(gateOperator.rawValue),
            "actualValue": .text(describeGateValue(actualValue)),
            "expectedValue": .text(describeGateValue(action.gateValue))
        ]

        if !passed {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.gate.blocked",
                payload: eventPayload,
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.gate.passed",
            payload: eventPayload,
            modelContext: modelContext
        )
        return ([], "Expression gate '\(action.id)' passed.", nil, nil)
    }

    private func executePipeline(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        guard !action.steps.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingPipelineSteps(action.id)
        }

        var rows: [[String: WorkspaceAppStorageValue]] = []
        var summaries: [String] = []
        var linkedTaskID: UUID?
        var linkedArtifactPath: String?

        for stepID in action.steps {
            let step = try actionSpec(actionID: stepID, manifest: manifest)
            try enforcePermission(for: step, app: app, input: input)
            let result = try execute(
                action: step,
                app: app,
                workspace: workspace,
                manifest: manifest,
                input: input,
                run: run,
                modelContext: modelContext
            )
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.pipeline.step.completed",
                payload: [
                    "pipelineID": .text(action.id),
                    "stepID": .text(stepID),
                    "summary": .text(result.outputSummary)
                ],
                modelContext: modelContext
            )
            rows = result.rows
            summaries.append("\(stepID): \(result.outputSummary)")
            linkedTaskID = result.linkedTaskID ?? linkedTaskID
            linkedArtifactPath = result.linkedArtifactPath ?? linkedArtifactPath
        }

        return (
            rows,
            "Pipeline '\(action.id)' completed \(action.steps.count) steps. " + summaries.joined(separator: " "),
            linkedTaskID,
            linkedArtifactPath
        )
    }

    private func primaryKeyColumn(
        in tableName: String,
        manifest: WorkspaceAppManifest
    ) throws -> String {
        guard let table = manifest.storage?.tables.first(where: { $0.name == tableName }),
              let primaryKey = table.columns.first(where: \.primaryKey)?.name else {
            throw WorkspaceAppActionExecutionError.missingPrimaryKey(tableName)
        }
        return primaryKey
    }

    private func exportStorageArtifact(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        workspace: Workspace,
        app: WorkspaceApp,
        databaseURL: URL
    ) throws -> URL {
        guard let table = input.table ?? action.table else {
            throw WorkspaceAppActionExecutionError.missingTable
        }
        let format = normalized(input.exportFormat, action.exportFormat, fallback: "csv").lowercased()
        let rows: [[String: WorkspaceAppStorageValue]]
        do {
            rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
        } catch {
            throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
        }

        let directory = WorkspaceFileLayout.appArtifactExportDirectory(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        )
        guard !directory.isEmpty else {
            throw WorkspaceAppActionExecutionError.storageFailed("Workspace path is unavailable.")
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        switch format {
        case "csv":
            let url = try nextExportURL(directory: directoryURL, table: table, pathExtension: "csv")
            let columns = exportColumns(rows, manifest: manifest, table: table)
            try csvData(rows: rows, columns: columns).write(to: url, options: .atomic)
            return url
        case "json":
            let url = try nextExportURL(directory: directoryURL, table: table, pathExtension: "json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            try data.write(to: url, options: .atomic)
            return url
        default:
            throw WorkspaceAppActionExecutionError.unsupportedExportFormat(format)
        }
    }

    private func nextExportURL(
        directory: URL,
        table: String,
        pathExtension: String
    ) throws -> URL {
        let safeTable = table.replacingOccurrences(of: ".", with: "-")
        let first = directory.appendingPathComponent("\(safeTable).\(pathExtension)")
        guard FileManager.default.fileExists(atPath: first.path) else {
            return first
        }
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(safeTable)-\(suffix).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func exportColumns(
        _ rows: [[String: WorkspaceAppStorageValue]],
        manifest: WorkspaceAppManifest,
        table: String
    ) -> [String] {
        if let declaredColumns = manifest.storage?.tables.first(where: { $0.name == table })?.columns.map(\.name),
           !declaredColumns.isEmpty {
            return declaredColumns
        }
        var columns: [String] = []
        var seen = Set<String>()
        for row in rows {
            for key in row.keys.sorted() where seen.insert(key).inserted {
                columns.append(key)
            }
        }
        return columns
    }

    private func csvData(
        rows: [[String: WorkspaceAppStorageValue]],
        columns: [String]
    ) -> Data {
        let lines = [columns.map(csvField).joined(separator: ",")] + rows.map { row in
            columns
                .map { csvField(exportValue(row[$0])) }
                .joined(separator: ",")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func exportValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            ""
        case .text(let value):
            value
        case .integer(let value):
            "\(value)"
        case .real(let value):
            value.formatted(.number.precision(.fractionLength(0...12)))
        case .bool(let value):
            value ? "true" : "false"
        }
    }

    private func createDraftTask(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        workspace: Workspace,
        modelContext: ModelContext
    ) throws -> AgentTask {
        let title = normalized(
            input.taskTitle,
            action.taskTitle,
            action.label,
            fallback: "\(manifest.app.name) task"
        )
        let goal = normalized(
            input.taskGoal,
            action.taskGoal,
            fallback: ""
        )
        guard !goal.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingTaskGoal
        }

        let task = AgentTask(title: title, goal: goal, workspace: workspace)
        task.inputs = [
            "Created from Workspace App '\(manifest.app.name)' (\(manifest.app.id)).",
            "Workspace App action: \(action.id)"
        ]
        modelContext.insert(task)
        return task
    }

    private func effect(for actionType: String) -> WorkspaceAppContractEffect {
        switch actionType {
        case "appStorage.query", "capability.read", "task.open", "artifact.open", "artifact.export", "url.open", "clipboard.copy", "pipeline.run", "gate.humanApproval", "gate.expression":
            .read
        case "appStorage.insert", "appStorage.update", "notification.show", "task.createDraft":
            .localWrite
        case "capability.write", "task.createAndRun":
            .externalWrite
        case "appStorage.delete":
            .destructive
        default:
            .externalWrite
        }
    }

    private func inputSummary(_ input: WorkspaceAppActionInput) -> String {
        let table = input.table ?? "none"
        let taskGoal = input.taskGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "present" : "none"
        let exportFormat = input.exportFormat ?? "none"
        return "table=\(table); recordKeys=\(input.record.keys.sorted().joined(separator: ",")); limit=\(input.limit); exportFormat=\(exportFormat); taskGoal=\(taskGoal); confirmedDestructive=\(input.confirmedDestructive); confirmedApproval=\(input.confirmedApproval)"
    }

    private func isPermissionError(_ error: Error) -> Bool {
        if case WorkspaceAppActionExecutionError.permissionDenied = error {
            return true
        }
        if case WorkspaceAppActionExecutionError.approvalRequired = error {
            return true
        }
        if case WorkspaceAppActionExecutionError.gateBlocked = error {
            return true
        }
        return false
    }

    private func evaluateExpressionGate(
        gateOperator: WorkspaceAppExpressionGateOperator,
        actualValue: WorkspaceAppStorageValue?,
        expectedValue: WorkspaceAppStorageValue?
    ) -> Bool {
        switch gateOperator {
        case .exists:
            return actualValue != nil && actualValue != .null
        case .notExists:
            return actualValue == nil || actualValue == .null
        case .equals:
            return actualValue == expectedValue
        case .notEquals:
            return actualValue != expectedValue
        case .greaterThan:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison > 0
        case .greaterThanOrEquals:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison >= 0
        case .lessThan:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison < 0
        case .lessThanOrEquals:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison <= 0
        }
    }

    private func numericComparison(
        _ actualValue: WorkspaceAppStorageValue?,
        _ expectedValue: WorkspaceAppStorageValue?
    ) -> Int? {
        guard let actualNumber = numericValue(actualValue),
              let expectedNumber = numericValue(expectedValue) else {
            return nil
        }
        if actualNumber < expectedNumber { return -1 }
        if actualNumber > expectedNumber { return 1 }
        return 0
    }

    private func numericValue(_ value: WorkspaceAppStorageValue?) -> Double? {
        switch value {
        case .integer(let value):
            return Double(value)
        case .real(let value):
            return value
        case .text(let value):
            return Double(value)
        case .bool, .null, nil:
            return nil
        }
    }

    private func describeGateValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            return "null"
        case .text(let value):
            return value
        case .integer(let value):
            return "\(value)"
        case .real(let value):
            return value.formatted(.number.precision(.fractionLength(0...12)))
        case .bool(let value):
            return value ? "true" : "false"
        }
    }

    private func normalized(_ candidates: String?..., fallback: String) -> String {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }
}
