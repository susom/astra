import SwiftUI

struct WorkspaceAppStudioView: View {
    let workspace: Workspace
    let initialIntent: String
    let existingManifest: WorkspaceAppManifest?
    let onCancel: () -> Void
    let onPublish: (WorkspaceAppStudioDraft) throws -> Void

    @State private var intent: String
    @State private var draft: WorkspaceAppStudioDraft
    @State private var statusMessage = ""

    init(
        workspace: Workspace,
        initialIntent: String = WorkspaceAppStudioBuilder.defaultIntent,
        existingManifest: WorkspaceAppManifest? = nil,
        onCancel: @escaping () -> Void,
        onPublish: @escaping (WorkspaceAppStudioDraft) throws -> Void
    ) {
        self.workspace = workspace
        self.initialIntent = initialIntent
        self.existingManifest = existingManifest
        self.onCancel = onCancel
        self.onPublish = onPublish
        let generatedDraft = WorkspaceAppStudioBuilder.draft(
            intent: initialIntent,
            workspace: workspace,
            existingManifest: existingManifest
        )
        _intent = State(initialValue: generatedDraft.intent)
        _draft = State(initialValue: generatedDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intentSection
                    proposalSection
                    validationSection
                    manifestSection
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppStudioView")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("App Studio")
                    .font(Stanford.heading(20))
                    .foregroundStyle(.primary)

                Text(workspace.name)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)

            Button(action: publishDraft) {
                Label("Publish", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.canPublish)
            .help(draft.canPublish ? "Publish this Workspace App" : "Resolve validation blockers before publishing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Intent", count: nil)

            TextEditor(text: $intent)
                .font(Stanford.ui(14))
                .frame(minHeight: 92)
                .padding(8)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button(action: regenerateDraft) {
                    Label("Generate Draft", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.bordered)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var proposalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Proposal", count: nil)

            VStack(alignment: .leading, spacing: 8) {
                Text(draft.proposal.name)
                    .font(Stanford.ui(17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(draft.proposal.problem)
                    .font(Stanford.caption(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                proposalCard(title: "Storage", values: draft.proposal.storage, icon: "externaldrive")
                proposalCard(title: "Views", values: draft.proposal.views, icon: "rectangle.grid.2x2")
                proposalCard(title: "Actions", values: draft.proposal.actions, icon: "play.circle")
                proposalCard(title: "Automation", values: draft.proposal.automation, icon: "clock.arrow.circlepath")
                proposalCard(title: "Permission Mode", values: [draft.proposal.riskMode.rawValue], icon: "lock.shield")
            }
        }
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Validation",
                count: draft.validationReport.issues.isEmpty ? nil : draft.validationReport.issues.count
            )

            if draft.validationReport.issues.isEmpty {
                WorkspaceAppDetailNotice(
                    title: "Ready to publish",
                    message: "The manifest is valid. Schedules remain disabled until explicitly enabled.",
                    systemImage: "checkmark.seal"
                )
            } else {
                ForEach(Array(draft.validationReport.issues.enumerated()), id: \.offset) { _, issue in
                    WorkspaceAppDetailNotice(
                        title: issue.severity.rawValue.capitalized,
                        message: "\(issue.path): \(issue.message)",
                        systemImage: issue.severity == .blocker ? "xmark.octagon" : "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Manifest", count: nil)

            VStack(alignment: .leading, spacing: 8) {
                manifestRow("ID", draft.manifest.app.id)
                manifestRow("Name", draft.manifest.app.name)
                manifestRow("Views", "\(draft.manifest.views.count)")
                manifestRow("Actions", "\(draft.manifest.actions.count)")
                manifestRow("Storage Tables", "\(draft.manifest.storage?.tables.count ?? 0)")
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Stanford.caption(13).weight(.semibold))
                .foregroundStyle(.primary)
            if let count {
                Text("\(count)")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func proposalCard(title: String, values: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 18)

                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if values.isEmpty {
                Text("None")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func manifestRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary)
        }
    }

    private func regenerateDraft() {
        draft = WorkspaceAppStudioBuilder.draft(
            intent: intent,
            workspace: workspace,
            existingManifest: existingManifest
        )
        statusMessage = "Draft regenerated."
    }

    private func publishDraft() {
        do {
            try onPublish(draft)
            statusMessage = "Published."
        } catch {
            statusMessage = String(describing: error)
        }
    }
}
