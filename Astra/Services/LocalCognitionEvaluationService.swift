import Foundation
import SwiftData
import ASTRACore

struct LocalCognitionEvaluationComparison: Identifiable {
    let id: String
    let kind: OperationalCognitionJobKind
    let status: LocalCognitionJobDiagnosticStatus
    let deterministicSummary: String?
    let localSummary: String?
    let changedFields: [String]
    let fallbackReason: String?
}

struct LocalCognitionEvaluationRow: Identifiable {
    let diagnosticsEvent: TaskEvent
    let diagnostics: LocalCognitionRunDiagnostics
    let latestEvaluation: LocalCognitionRunEvaluation?
    let taskTitle: String
    let taskID: UUID?
    let runID: UUID?
    let changedFields: [String]
    let materialChangedFields: [String]
    let comparisons: [LocalCognitionEvaluationComparison]

    var id: UUID { diagnosticsEvent.id }

    var rating: LocalCognitionEvaluationRating? {
        latestEvaluation?.rating
    }

    var isMateriallyDifferent: Bool {
        !materialChangedFields.isEmpty ||
            comparisons.contains { comparison in
                normalized(comparison.deterministicSummary) != normalized(comparison.localSummary) &&
                    comparison.localSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
    }

    var latestEvaluationDate: Date? {
        latestEvaluation?.evaluatedAt
    }

    private func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}

struct LocalCognitionEvaluationSummary {
    let totalRuns: Int
    let ratedRuns: Int
    let usefulCount: Int
    let sameCount: Int
    let worseCount: Int
    let fallbackRuns: Int
    let averageLatencyMilliseconds: Int

    init(rows: [LocalCognitionEvaluationRow]) {
        totalRuns = rows.count
        ratedRuns = rows.filter { $0.rating != nil }.count
        usefulCount = rows.filter { $0.rating == .useful }.count
        sameCount = rows.filter { $0.rating == .sameAsDeterministic }.count
        worseCount = rows.filter { $0.rating == .worseNoisy }.count
        fallbackRuns = rows.filter { $0.diagnostics.fallbackJobCount > 0 }.count
        let totalLatency = rows.reduce(0) { $0 + $1.diagnostics.totalLatencyMilliseconds }
        averageLatencyMilliseconds = rows.isEmpty ? 0 : totalLatency / rows.count
    }
}

@MainActor
enum LocalCognitionEvaluationBuilder {
    static let materialFieldIgnoreList: Set<String> = ["summary", "confidence", "provenance"]

    static func rows(from events: [TaskEvent], limit: Int = 20) -> [LocalCognitionEvaluationRow] {
        let evaluationsByDiagnosticsID = latestEvaluationsByDiagnosticsID(events: events)

        return events
            .filter { $0.type == OperationalCognitionEventTypes.localDiagnostics }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { event in
                guard let diagnostics = LocalCognitionRunDiagnostics.decodePayload(event.payload) else {
                    return nil
                }
                return row(
                    event: event,
                    diagnostics: diagnostics,
                    evaluation: evaluationsByDiagnosticsID[event.id]
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func latestEvaluationsByDiagnosticsID(events: [TaskEvent]) -> [UUID: LocalCognitionRunEvaluation] {
        var latest: [UUID: LocalCognitionRunEvaluation] = [:]
        for event in events where event.type == OperationalCognitionEventTypes.localEvaluation {
            guard let evaluation = LocalCognitionRunEvaluation.decodePayload(event.payload) else {
                continue
            }
            if let existing = latest[evaluation.diagnosticsEventID],
               existing.evaluatedAt >= evaluation.evaluatedAt {
                continue
            }
            latest[evaluation.diagnosticsEventID] = evaluation
        }
        return latest
    }

    private static func row(
        event: TaskEvent,
        diagnostics: LocalCognitionRunDiagnostics,
        evaluation: LocalCognitionRunEvaluation?
    ) -> LocalCognitionEvaluationRow {
        let changedFields = unique(diagnostics.jobs.flatMap(\.changedFields))
        let materialFields = changedFields.filter { !materialFieldIgnoreList.contains($0) }
        let comparisons = diagnostics.jobs.map { job in
            LocalCognitionEvaluationComparison(
                id: job.kind.rawValue,
                kind: job.kind,
                status: job.status,
                deterministicSummary: job.deterministicSummary,
                localSummary: job.localSummary,
                changedFields: job.changedFields,
                fallbackReason: job.fallbackReason
            )
        }
        return LocalCognitionEvaluationRow(
            diagnosticsEvent: event,
            diagnostics: diagnostics,
            latestEvaluation: evaluation,
            taskTitle: event.task?.title ?? "Untitled task",
            taskID: event.task?.id,
            runID: event.run?.id,
            changedFields: changedFields,
            materialChangedFields: materialFields,
            comparisons: comparisons
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

@MainActor
enum LocalCognitionEvaluationStore {
    static func record(
        rating: LocalCognitionEvaluationRating,
        diagnosticsEvent: TaskEvent,
        modelContext: ModelContext,
        evaluatedAt: Date = Date()
    ) {
        guard let task = diagnosticsEvent.task else { return }
        let evaluation = LocalCognitionRunEvaluation(
            diagnosticsEventID: diagnosticsEvent.id,
            taskID: task.id,
            runID: diagnosticsEvent.run?.id,
            rating: rating,
            evaluatedAt: evaluatedAt
        )
        guard let payload = evaluation.encodedPayload() else {
            AppLogger.audit(.runtimePersistenceSummary, category: "Cognition", taskID: task.id, fields: [
                "result": "local_evaluation_encode_failed",
                "rating": rating.rawValue
            ], level: .warning)
            return
        }

        let event = TaskEvent(
            task: task,
            type: OperationalCognitionEventTypes.localEvaluation,
            payload: payload,
            run: diagnosticsEvent.run
        )
        event.timestamp = evaluatedAt
        modelContext.insert(event)
        try? modelContext.save()

        AppLogger.audit(.runtimePersistenceSummary, category: "Cognition", taskID: task.id, fields: [
            "result": "local_evaluation_recorded",
            "diagnostics_event_id": diagnosticsEvent.id.uuidString,
            "rating": rating.rawValue
        ])
    }
}
