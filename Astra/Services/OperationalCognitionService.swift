import Foundation
import SwiftData
import ASTRACore

@MainActor
enum OperationalCognitionService {
    static let method = "deterministic-rules-v1"

    static func recordPostRunAdvisories(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        generatedAt: Date = Date()
    ) {
        let runEvents = sourceEvents(for: task, run: run)
        let allTaskEvents = sourceEvents(for: task, run: nil)
        let runProvenance = provenance(
            task: task,
            run: run,
            events: runEvents,
            generatedAt: generatedAt
        )
        let taskProvenance = provenance(
            task: task,
            run: run,
            events: allTaskEvents,
            generatedAt: generatedAt
        )
        let runSummary = makeRunSummary(task: task, run: run, events: runEvents)

        insertResultIfNeeded(
            makeRunSummaryResult(
                task: task,
                run: run,
                runSummary: runSummary,
                provenance: runProvenance,
                generatedAt: generatedAt
            ),
            task: task,
            run: run,
            modelContext: modelContext
        )

        insertResultIfNeeded(
            makeTaskHealthResult(
                task: task,
                run: run,
                runSummary: runSummary,
                events: allTaskEvents,
                provenance: taskProvenance,
                generatedAt: generatedAt
            ),
            task: task,
            run: run,
            modelContext: modelContext
        )

        if let attention = makeAttentionResult(
            task: task,
            run: run,
            events: runEvents,
            provenance: runProvenance,
            generatedAt: generatedAt
        ) {
            insertResultIfNeeded(attention, task: task, run: run, modelContext: modelContext)
        }

        insertResultIfNeeded(
            makeCompressedStateResult(
                task: task,
                run: run,
                runSummary: runSummary,
                events: allTaskEvents,
                provenance: taskProvenance,
                generatedAt: generatedAt
            ),
            task: task,
            run: run,
            modelContext: modelContext
        )
    }

    static func decodeResult(from payload: String) -> CognitionJobResult? {
        CognitionJobResult.decodePayload(payload)
    }

    private static func insertResultIfNeeded(
        _ result: CognitionJobResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        let eventType = result.kind.eventType
        guard !task.events.contains(where: { $0.type == eventType && $0.run?.id == run.id }) else {
            return
        }
        guard let payload = result.encodedPayload() else {
            AppLogger.audit(.runtimePersistenceSummary, category: "Cognition", taskID: task.id, fields: [
                "result": "encode_failed",
                "kind": result.kind.rawValue
            ], level: .warning)
            return
        }
        modelContext.insert(TaskEvent(task: task, type: eventType, payload: payload, run: run))
    }

