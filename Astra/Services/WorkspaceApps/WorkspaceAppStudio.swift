import Foundation

struct WorkspaceAppStudioProposal: Sendable, Equatable {
    var name: String
    var problem: String
    var storage: [String]
    var views: [String]
    var actions: [String]
    var automation: [String]
    var riskMode: WorkspaceAppPermissionMode
}

struct WorkspaceAppStudioDraft: Identifiable, Sendable, Equatable {
    var id: UUID
    var workspaceID: UUID
    var sourceAppID: UUID?
    var intent: String
    var proposal: WorkspaceAppStudioProposal
    var manifest: WorkspaceAppManifest
    var validationReport: WorkspaceAppManifestValidationReport

    var canPublish: Bool {
        validationReport.isValid
    }
}

enum WorkspaceAppStudioBuilder {
    static let defaultIntent = "Build me a database app to store my groceries."

    static func draft(
        intent rawIntent: String,
        workspace: Workspace,
        existingManifest: WorkspaceAppManifest? = nil
    ) -> WorkspaceAppStudioDraft {
        let intent = normalizedIntent(rawIntent)
        let manifest = existingManifest ?? manifest(for: intent)
        let proposal = proposal(for: intent, manifest: manifest)
        let report = WorkspaceAppManifestValidator.validate(manifest)

        return WorkspaceAppStudioDraft(
            id: UUID(),
            workspaceID: workspace.id,
            sourceAppID: nil,
            intent: intent,
            proposal: proposal,
            manifest: manifest,
            validationReport: report
        )
    }

    static func manifestForPublishing(
        _ manifest: WorkspaceAppManifest,
        existingLogicalIDs: Set<String>
    ) -> WorkspaceAppManifest {
        guard existingLogicalIDs.contains(manifest.app.id) else {
            return manifest
        }

        var copy = manifest
        let baseID = manifest.app.id
        var suffix = 2
        while existingLogicalIDs.contains("\(baseID)-\(suffix)") {
            suffix += 1
        }
        copy.app.id = "\(baseID)-\(suffix)"
        copy.app.name = "\(manifest.app.name) \(suffix)"
        return copy
    }

    private static func manifest(for intent: String) -> WorkspaceAppManifest {
        if isLocalDatabaseIntent(intent) {
            return localDatabaseManifest(intent: intent)
        }
        return operationalSurfaceManifest(intent: intent)
    }

    private static func proposal(
        for intent: String,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioProposal {
        WorkspaceAppStudioProposal(
            name: manifest.app.name,
            problem: manifest.app.description,
            storage: manifest.storage?.tables.map(\.name) ?? [],
            views: manifest.views.map { $0.title ?? $0.id },
            actions: manifest.actions.map { $0.label ?? $0.id },
            automation: manifest.automations.map(\.id),
            riskMode: manifest.permissions.defaultMode
        )
    }

    private static func localDatabaseManifest(intent: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-tracker",
                name: "Grocery Tracker",
                icon: "cart",
                description: "Track grocery items, shopping lists, stores, and purchases from a local app database.",
                tags: ["local-storage", "database"],
                archetypes: ["Local Database App", "Action Panel"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text"),
                    WorkspaceAppStorageColumn(name: "preferred_store", type: "text"),
                    WorkspaceAppStorageColumn(name: "last_price", type: "double"),
                    WorkspaceAppStorageColumn(name: "in_stock", type: "bool")
                ]),
                WorkspaceAppStorageTable(name: "shopping_lists", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true)
                ]),
                WorkspaceAppStorageTable(name: "purchases", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "item_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "store", type: "text"),
                    WorkspaceAppStorageColumn(name: "price", type: "double"),
                    WorkspaceAppStorageColumn(name: "purchased_at", type: "date")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "local_grocery_tables", mode: "read", sourceRef: "appStorage")
            ],
            views: [
                WorkspaceAppViewSpec(id: "items_table", type: "table", title: "Items", table: "items"),
                WorkspaceAppViewSpec(id: "shopping_list", type: "form", title: "Shopping List"),
                WorkspaceAppViewSpec(
                    id: "spend_metrics",
                    type: "dashboard",
                    title: "Spend Metrics",
                    table: "purchases",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "item_count",
                            type: "metric",
                            label: "Tracked items",
                            table: "items",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "total_spend",
                            type: "metric",
                            label: "Total spend",
                            field: "price",
                            aggregation: "sum"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "spend_by_store",
                            type: "chart",
                            label: "Spend by store",
                            field: "price",
                            groupBy: "store",
                            aggregation: "sum"
                        )
                    ]
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List Items"),
                WorkspaceAppActionSpec(id: "add_item", type: "appStorage.insert", label: "Add Item"),
                WorkspaceAppActionSpec(
                    id: "create_shopping_task",
                    type: "task.createDraft",
                    label: "Create Shopping Task",
                    taskTitle: "Plan next grocery trip",
                    taskGoal: "Review the grocery tracker records and draft a focused shopping plan for the next trip."
                ),
                WorkspaceAppActionSpec(
                    id: "export_items",
                    type: "artifact.export",
                    label: "Export Items",
                    table: "items",
                    exportFormat: "csv"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: .draftOnly
            )
        )
    }

    private static func operationalSurfaceManifest(intent: String) -> WorkspaceAppManifest {
        let name = title(from: intent)
        let id = slug(from: name)
        return WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: id,
                name: name,
                icon: "rectangle.3.group",
                description: "Draft operational app surface generated from the requested workflow.",
                tags: ["draft", "workspace-app"],
                archetypes: ["Dashboard", "Action Panel"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "notes", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_context", mode: "read", sourceRef: "workspace")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "overview",
                    type: "dashboard",
                    title: "Overview",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_item_count",
                            type: "metric",
                            label: "Review items",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "review_status_chart",
                            type: "chart",
                            label: "Items by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "review_queue", type: "table", title: "Review Queue", table: "review_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_review_items", type: "appStorage.query", label: "List Review Items"),
                WorkspaceAppActionSpec(
                    id: "create_review_task",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review workspace app items",
                    taskGoal: "Review the current app records, identify the next manual decision, and summarize recommended follow-up."
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: .draftOnly
            )
        )
    }

    private static func normalizedIntent(_ rawIntent: String) -> String {
        let trimmed = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIntent : trimmed
    }

    private static func isLocalDatabaseIntent(_ intent: String) -> Bool {
        let lowercased = intent.lowercased()
        return lowercased.contains("database")
            || lowercased.contains("store my")
            || lowercased.contains("grocery")
            || lowercased.contains("tracker")
    }

    private static func title(from intent: String) -> String {
        let words = intent
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        let title = words.joined(separator: " ")
        return title.isEmpty ? "Workspace App" : title
    }

    private static func slug(from title: String) -> String {
        let parts = title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "workspace-app" : slug
    }
}
