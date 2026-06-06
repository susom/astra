import SwiftUI

struct WorkspaceAppDetailView: View {
    let app: WorkspaceApp
    let workspace: Workspace?
    let onOpenStudio: () -> Void
    let onRefresh: () -> Void
    let onExportPackage: () throws -> URL
    let onRunAction: (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult

    @State private var dataSnapshot = WorkspaceAppDetailDataSnapshot.empty
    @State private var actionStatusMessage = ""
    @State private var packageStatusMessage = ""
    @State private var activeRecordAction: WorkspaceAppDetailActionPresentation?
    @State private var recordFormValues: [String: String] = [:]
    @State private var recordFormError = ""

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
                    actionsSection
                    storageSection
                    metadataRows
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppDetailView-\(presentation.logicalID)")
        .onAppear(perform: loadDataSnapshot)
        .onChange(of: app.updatedAt) {
            loadDataSnapshot()
        }
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

            Menu {
                Button(action: exportPackage) {
                    Label("Export ASTRA App Package", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Share this app with another ASTRA workspace")
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

            if !packageStatusMessage.isEmpty {
                Text(packageStatusMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    @ViewBuilder
    private var actionsSection: some View {
        let actions = WorkspaceAppDetailActionsPresentation.actions(
            manifest: dataSnapshot.manifest,
            storageTables: dataSnapshot.storageTables
        )
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Actions")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(actions.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(actions) { action in
                        WorkspaceAppActionButton(
                            action: action,
                            onRun: { handleAction(action) }
                        )
                    }
                }

                if let activeRecordAction,
                   let table = storageTable(for: activeRecordAction) {
                    WorkspaceAppStorageRecordForm(
                        action: activeRecordAction,
                        table: table,
                        values: $recordFormValues,
                        errorMessage: recordFormError,
                        onCancel: clearRecordForm,
                        onSubmit: { submitRecordAction(activeRecordAction, table: table) }
                    )
                }

                if !actionStatusMessage.isEmpty {
                    Text(actionStatusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        if let errorMessage = dataSnapshot.errorMessage {
            WorkspaceAppDetailNotice(
                title: "Storage unavailable",
                message: errorMessage,
                systemImage: "exclamationmark.triangle"
            )
        } else if !dataSnapshot.storageTables.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Storage")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(dataSnapshot.storageTables.count) tables")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ForEach(dataSnapshot.storageTables, id: \.name) { table in
                    WorkspaceAppStorageTableView(table: table)
                }
            }
        }
    }

    private func loadDataSnapshot() {
        dataSnapshot = WorkspaceAppDetailDataLoader().load(app: app, workspace: workspace)
    }

    private func handleAction(_ action: WorkspaceAppDetailActionPresentation) {
        if action.type == "appStorage.insert" {
            showRecordForm(for: action)
        } else {
            runAction(action)
        }
    }

    private func showRecordForm(for action: WorkspaceAppDetailActionPresentation) {
        activeRecordAction = action
        recordFormValues = [:]
        recordFormError = ""
    }

    private func clearRecordForm() {
        activeRecordAction = nil
        recordFormValues = [:]
        recordFormError = ""
    }

    private func storageTable(for action: WorkspaceAppDetailActionPresentation) -> WorkspaceAppStorageTable? {
        guard let tableName = action.input.table else { return nil }
        return dataSnapshot.manifest?.storage?.tables.first { $0.name == tableName }
    }

    private func submitRecordAction(
        _ action: WorkspaceAppDetailActionPresentation,
        table: WorkspaceAppStorageTable
    ) {
        do {
            let record = try WorkspaceAppStorageRecordDraftBuilder.record(
                for: table,
                values: recordFormValues
            )
            runAction(
                WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: action.label,
                    type: action.type,
                    isEnabled: action.isEnabled,
                    disabledReason: action.disabledReason,
                    input: WorkspaceAppActionInput(table: table.name, record: record)
                )
            )
            clearRecordForm()
        } catch {
            recordFormError = error.localizedDescription
        }
    }

    private func runAction(_ action: WorkspaceAppDetailActionPresentation) {
        guard let manifest = dataSnapshot.manifest,
              let actionSpec = manifest.actions.first(where: { $0.id == action.id }) else {
            actionStatusMessage = "Action is unavailable."
            return
        }

        do {
            let result = try onRunAction(actionSpec, manifest, action.input)
            actionStatusMessage = result.outputSummary
            loadDataSnapshot()
        } catch {
            actionStatusMessage = String(describing: error)
        }
    }

    private func exportPackage() {
        do {
            let url = try onExportPackage()
            packageStatusMessage = "Exported ASTRA app package to \(url.lastPathComponent)."
        } catch {
            packageStatusMessage = String(describing: error)
        }
    }
}

private struct WorkspaceAppStorageRecordForm: View {
    let action: WorkspaceAppDetailActionPresentation
    let table: WorkspaceAppStorageTable
    @Binding var values: [String: String]
    let errorMessage: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private var fields: [WorkspaceAppStorageFormField] {
        WorkspaceAppStorageRecordDraftBuilder.fields(for: table)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(action.label)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(table.name)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if fields.isEmpty {
                Text("This table has no editable fields.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Text(field.name)
                                    .font(Stanford.caption(11).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if field.isRequired {
                                    Text("required")
                                        .font(Stanford.caption(10).weight(.semibold))
                                        .foregroundStyle(Stanford.statusWarn)
                                }
                            }

                            TextField(field.type, text: binding(for: field.name))
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.caption(12))
                        }
                    }
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusWarn)
            }

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)

                Button(action: onSubmit) {
                    Label("Save Record", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(
            get: { values[field] ?? "" },
            set: { values[field] = $0 }
        )
    }
}

private struct WorkspaceAppActionButton: View {
    let action: WorkspaceAppDetailActionPresentation
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .font(Stanford.ui(14, weight: .semibold))
                    Text(action.label)
                        .font(Stanford.ui(13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(action.disabledReason ?? action.type)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(action.isEnabled ? Stanford.lagunita : .secondary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Color.primary.opacity(action.isEnabled ? 0.025 : 0.015))
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(action.isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .help(action.disabledReason ?? "Run \(action.label)")
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

private struct WorkspaceAppStorageTableView: View {
    let table: WorkspaceAppStorageTableSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(table.name)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(table.rowCount) rows")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if let errorMessage = table.errorMessage {
                WorkspaceAppDetailNotice(
                    title: "Table unavailable",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle"
                )
            } else if table.rows.isEmpty {
                Text("No records yet")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WorkspaceAppStorageHeaderRow(columns: table.columns)
                    ForEach(Array(table.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        WorkspaceAppStorageRecordRow(columns: table.columns, row: row)
                    }
                }
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct WorkspaceAppStorageHeaderRow: View {
    let columns: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.prefix(4), id: \.self) { column in
                Text(column)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
    }
}

private struct WorkspaceAppStorageRecordRow: View {
    let columns: [String]
    let row: [String: WorkspaceAppStorageValue]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.prefix(4), id: \.self) { column in
                Text(displayValue(row[column]))
                    .font(Stanford.caption(12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    private func displayValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            "-"
        case .text(let text):
            text
        case .integer(let integer):
            "\(integer)"
        case .real(let real):
            real.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let bool):
            bool ? "true" : "false"
        }
    }
}

struct WorkspaceAppDetailNotice: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.statusWarn)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Stanford.statusWarn.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
    }
}
