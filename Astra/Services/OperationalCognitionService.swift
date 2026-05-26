import Foundation
import SwiftData
import ASTRACore

@MainActor
protocol OperationalCognitionProvider {
    var providerID: String { get }
    var method: String { get }

    func result(for job: CognitionJob, context: OperationalCognitionJobContext) throws -> CognitionJobResult?
}

@MainActor
struct OperationalCognitionJobContext {
    let task: AgentTask
    let run: TaskRun
    let generatedAt: Date
    let runEvents: [TaskEvent]
    let taskEvents: [TaskEvent]

    init(task: AgentTask, run: TaskRun, generatedAt: Date) {
        self.task = task
        self.run = run
        self.generatedAt = generatedAt
        runEvents = Self.sourceEvents(for: task, run: run)
        taskEvents = Self.sourceEvents(for: task, run: nil)
    }

    func events(for job: CognitionJob) -> [TaskEvent] {
        switch job.sourceScope {
        case .run:
            runEvents
        case .task:
            taskEvents
        }
    }

    func provenance(for job: CognitionJob, provider: any OperationalCognitionProvider) -> CognitionProvenance {
        let sourceEvents = events(for: job)
        return CognitionProvenance(
            taskID: task.id,
            runID: run.id,
            sourceEventIDs: sourceEvents.map(\.id),
            sourceEventTypes: Array(Set(sourceEvents.map(\.type))).sorted(),
            sourceEventCount: sourceEvents.count,
            sourceStartedAt: run.startedAt,
            sourceCompletedAt: run.completedAt,
            runtimeID: run.runtimeID ?? task.runtimeID,
            model: task.model,
            method: provider.method,
            providerID: provider.providerID
        )
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
}

@MainActor
struct OperationalCognitionRuntime {
    let provider: any OperationalCognitionProvider

    init(provider: any OperationalCognitionProvider) {
        self.provider = provider
    }

    static var `default`: OperationalCognitionRuntime {
        OperationalCognitionRuntime(provider: DeterministicCognitionProvider())
    }

    static func postRunJobs(taskID: UUID, runID: UUID, requestedAt: Date) -> [CognitionJob] {
        [
            CognitionJob(kind: .runSummary, taskID: taskID, runID: runID, sourceScope: .run, requestedAt: requestedAt),
            CognitionJob(kind: .taskHealth, taskID: taskID, runID: runID, sourceScope: .task, requestedAt: requestedAt),
            CognitionJob(kind: .attentionSignal, taskID: taskID, runID: runID, sourceScope: .run, requestedAt: requestedAt),
            CognitionJob(kind: .stateCompression, taskID: taskID, runID: runID, sourceScope: .task, requestedAt: requestedAt)
        ]
    }

    func recordPostRunAdvisories(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        generatedAt: Date = Date()
    ) {
        let context = OperationalCognitionJobContext(task: task, run: run, generatedAt: generatedAt)
        for job in Self.postRunJobs(taskID: task.id, runID: run.id, requestedAt: generatedAt) {
            execute(job: job, context: context, modelContext: modelContext)
        }
    }

    func recordResults(
        _ results: [CognitionJobResult],
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        for result in results {
            insertResultIfNeeded(result, task: task, run: run, modelContext: modelContext)
        }
    }

    private func execute(
        job: CognitionJob,
        context: OperationalCognitionJobContext,
        modelContext: ModelContext
    ) {
        guard job.advisory else {
            auditDrop(job: job, task: context.task, reason: "non_advisory_job", detail: nil)
            return
        }

        let result: CognitionJobResult?
        do {
            result = try provider.result(for: job, context: context)
        } catch {
            auditDrop(
                job: job,
                task: context.task,
                reason: "provider_failed",
                detail: String(describing: error)
            )
            return
        }

        guard let result else { return }
        guard result.advisory else {
            auditDrop(job: job, task: context.task, reason: "non_advisory_result", detail: nil)
            return
        }
        guard result.kind == job.kind else {
            auditDrop(
                job: job,
                task: context.task,
                reason: "kind_mismatch",
                detail: result.kind.rawValue
            )
            return
        }

        insertResultIfNeeded(result, task: context.task, run: context.run, modelContext: modelContext)
    }

    private func insertResultIfNeeded(
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
            auditDrop(jobKind: result.kind, task: task, reason: "encode_failed", detail: nil)
            return
        }
        modelContext.insert(TaskEvent(task: task, type: eventType, payload: payload, run: run))
    }

    private func auditDrop(job: CognitionJob, task: AgentTask, reason: String, detail: String?) {
        auditDrop(jobKind: job.kind, task: task, reason: reason, detail: detail)
    }

