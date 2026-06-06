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

    static func draft(
        from idea: WorkspaceAppStudioIdea,
        workspace: Workspace
    ) -> WorkspaceAppStudioDraft {
        let manifest = manifest(for: idea)
        let proposal = WorkspaceAppStudioProposal(
            name: idea.name,
            problem: idea.problem,
            storage: idea.appStorage,
            views: idea.mainViews,
            actions: idea.actions,
            automation: idea.automation,
            riskMode: idea.riskMode
        )
        let report = WorkspaceAppManifestValidator.validate(manifest)
        return WorkspaceAppStudioDraft(
            id: UUID(),
            workspaceID: workspace.id,
            sourceAppID: nil,
            intent: idea.accelerationRationale,
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

    private static func manifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        if idea.id == "bq-redcap-reconciliation" {
            return reconciliationManifest(for: idea)
        }
        if idea.id == "pipeline-review-queue" {
            return pipelineReviewQueueManifest(for: idea)
        }
        if idea.id == "weekly-report-generator" {
            return reportGeneratorManifest(for: idea)
        }
        return operationalSurfaceManifest(intent: idea.name)
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

    private static func reconciliationManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "checklist.checked",
                description: idea.problem,
                tags: ["reconciliation", "redcap", "bigquery"],
                archetypes: ["Reconciliation App", "Dashboard", "Review Queue"]
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    minVersion: "1.0.0",
                    operations: ["describeTable", "runReadOnlyQuery"],
                    providerHint: "bigQuery",
                    dataClass: "sensitive"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    minVersion: "1.0.0",
                    operations: ["describeProject", "readRecords", "validateRecord"],
                    providerHint: "redcap",
                    dataClass: "sensitive"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "source_record_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "match_status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "notes", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "latest_candidates",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    query: "SELECT * FROM clinical.enrollment_candidates ORDER BY updated_at DESC LIMIT 100"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    mode: "read",
                    projectRef: "enrollment-study"
                )
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "dashboard",
                    type: "dashboard",
                    title: "Reconciliation Dashboard",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_count",
                            type: "metric",
                            label: "Records to review",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "status_chart",
                            type: "chart",
                            label: "Records by status",
                            groupBy: "match_status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "exceptions", type: "reviewQueue", title: "Exceptions", table: "review_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_review_items", type: "appStorage.query", label: "List Review Items", table: "review_items"),
                WorkspaceAppActionSpec(id: "refresh", type: "pipeline.run", label: "Refresh", steps: ["list_review_items"]),
                WorkspaceAppActionSpec(
                    id: "create_review_task",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review missing REDCap records",
                    taskGoal: "Review missing or ambiguous REDCap records from the reconciliation app and recommend follow-up."
                ),
                WorkspaceAppActionSpec(
                    id: "export_missing",
                    type: "artifact.export",
                    label: "Export Missing Records",
                    table: "review_items",
                    exportFormat: "csv"
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "daily_refresh", type: "schedule", action: "refresh")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["tabularQuery.read", "recordProject.read"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
            )
        )
    }

    private static func pipelineReviewQueueManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "arrow.triangle.branch",
                description: idea.problem,
                tags: ["pipeline", "review"],
                archetypes: ["Pipeline", "Review Queue"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "pipeline_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "step", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "owner", type: "text"),
                    WorkspaceAppStorageColumn(name: "updated_at", type: "datetime")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_process", mode: "read", sourceRef: "conversation")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "pipeline_overview",
                    type: "pipelineRun",
                    title: "Pipeline Overview",
                    table: "pipeline_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "step_count",
                            type: "metric",
                            label: "Tracked steps",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "status_breakdown",
                            type: "chart",
                            label: "Steps by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "approval_queue", type: "reviewQueue", title: "Approval Queue", table: "pipeline_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_pipeline_items", type: "appStorage.query", label: "List Pipeline Items", table: "pipeline_items"),
                WorkspaceAppActionSpec(id: "run_pipeline", type: "pipeline.run", label: "Run Pipeline", steps: ["list_pipeline_items"]),
                WorkspaceAppActionSpec(
                    id: "create_followup_task",
                    type: "task.createDraft",
                    label: "Create Follow-up Task",
                    taskTitle: "Follow up on pipeline exception",
                    taskGoal: "Review the selected pipeline exception, identify the blocker, and draft the next action."
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "weekday_monitor", type: "monitor", action: "run_pipeline")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
            )
        )
    }

    private static func reportGeneratorManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "doc.text.magnifyingglass",
                description: idea.problem,
                tags: ["report", "artifact"],
                archetypes: ["Report Generator", "Dashboard"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "report_runs", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "period", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "artifact_path", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_artifacts", mode: "read", sourceRef: "artifacts")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "report_dashboard",
                    type: "dashboard",
                    title: "Report Dashboard",
                    table: "report_runs",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "report_count",
                            type: "metric",
                            label: "Reports",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "report_status",
                            type: "chart",
                            label: "Reports by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "report_history", type: "table", title: "Report History", table: "report_runs")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "draft_report_task",
                    type: "task.createDraft",
                    label: "Draft Report Task",
                    taskTitle: "Generate workspace report",
                    taskGoal: "Compile selected workspace records and artifacts into a concise report draft."
                ),
                WorkspaceAppActionSpec(
                    id: "export_report_runs",
                    type: "artifact.export",
                    label: "Export Report Runs",
                    table: "report_runs",
                    exportFormat: "json"
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "weekly_report", type: "schedule", action: "draft_report_task")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "task.artifacts", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
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
