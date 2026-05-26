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
        #expect(summary.provenance.providerID == DeterministicCognitionProvider.id)
        #expect(summary.provenance.method == OperationalCognitionService.method)
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

    @Test("post-run runtime builds typed advisory cognition jobs")
    func postRunRuntimeBuildsTypedAdvisoryJobs() {
        let taskID = UUID()
        let runID = UUID()
        let requestedAt = Date(timeIntervalSince1970: 12)

        let jobs = OperationalCognitionRuntime.postRunJobs(taskID: taskID, runID: runID, requestedAt: requestedAt)

        #expect(jobs.map(\.kind) == [.runSummary, .taskHealth, .attentionSignal, .stateCompression])
        #expect(jobs.map(\.sourceScope) == [.run, .task, .run, .task])
        #expect(jobs.allSatisfy { $0.advisory })
        #expect(jobs.allSatisfy { $0.taskID == taskID && $0.runID == runID && $0.requestedAt == requestedAt })
    }

    @Test("provider failures do not mutate task state or persist cognition events")
    func providerFailuresDoNotMutateTaskStateOrPersistEvents() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Provider failure", goal: "Complete safely")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date()
        context.insert(task)
        context.insert(run)

        let runtime = OperationalCognitionRuntime(provider: ThrowingCognitionProvider())
        OperationalCognitionService.recordPostRunAdvisories(
            task: task,
            run: run,
            modelContext: context,
            runtime: runtime
        )

        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(!task.events.contains { OperationalCognitionEventTypes.isCognitionEvent($0.type) })
    }

    @Test("runtime rejects non-advisory provider results")
    func runtimeRejectsNonAdvisoryProviderResults() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Non advisory", goal: "Stay authoritative")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date()
        context.insert(task)
        context.insert(run)

        let runtime = OperationalCognitionRuntime(provider: NonAdvisoryCognitionProvider())
        OperationalCognitionService.recordPostRunAdvisories(
            task: task,
            run: run,
            modelContext: context,
            runtime: runtime
        )

        #expect(!task.events.contains { OperationalCognitionEventTypes.isCognitionEvent($0.type) })
    }

    @Test("local OpenAI provider sends JSON schema request and merges advisory output")
    func localOpenAIProviderSendsSchemaRequestAndMergesOutput() async throws {
        let taskID = UUID()
        let runID = UUID()
        let job = CognitionJob(
            kind: .stateCompression,
            taskID: taskID,
            runID: runID,
            sourceScope: .task,
            requestedAt: Date(timeIntervalSince1970: 100)
        )
        let base = baseStateCompressionResult(taskID: taskID, runID: runID)
        let snapshot = localSnapshot(taskID: taskID, runID: runID)
        let http = StubLocalCognitionHTTPClient(response: chatCompletionResponse(content: #"""
        {"summary":"Local model sees a clean finish.","confidence":0.72,"latest_outcome":"Local model compressed the run state.","blockers":[],"next_likely_action":"Review the generated file."}
        """#))
        let provider = LocalOpenAICompatibleCognitionProvider(
            configuration: LocalOpenAICompatibleCognitionConfiguration.lmStudioDefault,
            httpClient: http
        )

        let runResult = await provider.run(for: snapshot, jobs: [job], baseResults: [.stateCompression: base])
        let results = runResult.results

        let result = try #require(results.first)
        #expect(result.provenance.providerID == LocalOpenAICompatibleCognitionConfiguration.providerID)
        #expect(result.provenance.method == LocalOpenAICompatibleCognitionConfiguration.method)
        #expect(result.provenance.model == LocalOpenAICompatibleCognitionConfiguration.defaultModel)
        #expect(result.confidence == 0.72)
        #expect(result.compressedState?.mode == TaskStatus.completed.rawValue)
        #expect(result.compressedState?.latestOutcome == "Local model compressed the run state.")
        #expect(result.compressedState?.nextLikelyAction == "Review the generated file.")

        #expect(runResult.diagnostics.providerID == LocalOpenAICompatibleCognitionConfiguration.providerID)
        #expect(runResult.diagnostics.model == LocalOpenAICompatibleCognitionConfiguration.defaultModel)
        #expect(runResult.diagnostics.endpoint == "http://localhost:1234/v1/chat/completions")
        #expect(runResult.diagnostics.attemptedJobCount == 1)
        #expect(runResult.diagnostics.successfulJobCount == 1)
        #expect(runResult.diagnostics.fallbackJobCount == 0)
        let jobDiagnostics = try #require(runResult.diagnostics.jobs.first)
        #expect(jobDiagnostics.status == .success)
        #expect(jobDiagnostics.deterministicSummary == "Run completed.")
        #expect(jobDiagnostics.localSummary == "Local model compressed the run state.")
        #expect(jobDiagnostics.changedFields.contains("compressed_state.latest_outcome"))
        #expect(jobDiagnostics.rawModelOutput?.contains("Local model sees") == true)

        let requests = await http.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        let body = try requestBodyDictionary(request)
        #expect(body["model"] as? String == LocalOpenAICompatibleCognitionConfiguration.defaultModel)
        #expect(body["stream"] as? Bool == false)
        #expect(body["temperature"] as? Int == 0)
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
    }

    @Test("local OpenAI provider falls back to deterministic result on invalid JSON")
    func localOpenAIProviderFallsBackOnInvalidJSON() async throws {
        let taskID = UUID()
        let runID = UUID()
        let job = CognitionJob(
            kind: .stateCompression,
            taskID: taskID,
            runID: runID,
            sourceScope: .task,
            requestedAt: Date(timeIntervalSince1970: 100)
        )
        let base = baseStateCompressionResult(taskID: taskID, runID: runID)
        let http = StubLocalCognitionHTTPClient(response: chatCompletionResponse(content: "not json"))
        let provider = LocalOpenAICompatibleCognitionProvider(
            configuration: LocalOpenAICompatibleCognitionConfiguration.lmStudioDefault,
            httpClient: http
        )

        let runResult = await provider.run(
            for: localSnapshot(taskID: taskID, runID: runID),
            jobs: [job],
            baseResults: [.stateCompression: base]
        )

        #expect(runResult.results == [base])
        #expect(runResult.diagnostics.fallbackJobCount == 1)
        let jobDiagnostics = try #require(runResult.diagnostics.jobs.first)
        #expect(jobDiagnostics.status == .fallback)
        #expect(jobDiagnostics.fallbackReason == "invalid_model_json")
        #expect(jobDiagnostics.deterministicSummary == "Run completed.")
        #expect(jobDiagnostics.localSummary == nil)
    }

    @Test("local cognition configuration supports LM Studio defaults and environment overrides")
    func localCognitionConfigurationSupportsDefaultsAndEnvironment() throws {
        let suiteName = "astra.local-cognition.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppStorageKeys.localCognitionEnabled)
        let defaultConfig = try #require(LocalOpenAICompatibleCognitionConfiguration.active(defaults: defaults, environment: [:]))
        #expect(defaultConfig.baseURL.absoluteString == LocalOpenAICompatibleCognitionConfiguration.lmStudioDefaultBaseURL)
        #expect(defaultConfig.model == LocalOpenAICompatibleCognitionConfiguration.defaultModel)

        let envConfig = try #require(LocalOpenAICompatibleCognitionConfiguration.active(defaults: defaults, environment: [
            "ASTRA_COGNITION_PROVIDER": "lmstudio",
            "ASTRA_COGNITION_BASE_URL": "http://127.0.0.1:3456/v1",
            "ASTRA_COGNITION_MODEL": "gemma-local",
            "ASTRA_COGNITION_TIMEOUT_SECONDS": "7",
            "ASTRA_COGNITION_MAX_TOKENS": "256"
        ]))
        #expect(envConfig.chatCompletionsURL.absoluteString == "http://127.0.0.1:3456/v1/chat/completions")
        #expect(envConfig.model == "gemma-local")
        #expect(envConfig.timeoutSeconds == 7)
        #expect(envConfig.maxTokens == 256)
    }

    @Test("local cognition evaluation builder uses latest rating and material changes")
    func localCognitionEvaluationBuilderUsesLatestRatingAndMaterialChanges() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Evaluate cognition", goal: "Compare local cognition")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 99)
        context.insert(task)
        context.insert(run)

        let diagnostics = localDiagnostics(taskID: task.id, runID: run.id)
        let diagnosticsEvent = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.localDiagnostics,
            payload: try #require(diagnostics.encodedPayload()),
            run: run
        )
        diagnosticsEvent.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(diagnosticsEvent)

        let olderEvaluation = LocalCognitionRunEvaluation(
            diagnosticsEventID: diagnosticsEvent.id,
            taskID: task.id,
            runID: run.id,
            rating: .useful,
            evaluatedAt: Date(timeIntervalSince1970: 101)
        )
        let newerEvaluation = LocalCognitionRunEvaluation(
            diagnosticsEventID: diagnosticsEvent.id,
            taskID: task.id,
            runID: run.id,
            rating: .sameAsDeterministic,
            evaluatedAt: Date(timeIntervalSince1970: 102)
        )
        let olderEvent = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.localEvaluation,
            payload: try #require(olderEvaluation.encodedPayload()),
            run: run
        )
        let newerEvent = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.localEvaluation,
            payload: try #require(newerEvaluation.encodedPayload()),
            run: run
        )
        context.insert(olderEvent)
        context.insert(newerEvent)

        let rows = LocalCognitionEvaluationBuilder.rows(from: task.events)
        let row = try #require(rows.first)

        #expect(row.rating == .sameAsDeterministic)
        #expect(row.diagnostics.successfulJobCount == 1)
        #expect(row.diagnostics.fallbackJobCount == 1)
        #expect(row.materialChangedFields == ["task_health.summary"])
        #expect(row.isMateriallyDifferent)
        #expect(row.comparisons.count == 2)

        let summary = LocalCognitionEvaluationSummary(rows: rows)
        #expect(summary.totalRuns == 1)
        #expect(summary.ratedRuns == 1)
        #expect(summary.sameCount == 1)
        #expect(summary.fallbackRuns == 1)
    }

    @Test("local cognition evaluation store records audit event without mutating task")
    func localCognitionEvaluationStoreRecordsEventWithoutMutatingTask() throws {
        let container = try makeOperationalCognitionContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Rate cognition", goal: "Rate local output")
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(task)
        context.insert(run)

        let diagnostics = localDiagnostics(taskID: task.id, runID: run.id)
        let diagnosticsEvent = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.localDiagnostics,
            payload: try #require(diagnostics.encodedPayload()),
            run: run
        )
        context.insert(diagnosticsEvent)

        LocalCognitionEvaluationStore.record(
            rating: .worseNoisy,
            diagnosticsEvent: diagnosticsEvent,
            modelContext: context,
            evaluatedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(task.status == .completed)
        let evaluationEvent = try #require(task.events.first {
            $0.type == OperationalCognitionEventTypes.localEvaluation
        })
        let evaluation = try #require(LocalCognitionRunEvaluation.decodePayload(evaluationEvent.payload))
        #expect(evaluation.diagnosticsEventID == diagnosticsEvent.id)
        #expect(evaluation.taskID == task.id)
        #expect(evaluation.runID == run.id)
        #expect(evaluation.rating == .worseNoisy)
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

    private func baseStateCompressionResult(taskID: UUID, runID: UUID) -> CognitionJobResult {
        CognitionJobResult(
            kind: .stateCompression,
            generatedAt: Date(timeIntervalSince1970: 100),
            confidence: 0.9,
            summary: "Run completed.",
            provenance: CognitionProvenance(
                taskID: taskID,
                runID: runID,
                sourceEventIDs: [],
                sourceEventTypes: ["agent.response"],
                sourceEventCount: 1,
                sourceStartedAt: Date(timeIntervalSince1970: 90),
                sourceCompletedAt: Date(timeIntervalSince1970: 99),
                runtimeID: "claude_code",
                model: "claude",
                method: OperationalCognitionService.method,
                providerID: DeterministicCognitionProvider.id
            ),
            compressedState: CognitionCompressedState(
                mode: TaskStatus.completed.rawValue,
                currentObjective: "Summarize the result",
                latestOutcome: "Run completed.",
                blockers: ["old blocker"],
                filesChanged: ["/tmp/report.md"],
                nextLikelyAction: "Review the result."
            )
        )
    }

    private func localSnapshot(taskID: UUID, runID: UUID) -> LocalCognitionSnapshot {
        LocalCognitionSnapshot(
            taskID: taskID,
            runID: runID,
            taskTitle: "Summarize",
            taskGoal: "Summarize the result",
            taskStatus: TaskStatus.completed.rawValue,
            runStatus: RunStatus.completed.rawValue,
            stopReason: "completed",
            exitCode: 0,
            outputExcerpt: "Wrote the report.",
            filesChanged: ["/tmp/report.md"],
            tokenCount: 123,
            costUSD: 0,
            runtimeID: "claude_code",
            model: "claude",
            generatedAt: Date(timeIntervalSince1970: 100),
            runEvents: [
                LocalCognitionEventSnapshot(
                    id: UUID(),
                    type: "agent.response",
                    timestamp: Date(timeIntervalSince1970: 95),
                    payloadExcerpt: "Wrote the report."
                )
            ],
            taskEvents: [
                LocalCognitionEventSnapshot(
                    id: UUID(),
                    type: "agent.response",
                    timestamp: Date(timeIntervalSince1970: 95),
                    payloadExcerpt: "Wrote the report."
                )
            ]
        )
    }

    private func chatCompletionResponse(content: String) -> Data {
        let payload: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "content": content
                    ]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func requestBodyDictionary(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func localDiagnostics(taskID _: UUID, runID _: UUID) -> LocalCognitionRunDiagnostics {
        LocalCognitionRunDiagnostics(
            providerID: LocalOpenAICompatibleCognitionConfiguration.providerID,
            method: LocalOpenAICompatibleCognitionConfiguration.method,
            model: LocalOpenAICompatibleCognitionConfiguration.defaultModel,
            endpoint: "http://localhost:1234/v1/chat/completions",
            generatedAt: Date(timeIntervalSince1970: 100),
            totalLatencyMilliseconds: 1_200,
            jobs: [
                LocalCognitionJobDiagnostics(
                    kind: .taskHealth,
                    status: .success,
                    latencyMilliseconds: 700,
                    fallbackReason: nil,
                    deterministicSummary: "Task completed with 1 changed file.",
                    localSummary: "Task completed with a useful implementation note.",
                    changedFields: ["summary", "confidence", "provenance", "task_health.summary"],
                    rawModelOutput: #"{"summary":"Task completed with a useful implementation note."}"#
                ),
                LocalCognitionJobDiagnostics(
                    kind: .stateCompression,
                    status: .fallback,
                    latencyMilliseconds: 500,
                    fallbackReason: "invalid_model_json",
                    deterministicSummary: "Run completed.",
                    localSummary: nil,
                    changedFields: [],
                    rawModelOutput: nil
                )
            ]
        )
    }
}

private enum TestCognitionProviderError: Error {
    case failed
}

@MainActor
private struct ThrowingCognitionProvider: OperationalCognitionProvider {
    let providerID = "test.throwing"
    let method = "throwing-test"

    func result(for _: CognitionJob, context _: OperationalCognitionJobContext) throws -> CognitionJobResult? {
        throw TestCognitionProviderError.failed
    }
}

@MainActor
private struct NonAdvisoryCognitionProvider: OperationalCognitionProvider {
    let providerID = "test.non-advisory"
    let method = "non-advisory-test"

    func result(for job: CognitionJob, context: OperationalCognitionJobContext) throws -> CognitionJobResult? {
        CognitionJobResult(
            kind: job.kind,
            advisory: false,
            generatedAt: context.generatedAt,
            confidence: 1.0,
            summary: "Non-advisory result should be rejected.",
            provenance: context.provenance(for: job, provider: self)
        )
    }
}

private actor StubLocalCognitionHTTPClient: LocalCognitionHTTPClient {
    private var requests: [URLRequest] = []
    private let response: Data
    private let statusCode: Int

    init(response: Data, statusCode: Int = 200) {
        self.response = response
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (self.response, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