    private func auditDrop(jobKind: OperationalCognitionJobKind, task: AgentTask, reason: String, detail: String?) {
        var fields = [
            "result": reason,
            "kind": jobKind.rawValue,
            "provider": provider.providerID,
            "method": provider.method
        ]
        if let detail, !detail.isEmpty {
            fields["detail"] = detail
        }
        AppLogger.audit(
            .runtimePersistenceSummary,
            category: "Cognition",
            taskID: task.id,
            fields: fields,
            level: .warning
        )
    }
}

struct DeterministicCognitionProvider: OperationalCognitionProvider {
    static let id = "astra.deterministic"
    static let methodName = "deterministic-rules-v1"

    var providerID: String { Self.id }
    var method: String { Self.methodName }

    func result(for job: CognitionJob, context: OperationalCognitionJobContext) throws -> CognitionJobResult? {
        let runSummary = makeRunSummary(run: context.run, events: context.runEvents)
        let provenance = context.provenance(for: job, provider: self)

        switch job.kind {
        case .runSummary:
            return makeRunSummaryResult(
                run: context.run,
                runSummary: runSummary,
                provenance: provenance,
                generatedAt: context.generatedAt
            )
        case .taskHealth:
            return makeTaskHealthResult(
                task: context.task,
                run: context.run,
                runSummary: runSummary,
                events: context.taskEvents,
                provenance: provenance,
                generatedAt: context.generatedAt
            )
        case .attentionSignal:
            return makeAttentionResult(
                task: context.task,
                run: context.run,
                events: context.runEvents,
                provenance: provenance,
                generatedAt: context.generatedAt
            )
        case .stateCompression:
            return makeCompressedStateResult(
                task: context.task,
                run: context.run,
                runSummary: runSummary,
                events: context.taskEvents,
                provenance: provenance,
                generatedAt: context.generatedAt
            )
        }
    }

    private func makeRunSummary(run: TaskRun, events: [TaskEvent]) -> CognitionRunSummary {
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

    private func makeRunSummaryResult(
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

    private func makeTaskHealthResult(
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

    private func makeAttentionResult(
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

    private func makeCompressedStateResult(
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

    private func makeHealth(
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

    private func makeAttentionSignal(
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

    private func makeCompressedState(
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

    private func pendingAction(events: [TaskEvent]) -> String {
        if latestEvent(ofType: "permission.approval.requested", in: events) != nil {
            return "Review the permission request and decide whether to grant it for this run."
        }
        if latestEvent(ofType: "budget.exceeded", in: events) != nil {
            return "Raise the budget or narrow the task before retrying."
        }
        return "Review the latest message or error, then provide guidance or retry."
    }

    private func nextLikelyAction(task: AgentTask, run: TaskRun, events: [TaskEvent]) -> String? {
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

    private func runSummarySentence(run: TaskRun, runSummary: CognitionRunSummary) -> String {
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

    private func latestIssueEvent(in events: [TaskEvent]) -> TaskEvent? {
        events.last { event in
            ["permission.approval.requested", "error", "budget.exceeded", "permission.denied"].contains(event.type)
        }
    }

    private func latestEvent(ofType type: String, in events: [TaskEvent]) -> TaskEvent? {
        events.last { $0.type == type }
    }

    private func boundedInline(_ text: String, maxCharacters: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }
        return String(cleaned.prefix(maxCharacters)) + "..."
    }

    private func boundedMultiline(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "..."
    }

    private func uniquePreservingOrder(_ values: [String], limit: Int) -> [String] {
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

@MainActor
enum OperationalCognitionService {
    static let method = DeterministicCognitionProvider.methodName

    static func recordPostRunAdvisories(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        generatedAt: Date = Date(),
        runtime: OperationalCognitionRuntime? = nil
    ) {
        if let runtime {
            runtime.recordPostRunAdvisories(
                task: task,
                run: run,
                modelContext: modelContext,
                generatedAt: generatedAt
            )
            return
        }

        if let configuration = LocalOpenAICompatibleCognitionConfiguration.active() {
            LocalOpenAICompatibleCognitionExecutor.schedulePostRunAdvisories(
                task: task,
                run: run,
                modelContext: modelContext,
                generatedAt: generatedAt,
                configuration: configuration
            )
            return
        }

        let activeRuntime = runtime ?? .default
        activeRuntime.recordPostRunAdvisories(
            task: task,
            run: run,
            modelContext: modelContext,
            generatedAt: generatedAt
        )
    }

    static func decodeResult(from payload: String) -> CognitionJobResult? {
        CognitionJobResult.decodePayload(payload)
    }
}
