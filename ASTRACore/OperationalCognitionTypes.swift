import Foundation

public enum OperationalCognitionEventTypes {
    public static let runSummary = "cognition.run.summary"
    public static let taskHealth = "cognition.task.health"
    public static let attentionSignal = "cognition.attention.signal"
    public static let stateCompressed = "cognition.state.compressed"
    public static let localDiagnostics = "cognition.local.diagnostics"
    public static let localEvaluation = "cognition.local.evaluation"

    public static let all: Set<String> = [
        runSummary,
        taskHealth,
        attentionSignal,
        stateCompressed,
        localDiagnostics,
        localEvaluation
    ]

    public static func isCognitionEvent(_ type: String) -> Bool {
        type.hasPrefix("cognition.")
    }
}

public enum OperationalCognitionJobKind: String, Codable, CaseIterable, Sendable, Equatable {
    case runSummary = "run_summary"
    case taskHealth = "task_health"
    case attentionSignal = "attention_signal"
    case stateCompression = "state_compression"

    public var eventType: String {
        switch self {
        case .runSummary:
            OperationalCognitionEventTypes.runSummary
        case .taskHealth:
            OperationalCognitionEventTypes.taskHealth
        case .attentionSignal:
            OperationalCognitionEventTypes.attentionSignal
        case .stateCompression:
            OperationalCognitionEventTypes.stateCompressed
        }
    }
}

public enum CognitionJobSourceScope: String, Codable, Sendable, Equatable, Hashable {
    case run
    case task
}

public struct CognitionJob: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: OperationalCognitionJobKind
    public let taskID: UUID
    public let runID: UUID?
    public let sourceScope: CognitionJobSourceScope
    public let requestedAt: Date
    public let advisory: Bool

    public init(
        id: UUID = UUID(),
        kind: OperationalCognitionJobKind,
        taskID: UUID,
        runID: UUID?,
        sourceScope: CognitionJobSourceScope,
        requestedAt: Date,
        advisory: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.runID = runID
        self.sourceScope = sourceScope
        self.requestedAt = requestedAt
        self.advisory = advisory
    }
}

public struct CognitionProvenance: Codable, Hashable, Sendable {
    public let taskID: UUID
    public let runID: UUID?
    public let sourceEventIDs: [UUID]
    public let sourceEventTypes: [String]
    public let sourceEventCount: Int
    public let sourceStartedAt: Date?
    public let sourceCompletedAt: Date?
    public let runtimeID: String?
    public let model: String?
    public let method: String
    public let providerID: String?

    public init(
        taskID: UUID,
        runID: UUID?,
        sourceEventIDs: [UUID],
        sourceEventTypes: [String],
        sourceEventCount: Int,
        sourceStartedAt: Date?,
        sourceCompletedAt: Date?,
        runtimeID: String?,
        model: String?,
        method: String,
        providerID: String? = nil
    ) {
        self.taskID = taskID
        self.runID = runID
        self.sourceEventIDs = sourceEventIDs
        self.sourceEventTypes = sourceEventTypes
        self.sourceEventCount = sourceEventCount
        self.sourceStartedAt = sourceStartedAt
        self.sourceCompletedAt = sourceCompletedAt
        self.runtimeID = runtimeID
        self.model = model
        self.method = method
        self.providerID = providerID
    }
}

public struct CognitionRunSummary: Codable, Hashable, Sendable {
    public let status: String
    public let stopReason: String
    public let exitCode: Int?
    public let outputExcerpt: String?
    public let filesChanged: [String]
    public let eventCount: Int
    public let responseEventCount: Int
    public let toolUseCount: Int
    public let toolResultCount: Int
    public let issueCount: Int
    public let tokenCount: Int
    public let costUSD: Double

