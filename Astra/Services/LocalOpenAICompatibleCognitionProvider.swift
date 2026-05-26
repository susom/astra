import Foundation
import SwiftData
import ASTRACore

struct LocalOpenAICompatibleCognitionConfiguration: Equatable, Sendable {
    static let lmStudioDefaultBaseURL = "http://localhost:1234/v1"
    static let defaultModel = "astra-cognition"
    static let defaultTimeoutSeconds: TimeInterval = 20
    static let defaultMaxTokens = 512
    static let providerID = "local.openai-compatible.lmstudio"
    static let method = "local-openai-compatible-json-v1"

    let baseURL: URL
    let model: String
    let timeoutSeconds: TimeInterval
    let maxTokens: Int

    var chatCompletionsURL: URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            return baseURL
        }
        if path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("chat/completions")
        }
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat/completions")
    }

    static var lmStudioDefault: LocalOpenAICompatibleCognitionConfiguration {
        LocalOpenAICompatibleCognitionConfiguration(
            baseURL: URL(string: lmStudioDefaultBaseURL)!,
            model: defaultModel,
            timeoutSeconds: defaultTimeoutSeconds,
            maxTokens: defaultMaxTokens
        )
    }

    static func active(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOpenAICompatibleCognitionConfiguration? {
        let envProvider = environment["ASTRA_COGNITION_PROVIDER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let envEnabled = boolEnvironmentValue(environment["ASTRA_LOCAL_COGNITION"]) == true ||
            ["local", "lmstudio", "openai-compatible", "local-openai"].contains(envProvider ?? "")
        let defaultsEnabled = defaults.object(forKey: AppStorageKeys.localCognitionEnabled) != nil &&
            defaults.bool(forKey: AppStorageKeys.localCognitionEnabled)
        guard envEnabled || defaultsEnabled else { return nil }

        let baseURLString = firstNonBlank([
            environment["ASTRA_COGNITION_BASE_URL"],
            defaults.string(forKey: AppStorageKeys.localCognitionBaseURL),
            lmStudioDefaultBaseURL
        ])
        let model = firstNonBlank([
            environment["ASTRA_COGNITION_MODEL"],
            defaults.string(forKey: AppStorageKeys.localCognitionModel),
            defaultModel
        ])
        guard let baseURL = URL(string: baseURLString) else { return nil }

        return LocalOpenAICompatibleCognitionConfiguration(
            baseURL: baseURL,
            model: model,
            timeoutSeconds: timeoutSeconds(defaults: defaults, environment: environment),
            maxTokens: maxTokens(defaults: defaults, environment: environment)
        )
    }

    private static func timeoutSeconds(defaults: UserDefaults, environment: [String: String]) -> TimeInterval {
        let raw = firstNonBlank([
            environment["ASTRA_COGNITION_TIMEOUT_SECONDS"],
            defaults.object(forKey: AppStorageKeys.localCognitionTimeoutSeconds).map { String(describing: $0) }
        ])
        guard let value = Double(raw) else { return defaultTimeoutSeconds }
        return min(120, max(2, value))
    }

    private static func maxTokens(defaults: UserDefaults, environment: [String: String]) -> Int {
        let raw = firstNonBlank([
            environment["ASTRA_COGNITION_MAX_TOKENS"],
            defaults.object(forKey: AppStorageKeys.localCognitionMaxTokens).map { String(describing: $0) }
        ])
        guard let value = Int(raw) else { return defaultMaxTokens }
        return min(2048, max(64, value))
    }

    private static func boolEnvironmentValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func firstNonBlank(_ values: [String?]) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }
}

protocol LocalCognitionHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLocalCognitionHTTPClient: LocalCognitionHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalOpenAICompatibleCognitionError.invalidHTTPResponse
        }
        return (data, http)
    }
}

struct LocalCognitionEventSnapshot: Hashable, Sendable {
    let id: UUID
    let type: String
    let timestamp: Date
    let payloadExcerpt: String
}

struct LocalCognitionSnapshot: Sendable {
    let taskID: UUID
    let runID: UUID
    let taskTitle: String
    let taskGoal: String
    let taskStatus: String
    let runStatus: String
    let stopReason: String
    let exitCode: Int?
    let outputExcerpt: String?
    let filesChanged: [String]
    let tokenCount: Int
    let costUSD: Double
    let runtimeID: String?
    let model: String?
    let generatedAt: Date
    let runEvents: [LocalCognitionEventSnapshot]
    let taskEvents: [LocalCognitionEventSnapshot]
}

