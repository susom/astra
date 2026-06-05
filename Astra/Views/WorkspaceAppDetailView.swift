import SwiftUI

struct WorkspaceAppDetailView: View {
    let app: WorkspaceApp
    let workspace: Workspace?
    let onOpenStudio: () -> Void
    let onRefresh: () -> Void

    private var presentation: WorkspaceAppDetailPresentation {
        WorkspaceAppsPresentation.detail(for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appSurface
                    metadataRows
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppDetailView-\(presentation.logicalID)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: presentation.icon)
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.name)
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(workspace?.name ?? "Workspace app")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            WorkspaceAppStatusPill(
                label: presentation.statusLabel,
                systemImage: presentation.statusSystemImage
            )

            if let dependencyLabel = presentation.dependencyLabel,
               let dependencySystemImage = presentation.dependencySystemImage {
                WorkspaceAppStatusPill(
                    label: dependencyLabel,
                    systemImage: dependencySystemImage,
                    isWarning: true
                )
            }

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app data")

            Button(action: onOpenStudio) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Open in App Studio")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Stanford.cardBackground)
    }

    private var appSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(presentation.surfaceTitle)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(presentation.permissionLabel)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(presentation.subtitle)
                .font(Stanford.ui(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.surfaceSubtitle)
                .font(Stanford.ui(13))
                .foregroundStyle(presentation.canRunLocalActions ? .secondary : Stanford.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var metadataRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceAppMetadataRow(label: "Identifier", value: presentation.logicalID)
            WorkspaceAppMetadataRow(label: "Manifest", value: app.manifestRelativePath)
            WorkspaceAppMetadataRow(label: "Storage", value: app.appDirectoryRelativePath)
            WorkspaceAppMetadataRow(label: "Activity", value: presentation.lastActivityLabel)
        }
        .font(Stanford.caption(12))
    }
}

private struct WorkspaceAppMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