    public init(
        status: String,
        stopReason: String,
        exitCode: Int?,
        outputExcerpt: String?,
        filesChanged: [String],
        eventCount: Int,
        responseEventCount: Int,
        toolUseCount: Int,
        toolResultCount: Int,
        issueCount: Int,
        tokenCount: Int,
        costUSD: Double
    ) {
        self.status = status
        self.stopReason = stopReason
        self.exitCode = exitCode
        self.outputExcerpt = outputExcerpt
        self.filesChanged = filesChanged
        self.eventCount = eventCount
        self.responseEventCount = responseEventCount
        self.toolUseCount = toolUseCount
        self.toolResultCount = toolResultCount
        self.issueCount = issueCount
        self.tokenCount = tokenCount
        self.costUSD = costUSD
    }
}

public enum TaskHealthAssessmentState: String, Codable, Sendable, Equatable, Hashable {
    case draft
    case queued
    case running
    case completed
    case needsAttention = "needs_attention"
    case failed
    case budgetExceeded = "budget_exceeded"
    case cancelled
}

public struct TaskHealthAssessment: Codable, Hashable, Sendable {
    public let state: TaskHealthAssessmentState
    public let score: Int
    public let summary: String
    public let rationale: [String]
    public let recommendedAction: String?

    public init(
        state: TaskHealthAssessmentState,
        score: Int,
        summary: String,
        rationale: [String],
        recommendedAction: String?
    ) {
        self.state = state
        self.score = score
        self.summary = summary
        self.rationale = rationale
        self.recommendedAction = recommendedAction
    }
}

public enum TaskAttentionSignalKind: String, Codable, Sendable, Equatable, Hashable {
    case permissionApproval = "permission_approval"
    case userInputNeeded = "user_input_needed"
    case runFailed = "run_failed"
    case budgetExceeded = "budget_exceeded"
    case validationIssue = "validation_issue"
}

public enum TaskAttentionSeverity: String, Codable, Sendable, Equatable, Hashable {
    case info
    case warning
    case error
}

public struct TaskAttentionSignal: Codable, Hashable, Sendable {
    public let kind: TaskAttentionSignalKind
    public let severity: TaskAttentionSeverity
    public let title: String
    public let message: String
    public let recommendedAction: String?
    public let sourceEventType: String?
    public let sourceEventPayloadExcerpt: String?

    public init(
        kind: TaskAttentionSignalKind,
        severity: TaskAttentionSeverity,
        title: String,
        message: String,
        recommendedAction: String?,
        sourceEventType: String?,
        sourceEventPayloadExcerpt: String?
    ) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.message = message
        self.recommendedAction = recommendedAction
        self.sourceEventType = sourceEventType
        self.sourceEventPayloadExcerpt = sourceEventPayloadExcerpt
    }
}

public struct CognitionCompressedState: Codable, Hashable, Sendable {
    public let mode: String
    public let currentObjective: String
    public let latestOutcome: String
    public let blockers: [String]
    public let filesChanged: [String]
    public let nextLikelyAction: String?

    public init(
        mode: String,
        currentObjective: String,
        latestOutcome: String,
        blockers: [String],
        filesChanged: [String],
        nextLikelyAction: String?
    ) {
        self.mode = mode
        self.currentObjective = currentObjective
        self.latestOutcome = latestOutcome
        self.blockers = blockers
        self.filesChanged = filesChanged
        self.nextLikelyAction = nextLikelyAction
    }
}

public struct CognitionJobResult: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let kind: OperationalCognitionJobKind
    public let advisory: Bool
    public let generatedAt: Date
    public let confidence: Double
    public let summary: String
    public let provenance: CognitionProvenance
    public let runSummary: CognitionRunSummary?
    public let taskHealth: TaskHealthAssessment?
    public let attentionSignal: TaskAttentionSignal?
    public let compressedState: CognitionCompressedState?

    public init(
        schemaVersion: Int = 1,
        kind: OperationalCognitionJobKind,
        advisory: Bool = true,
        generatedAt: Date,
        confidence: Double,
        summary: String,
        provenance: CognitionProvenance,
        runSummary: CognitionRunSummary? = nil,
        taskHealth: TaskHealthAssessment? = nil,
        attentionSignal: TaskAttentionSignal? = nil,
        compressedState: CognitionCompressedState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.advisory = advisory
        self.generatedAt = generatedAt
        self.confidence = confidence
        self.summary = summary
        self.provenance = provenance
        self.runSummary = runSummary
        self.taskHealth = taskHealth
        self.attentionSignal = attentionSignal
        self.compressedState = compressedState
    }

    public func encodedPayload() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodePayload(_ payload: String) -> CognitionJobResult? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CognitionJobResult.self, from: data)
    }
}