enum LocalOpenAICompatibleCognitionError: Error, Equatable {
    case encodeFailed
    case invalidHTTPResponse
    case httpStatus(Int)
    case missingChoiceContent
    case invalidModelJSON
}

struct LocalOpenAICompatibleCognitionProvider {
    let configuration: LocalOpenAICompatibleCognitionConfiguration
    let httpClient: any LocalCognitionHTTPClient

    init(
        configuration: LocalOpenAICompatibleCognitionConfiguration,
        httpClient: any LocalCognitionHTTPClient = URLSessionLocalCognitionHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func results(
        for snapshot: LocalCognitionSnapshot,
        jobs: [CognitionJob],
        baseResults: [OperationalCognitionJobKind: CognitionJobResult]
    ) async -> [CognitionJobResult] {
        var results: [CognitionJobResult] = []
        for job in jobs {
            guard let baseResult = baseResults[job.kind] else { continue }
            do {
                let output = try await output(for: job, snapshot: snapshot, baseResult: baseResult)
                results.append(mergedResult(baseResult: baseResult, output: output))
            } catch {
                results.append(baseResult)
                AppLogger.audit(.runtimePersistenceSummary, category: "Cognition", taskID: snapshot.taskID, fields: [
                    "result": "local_provider_failed",
                    "kind": job.kind.rawValue,
                    "provider": LocalOpenAICompatibleCognitionConfiguration.providerID,
                    "method": LocalOpenAICompatibleCognitionConfiguration.method,
                    "error_type": String(describing: type(of: error))
                ], level: .warning)
            }
        }
        return results
    }

    func output(
        for job: CognitionJob,
        snapshot: LocalCognitionSnapshot,
        baseResult: CognitionJobResult
    ) async throws -> LocalCognitionModelOutput {
        var request = URLRequest(url: configuration.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try requestBody(job: job, snapshot: snapshot, baseResult: baseResult)

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LocalOpenAICompatibleCognitionError.httpStatus(response.statusCode)
        }
        let completion = try JSONDecoder().decode(LocalOpenAIChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw LocalOpenAICompatibleCognitionError.missingChoiceContent
        }
        return try Self.decodeModelOutput(content)
    }

    private func requestBody(
        job: CognitionJob,
        snapshot: LocalCognitionSnapshot,
        baseResult: CognitionJobResult
    ) throws -> Data {
        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userPrompt(job: job, snapshot: snapshot, baseResult: baseResult)
                ]
            ],
            "temperature": 0,
            "max_tokens": configuration.maxTokens,
            "stream": false,
            "response_format": responseFormatSchema
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LocalOpenAICompatibleCognitionError.encodeFailed
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private var systemPrompt: String {
        """
        You are ASTRA's local operational cognition endpoint. Return only JSON that matches the provided schema. Your output is advisory only: do not redefine task status, run status, policy, permissions, or provenance. Prefer concise operational language grounded in the supplied facts.
        """
    }

