import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeOperationalCognitionContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Operational cognition service")
@MainActor
struct OperationalCognitionServiceTests {
    @Test("completed run records typed advisory summary, health, and state events")
    func completedRunRecordsAdvisoryEvents() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Summarize", goal: "Summarize the repo")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Summary complete."
        run.tokensUsed = 123
        run.completedAt = Date()
        run.appendFileChange(StoredFileChange(from: FileChange(
            path: "/tmp/report.md",
            changeType: .write,
            content: nil,
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(task: task, type: "agent.response", payload: "Summary complete.", run: run))
        context.insert(TaskEvent(task: task, type: "task.completed", payload: "Done", run: run))

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let summary = try cognitionResult(task: task, type: OperationalCognitionEventTypes.runSummary)
        let health = try cognitionResult(task: task, type: OperationalCognitionEventTypes.taskHealth)
        let compressed = try cognitionResult(task: task, type: OperationalCognitionEventTypes.stateCompressed)

        #expect(summary.advisory)
        #expect(summary.kind == .runSummary)
        #expect(summary.runSummary?.filesChanged == ["/tmp/report.md"])
        #expect(summary.runSummary?.tokenCount == 123)
        #expect(health.taskHealth?.state == .completed)
        #expect(health.taskHealth?.score == 95)
        #expect(compressed.compressedState?.mode == TaskStatus.completed.rawValue)
        #expect(!task.events.contains { $0.type == OperationalCognitionEventTypes.attentionSignal })
    }

    @Test("failed run records attention signal without changing canonical status")
    func failedRunRecordsAttentionSignalWithoutMutatingStatus() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Fail", goal: "Run risky command")
        task.status = .failed
        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "failed"
        run.exitCode = 2
        run.completedAt = Date()
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(task: task, type: "error", payload: "Agent exited with code 2.", run: run))

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let attention = try cognitionResult(task: task, type: OperationalCognitionEventTypes.attentionSignal)

        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(attention.kind == .attentionSignal)
        #expect(attention.attentionSignal?.kind == .runFailed)
        #expect(attention.attentionSignal?.severity == .error)
        #expect(attention.provenance.sourceEventTypes.contains("error"))
    }

    @Test("permission approval records approval attention signal")
    func permissionApprovalRecordsAttentionSignal() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Approve", goal: "Use shell")
        task.status = .pendingUser
        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "permission_approval_required"
        run.completedAt = Date()
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: "Permission requested for tool: Bash.",
            run: run
        ))

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let attention = try cognitionResult(task: task, type: OperationalCognitionEventTypes.attentionSignal)

        #expect(task.status == .pendingUser)
        #expect(attention.attentionSignal?.kind == .permissionApproval)
        #expect(attention.attentionSignal?.recommendedAction?.contains("approve") == true)
        #expect(attention.attentionSignal?.sourceEventType == "permission.approval.requested")
    }

    @Test("cognition events are idempotent for the same run")
    func cognitionEventsAreIdempotentForSameRun() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Once", goal: "Do once")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date()
        context.insert(task)
        context.insert(run)

        OperationalCognitionService.recordPostRunAdvisories(task: task, run: run, modelContext: context)
        OperationalCognitionService.recordPostRunAdvisories(task: task, run: run, modelContext: context)

        #expect(task.events.filter { $0.type == OperationalCognitionEventTypes.runSummary }.count == 1)
        #expect(task.events.filter { $0.type == OperationalCognitionEventTypes.taskHealth }.count == 1)
        #expect(task.events.filter { $0.type == OperationalCognitionEventTypes.stateCompressed }.count == 1)
    }

    @Test("compaction preserves cognition events")
    func compactionPreservesCognitionEvents() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Compact", goal: "Keep cognition")
        context.insert(task)

        let result = CognitionJobResult(
            kind: .taskHealth,
            generatedAt: Date(timeIntervalSince1970: 10),
            confidence: 1.0,
            summary: "Task completed.",
            provenance: CognitionProvenance(
                taskID: task.id,
                runID: nil,
                sourceEventIDs: [],
                sourceEventTypes: [],
                sourceEventCount: 0,
                sourceStartedAt: nil,
                sourceCompletedAt: nil,
                runtimeID: nil,
                model: nil,
                method: OperationalCognitionService.method
            ),
            taskHealth: TaskHealthAssessment(
                state: .completed,
                score: 95,
                summary: "Task completed.",
                rationale: [],
                recommendedAction: nil
            )
        )
        let cognitionEvent = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.taskHealth,
            payload: try #require(result.encodedPayload())
        )
        cognitionEvent.timestamp = Date(timeIntervalSince1970: 10)
        context.insert(cognitionEvent)

        for index in 0..<230 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 20))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)

        #expect(task.events.contains { $0.type == OperationalCognitionEventTypes.taskHealth })
        #expect(task.events.contains { $0.type == "activity.compacted" })
    }

    private func cognitionResult(task: AgentTask, type: String) throws -> CognitionJobResult {
        let event = try #require(task.events.first { $0.type == type })
        return try #require(CognitionJobResult.decodePayload(event.payload))
    }
}
