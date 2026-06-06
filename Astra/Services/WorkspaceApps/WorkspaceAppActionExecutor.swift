import Foundation
import SwiftData

enum WorkspaceAppActionExecutionError: LocalizedError, Equatable {
    case missingAction(String)
    case unsupportedActionType(String)
    case missingTable
    case missingRecord
    case missingTaskGoal
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
        case .missingTaskGoal:
            "Workspace app task action requires a task goal."
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
    var taskTitle: String?
    var taskGoal: String?

    init(
        table: String? = nil,
        record: [String: WorkspaceAppStorageValue] = [:],
        limit: Int = 100,
        taskTitle: String? = nil,
        taskGoal: String? = nil
    ) {
        self.table = table
        self.record = record
        self.limit = limit
        self.taskTitle = taskTitle
        self.taskGoal = taskGoal
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
            try enforcePermission(for: action, app: app)
            let result = try execute(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                input: input,
                modelContext: modelContext
            )
            run.linkedTaskID = result.linkedTaskID
            if let linkedTaskID = result.linkedTaskID {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.task.created",
                    payload: ["taskID": .text(linkedTaskID.uuidString)],
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

    private func enforcePermission(for action: WorkspaceAppActionSpec, app: WorkspaceApp) throws {
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
            throw WorkspaceAppActionExecutionError.permissionDenied(
                "Destructive action '\(action.id)' requires explicit confirmation before execution."
            )
        }
    }

    private func execute(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        modelContext: ModelContext
    ) throws -> (rows: [[String: WorkspaceAppStorageValue]], outputSummary: String, linkedTaskID: UUID?) {
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
            return ([], "Inserted 1 record into \(table).", nil)
        case "appStorage.query":
            guard let table = input.table else { throw WorkspaceAppActionExecutionError.missingTable }
            do {
                let rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
                return (rows, "Read \(rows.count) records from \(table).", nil)
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
        case "task.createDraft":
            let task = try createDraftTask(
                action: action,
                manifest: manifest,
                input: input,
                workspace: workspace,
                modelContext: modelContext
            )
            return ([], "Created draft task '\(task.title)'.", task.id)
        default:
            throw WorkspaceAppActionExecutionError.unsupportedActionType(action.type)
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
        case "appStorage.query", "capability.read", "task.open", "artifact.open", "artifact.export", "url.open", "clipboard.copy":
            .read
        case "appStorage.insert", "appStorage.update", "notification.show", "task.createDraft":
            .localWrite
        case "capability.write", "task.createAndRun", "pipeline.run":
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
        return "table=\(table); recordKeys=\(input.record.keys.sorted().joined(separator: ",")); limit=\(input.limit); taskGoal=\(taskGoal)"
    }

    private func isPermissionError(_ error: Error) -> Bool {
        if case WorkspaceAppActionExecutionError.permissionDenied = error {
            return true
        }
        return false
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