    private static func sourceEvents(for task: AgentTask, run: TaskRun?) -> [TaskEvent] {
        task.events
            .filter { event in
                guard !OperationalCognitionEventTypes.isCognitionEvent(event.type) else { return false }
                if let run {
                    return event.run?.id == run.id
                }
                return true
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func provenance(
        task: AgentTask,
        run: TaskRun,
        events: [TaskEvent],
        generatedAt _: Date
    ) -> CognitionProvenance {
        CognitionProvenance(
            taskID: task.id,
            runID: run.id,
            sourceEventIDs: events.map(\.id),
            sourceEventTypes: Array(Set(events.map(\.type))).sorted(),
            sourceEventCount: events.count,
            sourceStartedAt: run.startedAt,
            sourceCompletedAt: run.completedAt,
            runtimeID: run.runtimeID ?? task.runtimeID,
            model: task.model,
            method: method
        )
    }

    private static func makeRunSummary(task _: AgentTask, run: TaskRun, events: [TaskEvent]) -> CognitionRunSummary {
        let issueTypes: Set<String> = ["error", "budget.exceeded", "permission.denied", "permission.approval.requested"]
        let output = boundedMultiline(run.output, maxCharacters: 700)
        return CognitionRunSummary(
            status: run.status.rawValue,
            stopReason: run.stopReason,
            exitCode: run.exitCode,
            outputExcerpt: output.isEmpty ? nil : output,
            filesChanged: uniquePreservingOrder(run.fileChanges.map(\.path), limit: 24),
            eventCount: events.count,
            responseEventCount: events.filter { $0.type == "agent.response" }.count,
            toolUseCount: events.filter { $0.type == "tool.use" }.count,
            toolResultCount: events.filter { $0.type == "tool.result" }.count,
            issueCount: events.filter { issueTypes.contains($0.type) }.count,
            tokenCount: run.tokensUsed,
            costUSD: run.costUSD
        )
    }

    private static func makeRunSummaryResult(
        task _: AgentTask,
        run: TaskRun,
        runSummary: CognitionRunSummary,
        provenance: CognitionProvenance,
        generatedAt: Date
    ) -> CognitionJobResult {
        let summary = runSummarySentence(run: run, runSummary: runSummary)
        return CognitionJobResult(
            kind: .runSummary,
            generatedAt: generatedAt,
            confidence: 1.0,
            summary: summary,
            provenance: provenance,
            runSummary: runSummary
        )
    }

    private static func makeTaskHealthResult(
        task: AgentTask,
        run: TaskRun,
        runSummary: CognitionRunSummary,
        events: [TaskEvent],
        provenance: CognitionProvenance,
        generatedAt: Date
    ) -> CognitionJobResult {
        let health = makeHealth(task: task, run: run, runSummary: runSummary, events: events)
        return CognitionJobResult(
            kind: .taskHealth,
            generatedAt: generatedAt,
            confidence: 0.95,
            summary: health.summary,
            provenance: provenance,
            taskHealth: health
        )
    }

    private static func makeAttentionResult(
        task: AgentTask,
        run: TaskRun,
        events: [TaskEvent],
        provenance: CognitionProvenance,
        generatedAt: Date
    ) -> CognitionJobResult? {
        guard let signal = makeAttentionSignal(task: task, run: run, events: events) else {
            return nil
        }
        return CognitionJobResult(
            kind: .attentionSignal,
            generatedAt: generatedAt,
            confidence: 0.95,
            summary: signal.title,
            provenance: provenance,
            attentionSignal: signal
        )
    }

    private static func makeCompressedStateResult(
        task: AgentTask,
        run: TaskRun,
        runSummary: CognitionRunSummary,
        events: [TaskEvent],
        provenance: CognitionProvenance,
        generatedAt: Date
    ) -> CognitionJobResult {
        let compressed = makeCompressedState(task: task, run: run, runSummary: runSummary, events: events)
        return CognitionJobResult(
            kind: .stateCompression,
            generatedAt: generatedAt,
            confidence: 0.9,
            summary: compressed.latestOutcome,
            provenance: provenance,
            compressedState: compressed
        )
    }

    private static func makeHealth(
        task: AgentTask,
        run: TaskRun,
        runSummary: CognitionRunSummary,
        events: [TaskEvent]
    ) -> TaskHealthAssessment {
        let state: TaskHealthAssessmentState
        let score: Int
        let summary: String
        let recommendedAction: String?

        switch task.status {
        case .draft:
            state = .draft
            score = 60
            summary = "Task is still a draft."
            recommendedAction = "Queue or run the task when ready."
        case .queued:
            state = .queued
            score = 70
            summary = "Task is queued for execution."
            recommendedAction = nil
        case .running:
            state = .running
            score = 75
            summary = "Task is currently running."
            recommendedAction = nil
        case .pendingUser:
            state = .needsAttention
            score = 35
            summary = "Task needs user attention before it can continue."
            recommendedAction = pendingAction(events: events)
        case .completed:
            state = .completed
            score = runSummary.issueCount > 0 ? 82 : 95
            summary = runSummary.filesChanged.isEmpty
                ? "Task completed without recorded file changes."
                : "Task completed with \(runSummary.filesChanged.count) changed \(runSummary.filesChanged.count == 1 ? "file" : "files")."
            recommendedAction = "Review the result and mark done if it is acceptable."
        case .failed:
            state = .failed
            score = 20
            summary = "Task failed during the latest run."
            recommendedAction = "Review the run issue and retry after fixing the blocker."
        case .cancelled:
            state = .cancelled
            score = 40
            summary = "Task was cancelled."
            recommendedAction = "Retry if the work should continue."
        case .budgetExceeded:
            state = .budgetExceeded
            score = 25
            summary = "Task exceeded its configured budget."
            recommendedAction = "Retry with a narrower request or raise the budget."
        }

        var rationale = [
            "Task status: \(task.status.rawValue)",
            "Run status: \(run.status.rawValue)"
        ]
        if !run.stopReason.isEmpty {
            rationale.append("Stop reason: \(run.stopReason)")
        }
        if runSummary.issueCount > 0 {
            rationale.append("\(runSummary.issueCount) issue \(runSummary.issueCount == 1 ? "event" : "events") observed")
        }
        if runSummary.filesChanged.count > 0 {
            rationale.append("\(runSummary.filesChanged.count) changed \(runSummary.filesChanged.count == 1 ? "file" : "files")")
        }

        return TaskHealthAssessment(
            state: state,
            score: score,
            summary: summary,
            rationale: rationale,
            recommendedAction: recommendedAction
        )
    }

    private static func makeAttentionSignal(
        task: AgentTask,
        run: TaskRun,
        events: [TaskEvent]
    ) -> TaskAttentionSignal? {
        if let event = latestEvent(ofType: "permission.approval.requested", in: events) {
            return TaskAttentionSignal(
                kind: .permissionApproval,
                severity: .warning,
                title: "Permission approval needed",
                message: "The provider requested a runtime permission before this task can continue.",
                recommendedAction: "Review the permission request and approve only if it matches the task.",
                sourceEventType: event.type,
                sourceEventPayloadExcerpt: boundedMultiline(event.payload, maxCharacters: 420)
            )
        }

        if task.status == .pendingUser {
            let event = latestIssueEvent(in: events)
            return TaskAttentionSignal(
                kind: .userInputNeeded,
                severity: .warning,
                title: "User input needed",
                message: "The task is paused and waiting for review or guidance.",
                recommendedAction: pendingAction(events: events),
                sourceEventType: event?.type,
                sourceEventPayloadExcerpt: event.map { boundedMultiline($0.payload, maxCharacters: 420) }
            )
        }

        if task.status == .budgetExceeded || run.status == .budgetExceeded {
            let event = latestEvent(ofType: "budget.exceeded", in: events)
            return TaskAttentionSignal(
                kind: .budgetExceeded,
                severity: .warning,
                title: "Budget exceeded",
                message: "The task stopped because it exceeded its configured budget.",
                recommendedAction: "Retry with a narrower request or raise the budget.",
                sourceEventType: event?.type,
                sourceEventPayloadExcerpt: event.map { boundedMultiline($0.payload, maxCharacters: 420) }
            )
        }

        if task.status == .failed || run.status == .failed || run.status == .timeout {
            let event = latestEvent(ofType: "error", in: events)
            let isValidation = event?.payload.localizedCaseInsensitiveContains("validation") == true ||
                event?.payload.localizedCaseInsensitiveContains("tests failed") == true
            return TaskAttentionSignal(
                kind: isValidation ? .validationIssue : .runFailed,
                severity: .error,
                title: isValidation ? "Validation needs attention" : "Run failed",
                message: isValidation
                    ? "Validation flagged an issue in the latest run."
                    : "The latest run failed before ASTRA could mark the task complete.",
                recommendedAction: isValidation
                    ? "Review validation output and retry after fixing the issue."
                    : "Review the run error and retry after fixing the blocker.",
                sourceEventType: event?.type,
                sourceEventPayloadExcerpt: event.map { boundedMultiline($0.payload, maxCharacters: 420) }
            )
        }

        return nil
    }

    private static func makeCompressedState(
        task: AgentTask,
        run: TaskRun,
        runSummary: CognitionRunSummary,
        events: [TaskEvent]
    ) -> CognitionCompressedState {
        let blockers = events
            .filter { ["error", "permission.denied", "permission.approval.requested", "budget.exceeded"].contains($0.type) }
            .suffix(6)
            .map { boundedInline($0.payload, maxCharacters: 220) }
        let nextAction = nextLikelyAction(task: task, run: run, events: events)
        return CognitionCompressedState(
            mode: task.status.rawValue,
            currentObjective: task.goal,
            latestOutcome: runSummarySentence(run: run, runSummary: runSummary),
            blockers: uniquePreservingOrder(Array(blockers), limit: 8),
            filesChanged: runSummary.filesChanged,
            nextLikelyAction: nextAction
        )
    }

    private static func pendingAction(events: [TaskEvent]) -> String {
        if latestEvent(ofType: "permission.approval.requested", in: events) != nil {
            return "Review the permission request and decide whether to grant it for this run."
        }
        if latestEvent(ofType: "budget.exceeded", in: events) != nil {
            return "Raise the budget or narrow the task before retrying."
        }
        return "Review the latest message or error, then provide guidance or retry."
    }

    private static func nextLikelyAction(task: AgentTask, run: TaskRun, events: [TaskEvent]) -> String? {
        if task.status == .pendingUser {
            return pendingAction(events: events)
        }
        if task.status == .failed || run.status == .failed || run.status == .timeout {
            return "Review the failure and retry when the blocker is fixed."
        }
        if task.status == .budgetExceeded || run.status == .budgetExceeded {
            return "Retry with a larger budget or narrower scope."
        }
        if task.status == .completed {
            return "Review the completed result."
        }
        return nil
    }

    private static func runSummarySentence(run: TaskRun, runSummary: CognitionRunSummary) -> String {
        var parts = ["Run \(run.status.rawValue.replacingOccurrences(of: "_", with: " "))"]
        if !run.stopReason.isEmpty {
            parts.append("stop reason \(run.stopReason.replacingOccurrences(of: "_", with: " "))")
        }
        if runSummary.filesChanged.count > 0 {
            parts.append("\(runSummary.filesChanged.count) changed \(runSummary.filesChanged.count == 1 ? "file" : "files")")
        }
        if runSummary.issueCount > 0 {
            parts.append("\(runSummary.issueCount) issue \(runSummary.issueCount == 1 ? "event" : "events")")
        }
        return parts.joined(separator: "; ") + "."
    }

    private static func latestIssueEvent(in events: [TaskEvent]) -> TaskEvent? {
        events.last { event in
            ["permission.approval.requested", "error", "budget.exceeded", "permission.denied"].contains(event.type)
        }
    }

    private static func latestEvent(ofType type: String, in events: [TaskEvent]) -> TaskEvent? {
        events.last { $0.type == type }
    }

    private static func boundedInline(_ text: String, maxCharacters: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }
        return String(cleaned.prefix(maxCharacters)) + "..."
    }

    private static func boundedMultiline(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "..."
    }

    private static func uniquePreservingOrder(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }
}
