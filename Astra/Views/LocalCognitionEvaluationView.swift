import SwiftData
import SwiftUI
import ASTRACore

struct LocalCognitionEvaluationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var taskEvents: [TaskEvent]

    private var rows: [LocalCognitionEvaluationRow] {
        LocalCognitionEvaluationBuilder.rows(from: taskEvents, limit: 30)
    }

    private var summary: LocalCognitionEvaluationSummary {
        LocalCognitionEvaluationSummary(rows: rows)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryGrid

                if rows.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            evaluationRow(row)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(Stanford.heading(22))
                .foregroundStyle(Stanford.lagunita)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Cognition Evaluation")
                    .font(Stanford.heading(20))
                    .foregroundStyle(Stanford.black)
                Text("Recent advisory traces and manual usefulness ratings.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
            StatCard(title: "Runs", value: "\(summary.totalRuns)", icon: "list.bullet.rectangle", color: Stanford.lagunita)
            StatCard(title: "Rated", value: "\(summary.ratedRuns)", icon: "checkmark.seal", color: Stanford.paloAltoGreen)
            StatCard(title: "Fallbacks", value: "\(summary.fallbackRuns)", icon: "exclamationmark.triangle", color: Stanford.poppy)
            StatCard(title: "Avg Latency", value: latencyLabel(summary.averageLatencyMilliseconds), icon: "timer", color: Stanford.sky)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No local cognition traces yet.")
                .font(Stanford.body(14).weight(.semibold))
                .foregroundStyle(Stanford.black)
            Text("Run a task with local advisory cognition enabled to populate this view.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Stanford.fog)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func evaluationRow(_ row: LocalCognitionEvaluationRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.diagnostics.fallbackJobCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Stanford.ui(15))
                    .foregroundStyle(row.diagnostics.fallbackJobCount > 0 ? Stanford.poppy : Stanford.paloAltoGreen)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.taskTitle)
                        .font(Stanford.body(14).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(2)
                    Text(rowSubtitle(row))
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                ratingBadge(row.rating)
            }

            HStack(spacing: 8) {
                metricPill("\(row.diagnostics.successfulJobCount) local", color: Stanford.paloAltoGreen)
                metricPill("\(row.diagnostics.fallbackJobCount) fallback", color: row.diagnostics.fallbackJobCount > 0 ? Stanford.poppy : Stanford.coolGrey)
                metricPill("\(row.diagnostics.skippedJobCount) skipped", color: Stanford.coolGrey)
                metricPill(latencyLabel(row.diagnostics.totalLatencyMilliseconds), color: Stanford.sky)
                if row.isMateriallyDifferent {
                    metricPill("changed", color: Stanford.lagunita)
                }
            }

            ratingControls(for: row)

            if !row.materialChangedFields.isEmpty {
                factLine("Material fields", value: compactList(row.materialChangedFields, limit: 5))
            } else if !row.changedFields.isEmpty {
                factLine("Changed fields", value: compactList(row.changedFields, limit: 5))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(row.comparisons.prefix(4)) { comparison in
                    comparisonView(comparison)
                }
            }
        }
        .padding(12)
        .background(Stanford.fog.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Stanford.sandstone.opacity(0.35), lineWidth: 1)
        )
    }

    private func ratingControls(for row: LocalCognitionEvaluationRow) -> some View {
        HStack(spacing: 8) {
            ForEach(LocalCognitionEvaluationRating.allCases) { rating in
                Button {
                    LocalCognitionEvaluationStore.record(
                        rating: rating,
                        diagnosticsEvent: row.diagnosticsEvent,
                        modelContext: modelContext
                    )
                } label: {
                    Label(rating.label, systemImage: symbol(for: rating))
                        .font(Stanford.caption(11).weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(row.rating == rating ? color(for: rating) : Stanford.coolGrey)
            }
            Spacer(minLength: 0)
        }
    }

    private func comparisonView(_ comparison: LocalCognitionEvaluationComparison) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(kindLabel(comparison.kind))
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(comparison.status.rawValue)
                    .font(Stanford.caption(10))
                    .foregroundStyle(comparison.status == .fallback ? Stanford.poppy : Stanford.coolGrey)
                if let reason = comparison.fallbackReason {
                    Text(reason)
                        .font(Stanford.caption(10))
                        .foregroundStyle(Stanford.poppy)
                }
            }

            if let deterministic = comparison.deterministicSummary, !deterministic.isEmpty {
                factLine("Deterministic", value: deterministic)
            }
            if let local = comparison.localSummary, !local.isEmpty {
                factLine("Local", value: local)
            }
        }
        .padding(.top, 2)
    }

    private func ratingBadge(_ rating: LocalCognitionEvaluationRating?) -> some View {
        Group {
            if let rating {
                Label(rating.label, systemImage: symbol(for: rating))
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(color(for: rating))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(color(for: rating).opacity(0.12)))
            } else {
                Text("Unrated")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
    }

    private func metricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Stanford.caption(10).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
    }

    private func factLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.readingText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowSubtitle(_ row: LocalCognitionEvaluationRow) -> String {
        [
            row.diagnostics.model,
            row.diagnostics.method,
            row.taskID.map { String($0.uuidString.prefix(8)) }
        ]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " / ")
    }

    private func kindLabel(_ kind: OperationalCognitionJobKind) -> String {
        switch kind {
        case .runSummary:
            "Run summary"
        case .taskHealth:
            "Task health"
        case .attentionSignal:
            "Attention"
        case .stateCompression:
            "State"
        }
    }

    private func symbol(for rating: LocalCognitionEvaluationRating) -> String {
        switch rating {
        case .useful:
            "hand.thumbsup"
        case .sameAsDeterministic:
            "equal.circle"
        case .worseNoisy:
            "hand.thumbsdown"
        }
    }

    private func color(for rating: LocalCognitionEvaluationRating) -> Color {
        switch rating {
        case .useful:
            Stanford.paloAltoGreen
        case .sameAsDeterministic:
            Stanford.coolGrey
        case .worseNoisy:
            Stanford.poppy
        }
    }

    private func latencyLabel(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds)ms"
        }
        return String(format: "%.1fs", Double(milliseconds) / 1_000)
    }

    private func compactList(_ values: [String], limit: Int) -> String {
        let visible = values.prefix(limit).joined(separator: ", ")
        let remaining = values.count - min(values.count, limit)
        return remaining > 0 ? "\(visible) +\(remaining)" : visible
    }
}
