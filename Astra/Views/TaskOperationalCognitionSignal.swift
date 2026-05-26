import Foundation
import ASTRACore

struct TaskOperationalCognitionSignal: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case aiReview
        case localFallback
    }

    let kind: Kind
    let title: String
    let summary: String
    let compactLabel: String
    let systemImage: String
    let isWarning: Bool

    var helpText: String {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return title }
        return "\(title): \(trimmedSummary)"
    }

    static func latest(for task: AgentTask) -> TaskOperationalCognitionSignal? {
        let diagnosticsEvents = task.events.filter {
            $0.type == OperationalCognitionEventTypes.localDiagnostics
        }
        guard let event = diagnosticsEvents.max(by: { $0.timestamp < $1.timestamp }),
              let diagnostics = LocalCognitionRunDiagnostics.decodePayload(event.payload) else {
            return nil
        }
        return signal(from: diagnostics)
    }

    private static func signal(from diagnostics: LocalCognitionRunDiagnostics) -> TaskOperationalCognitionSignal? {
        if let summary = primaryLocalSummary(from: diagnostics) {
            return TaskOperationalCognitionSignal(
                kind: .aiReview,
                title: "AI review",
                summary: summary,
                compactLabel: "AI review",
                systemImage: "sparkles",
                isWarning: diagnostics.fallbackJobCount > 0
            )
        }

        guard diagnostics.fallbackJobCount > 0 else {
            return nil
        }

        return TaskOperationalCognitionSignal(
            kind: .localFallback,
            title: "Local cognition fallback",
            summary: "ASTRA used deterministic advisories because local cognition did not produce usable output.",
            compactLabel: "AI fallback",
            systemImage: "exclamationmark.triangle",
            isWarning: true
        )
    }

    private static func primaryLocalSummary(from diagnostics: LocalCognitionRunDiagnostics) -> String? {
        let preferredKinds: [OperationalCognitionJobKind] = [
            .taskHealth,
            .runSummary,
            .stateCompression,
            .attentionSignal
        ]

        for kind in preferredKinds {
            if let summary = diagnostics.jobs.first(where: { $0.kind == kind && $0.status == .success })?.localSummary,
               let trimmed = nonEmpty(summary) {
                return trimmed
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