    private func userPrompt(
        job: CognitionJob,
        snapshot: LocalCognitionSnapshot,
        baseResult: CognitionJobResult
    ) -> String {
        let events = job.sourceScope == .run ? snapshot.runEvents : snapshot.taskEvents
        let compactFacts: [String: Any] = [
            "job_kind": job.kind.rawValue,
            "task": [
                "title": snapshot.taskTitle,
                "goal": snapshot.taskGoal,
                "status": snapshot.taskStatus
            ],
            "run": [
                "status": snapshot.runStatus,
                "stop_reason": snapshot.stopReason,
                "exit_code": snapshot.exitCode.map { $0 as Any } ?? NSNull(),
                "output_excerpt": snapshot.outputExcerpt.map { $0 as Any } ?? NSNull(),
                "files_changed": snapshot.filesChanged,
                "token_count": snapshot.tokenCount,
                "cost_usd": snapshot.costUSD
            ],
            "base_advisory": baseResult.summary,
            "source_events": events.prefix(20).map { event in
                [
                    "type": event.type,
                    "payload": event.payloadExcerpt
                ]
            }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: compactFacts, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return """
        Produce a compact advisory refinement for this cognition job. Preserve the authoritative facts and keep the response short.

        \(json)
        """
    }

    private var responseFormatSchema: [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "astra_cognition_advisory",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "summary": ["type": "string"],
                        "confidence": ["type": "number"],
                        "rationale": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "recommended_action": ["type": "string"],
                        "title": ["type": "string"],
                        "message": ["type": "string"],
                        "latest_outcome": ["type": "string"],
                        "blockers": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "next_likely_action": ["type": "string"]
                    ],
                    "required": ["summary"]
                ]
            ]
        ]
    }

    private static func decodeModelOutput(_ content: String) throws -> LocalCognitionModelOutput {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = candidate.data(using: .utf8),
              let output = try? JSONDecoder().decode(LocalCognitionModelOutput.self, from: data) else {
            throw LocalOpenAICompatibleCognitionError.invalidModelJSON
        }
        return output
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private func mergedResult(
        baseResult: CognitionJobResult,
        output: LocalCognitionModelOutput
    ) -> CognitionJobResult {
        let provenance = localProvenance(from: baseResult.provenance)
        let summary = clean(output.summary) ?? baseResult.summary
        let confidence = min(1, max(0, output.confidence ?? min(baseResult.confidence, 0.8)))

        switch baseResult.kind {
        case .runSummary:
            return CognitionJobResult(
                kind: .runSummary,
                generatedAt: baseResult.generatedAt,
                confidence: confidence,
                summary: summary,
                provenance: provenance,
                runSummary: baseResult.runSummary
            )
        case .taskHealth:
            let health = baseResult.taskHealth.map { health in
                TaskHealthAssessment(
                    state: health.state,
                    score: health.score,
                    summary: summary,
                    rationale: nonEmpty(output.rationale, fallback: health.rationale, limit: 5),
                    recommendedAction: clean(output.recommendedAction) ?? health.recommendedAction
                )
            }
            return CognitionJobResult(
                kind: .taskHealth,
                generatedAt: baseResult.generatedAt,
                confidence: confidence,
                summary: health?.summary ?? summary,
                provenance: provenance,
                taskHealth: health
            )
        case .attentionSignal:
            let attention = baseResult.attentionSignal.map { signal in
                TaskAttentionSignal(
                    kind: signal.kind,
                    severity: signal.severity,
                    title: clean(output.title) ?? signal.title,
                    message: clean(output.message) ?? summary,
                    recommendedAction: clean(output.recommendedAction) ?? signal.recommendedAction,
                    sourceEventType: signal.sourceEventType,
                    sourceEventPayloadExcerpt: signal.sourceEventPayloadExcerpt
                )
            }
            return CognitionJobResult(
                kind: .attentionSignal,
                generatedAt: baseResult.generatedAt,
                confidence: confidence,
                summary: attention?.title ?? summary,
                provenance: provenance,
                attentionSignal: attention
            )
        case .stateCompression:
            let compressed = baseResult.compressedState.map { state in
                CognitionCompressedState(
                    mode: state.mode,
                    currentObjective: state.currentObjective,
                    latestOutcome: clean(output.latestOutcome) ?? summary,
                    blockers: nonEmpty(output.blockers, fallback: state.blockers, limit: 8),
                    filesChanged: state.filesChanged,
                    nextLikelyAction: clean(output.nextLikelyAction) ?? clean(output.recommendedAction) ?? state.nextLikelyAction
                )
            }
            return CognitionJobResult(
                kind: .stateCompression,
                generatedAt: baseResult.generatedAt,
                confidence: confidence,
                summary: compressed?.latestOutcome ?? summary,
                provenance: provenance,
                compressedState: compressed
            )
        }
    }

    private func localProvenance(from provenance: CognitionProvenance) -> CognitionProvenance {
        CognitionProvenance(
            taskID: provenance.taskID,
            runID: provenance.runID,
            sourceEventIDs: provenance.sourceEventIDs,
            sourceEventTypes: provenance.sourceEventTypes,
            sourceEventCount: provenance.sourceEventCount,
            sourceStartedAt: provenance.sourceStartedAt,
            sourceCompletedAt: provenance.sourceCompletedAt,
            runtimeID: provenance.runtimeID,
            model: configuration.model,
            method: LocalOpenAICompatibleCognitionConfiguration.method,
            providerID: LocalOpenAICompatibleCognitionConfiguration.providerID
        )
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }

    private func nonEmpty(_ values: [String]?, fallback: [String], limit: Int) -> [String] {
        let cleaned = (values ?? [])
            .compactMap(clean)
            .prefix(limit)
        return cleaned.isEmpty ? fallback : Array(cleaned)
    }
}