public enum LocalCognitionJobDiagnosticStatus: String, Codable, Hashable, Sendable {
    case success
    case fallback
    case skipped
}

public struct LocalCognitionJobDiagnostics: Codable, Hashable, Sendable {
    public let kind: OperationalCognitionJobKind
    public let status: LocalCognitionJobDiagnosticStatus
    public let latencyMilliseconds: Int?
    public let fallbackReason: String?
    public let deterministicSummary: String?
    public let localSummary: String?
    public let changedFields: [String]
    public let rawModelOutput: String?

    public init(
        kind: OperationalCognitionJobKind,
        status: LocalCognitionJobDiagnosticStatus,
        latencyMilliseconds: Int?,
        fallbackReason: String?,
        deterministicSummary: String?,
        localSummary: String?,
        changedFields: [String],
        rawModelOutput: String?
    ) {
        self.kind = kind
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.fallbackReason = fallbackReason
        self.deterministicSummary = deterministicSummary
        self.localSummary = localSummary
        self.changedFields = changedFields
        self.rawModelOutput = rawModelOutput
    }
}

public struct LocalCognitionRunDiagnostics: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let providerID: String
    public let method: String
    public let model: String
    public let endpoint: String
    public let generatedAt: Date
    public let totalLatencyMilliseconds: Int
    public let attemptedJobCount: Int
    public let successfulJobCount: Int
    public let fallbackJobCount: Int
    public let skippedJobCount: Int
    public let jobs: [LocalCognitionJobDiagnostics]

    public init(
        schemaVersion: Int = 1,
        providerID: String,
        method: String,
        model: String,
        endpoint: String,
        generatedAt: Date,
        totalLatencyMilliseconds: Int,
        jobs: [LocalCognitionJobDiagnostics]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.method = method
        self.model = model
        self.endpoint = endpoint
        self.generatedAt = generatedAt
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.jobs = jobs
        attemptedJobCount = jobs.filter { $0.status != .skipped }.count
        successfulJobCount = jobs.filter { $0.status == .success }.count
        fallbackJobCount = jobs.filter { $0.status == .fallback }.count
        skippedJobCount = jobs.filter { $0.status == .skipped }.count
    }

    public func encodedPayload() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodePayload(_ payload: String) -> LocalCognitionRunDiagnostics? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalCognitionRunDiagnostics.self, from: data)
    }
}

public enum LocalCognitionEvaluationRating: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case useful
    case sameAsDeterministic = "same_as_deterministic"
    case worseNoisy = "worse_noisy"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .useful:
            "Useful"
        case .sameAsDeterministic:
            "Same"
        case .worseNoisy:
            "Worse"
        }
    }
}

public struct LocalCognitionRunEvaluation: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let diagnosticsEventID: UUID
    public let taskID: UUID?
    public let runID: UUID?
    public let rating: LocalCognitionEvaluationRating
    public let note: String?
    public let evaluatedAt: Date
    public let evaluator: String

    public init(
        schemaVersion: Int = 1,
        diagnosticsEventID: UUID,
        taskID: UUID?,
        runID: UUID?,
        rating: LocalCognitionEvaluationRating,
        note: String? = nil,
        evaluatedAt: Date,
        evaluator: String = "user"
    ) {
        self.schemaVersion = schemaVersion
        self.diagnosticsEventID = diagnosticsEventID
        self.taskID = taskID
        self.runID = runID
        self.rating = rating
        self.note = note
        self.evaluatedAt = evaluatedAt
        self.evaluator = evaluator
    }

    public func encodedPayload() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodePayload(_ payload: String) -> LocalCognitionRunEvaluation? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalCognitionRunEvaluation.self, from: data)
    }
}