struct LocalCognitionModelOutput: Codable, Equatable, Sendable {
    let summary: String
    let confidence: Double?
    let rationale: [String]?
    let recommendedAction: String?
    let title: String?
    let message: String?
    let latestOutcome: String?
    let blockers: [String]?
    let nextLikelyAction: String?

    enum CodingKeys: String, CodingKey {
        case summary
        case confidence
        case rationale
        case recommendedAction = "recommended_action"
        case title
        case message
        case latestOutcome = "latest_outcome"
        case blockers
        case nextLikelyAction = "next_likely_action"
    }
}

private struct LocalOpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

@MainActor
enum LocalOpenAICompatibleCognitionExecutor {
    static func schedulePostRunAdvisories(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        generatedAt: Date,
        configuration: LocalOpenAICompatibleCognitionConfiguration,
        httpClient: any LocalCognitionHTTPClient = URLSessionLocalCognitionHTTPClient()
    ) {
        let context = OperationalCognitionJobContext(task: task, run: run, generatedAt: generatedAt)
        let jobs = OperationalCognitionRuntime.postRunJobs(taskID: task.id, runID: run.id, requestedAt: generatedAt)
        let baseResults = deterministicBaseResults(jobs: jobs, context: context)
        let snapshot = LocalCognitionSnapshot(context: context)

        Task { @MainActor in
            let provider = LocalOpenAICompatibleCognitionProvider(configuration: configuration, httpClient: httpClient)
            let results = await provider.results(for: snapshot, jobs: jobs, baseResults: baseResults)
            OperationalCognitionRuntime(provider: LocalCognitionAuditProvider())
                .recordResults(results, task: task, run: run, modelContext: modelContext)
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "phase": "local_cognition",
                    "provider": LocalOpenAICompatibleCognitionConfiguration.providerID,
                    "model": configuration.model
                ]
            )
        }
    }

    private static func deterministicBaseResults(
        jobs: [CognitionJob],
        context: OperationalCognitionJobContext
    ) -> [OperationalCognitionJobKind: CognitionJobResult] {
        let provider = DeterministicCognitionProvider()
        var results: [OperationalCognitionJobKind: CognitionJobResult] = [:]
        for job in jobs {
            if let result = try? provider.result(for: job, context: context) {
                results[job.kind] = result
            }
        }
        return results
    }
}

@MainActor
private struct LocalCognitionAuditProvider: OperationalCognitionProvider {
    let providerID = LocalOpenAICompatibleCognitionConfiguration.providerID
    let method = LocalOpenAICompatibleCognitionConfiguration.method

    func result(for _: CognitionJob, context _: OperationalCognitionJobContext) throws -> CognitionJobResult? {
        nil
    }
}

@MainActor
private extension LocalCognitionSnapshot {
    init(context: OperationalCognitionJobContext) {
        taskID = context.task.id
        runID = context.run.id
        taskTitle = context.task.title
        taskGoal = context.task.goal
        taskStatus = context.task.status.rawValue
        runStatus = context.run.status.rawValue
        stopReason = context.run.stopReason
        exitCode = context.run.exitCode
        outputExcerpt = Self.boundedMultiline(context.run.output, maxCharacters: 900)
        filesChanged = Array(context.run.fileChanges.map(\.path).prefix(24))
        tokenCount = context.run.tokensUsed
        costUSD = context.run.costUSD
        runtimeID = context.run.runtimeID ?? context.task.runtimeID
        model = context.task.model
        generatedAt = context.generatedAt
        runEvents = context.runEvents.map(Self.eventSnapshot)
        taskEvents = context.taskEvents.map(Self.eventSnapshot)
    }

    static func eventSnapshot(_ event: TaskEvent) -> LocalCognitionEventSnapshot {
        LocalCognitionEventSnapshot(
            id: event.id,
            type: event.type,
            timestamp: event.timestamp,
            payloadExcerpt: boundedMultiline(event.payload, maxCharacters: 360)
        )
    }

    static func boundedMultiline(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "..."
    }
}
