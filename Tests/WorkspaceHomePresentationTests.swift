import Foundation
import Testing
@testable import ASTRA

@Suite("WorkspaceHomePresentation")
struct WorkspaceHomePresentationTests {
    @Test("Workspace context uses lean summary rows")
    func workspaceContextUsesLeanSummaryRows() {
        #expect(WorkspaceHomePresentation.usesWorkspaceContextCard == true)
        #expect(WorkspaceHomePresentation.usesKanbanMeasuredPageRail == true)
        #expect(WorkspaceHomePresentation.contextRowsUseSummaryPattern == true)
        #expect(WorkspaceHomePresentation.contextCardShowsCapabilitiesRow == true)
        #expect(WorkspaceHomePresentation.contextCardAlignsWithBoardColumns == true)
        #expect(WorkspaceHomePresentation.instructionEditorStaysInsideContextCard == true)
        #expect(WorkspaceInstructionPresentation.usesReadableExpandedBlocks == true)
        #expect(WorkspaceHomePresentation.headerShowsWorkspaceStatus == false)
        #expect(WorkspaceHomePresentation.headerUsesOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.headerUsesCompactOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.statusCountsStayOnBoard == true)
        #expect(WorkspaceHomePresentation.instructionsArePrimaryWorkspaceSurface == true)
        #expect(WorkspaceHomePresentation.instructionsExpandByDefaultWhenConfigured == false)
        #expect(WorkspaceHomePresentation.instructionsShowPreviewWhenConfigured == true)
        #expect(WorkspaceHomePresentation.emptyInstructionsUseSinglePrompt == true)
        #expect(WorkspaceHomePresentation.instructionBlockUsesPrimaryCTAWhenEmpty == true)
        #expect(WorkspaceHomePresentation.usesMinimumWelcomeRailWidth == true)
    }

    @Test("Workspace page keeps primary actions and routine rows lean")
    func workspacePageActionsStayLean() {
        #expect(WorkspaceHomePresentation.headerShowsPrimaryNewTaskAction == false)
        #expect(WorkspaceHomePresentation.routinesUseSummaryRows == true)
        #expect(WorkspaceAppsPresentation.appCardsAppearBeforeTasks == true)
        #expect(WorkspaceAppsPresentation.hidesEmptySection == true)
        #expect(WorkspaceAppsPresentation.sectionTitle == "Apps")
        #expect(WorkspaceAppsPresentation.newAppActionTitle == "New App")
        #expect(WorkspaceAppsPresentation.sectionIsUnframed == true)
        #expect(WorkspaceHomePresentation.rowIconFrame == 40)
        #expect(WorkspaceHomePresentation.rowMinHeight == 72)
        #expect(WorkspaceHomePresentation.cardCornerRadius == 12)
        #expect(WorkspaceAppsPresentation.cardCornerRadius == 8)
        #expect(WorkspaceAppsPresentation.cardMinHeight == WorkspaceHomePresentation.rowMinHeight)
        #expect(WorkspaceHomePresentation.minimumWelcomeRailWidth == 920)
        #expect(WorkspaceInstructionPresentation.emptyPromptTitle == "Tell the agent how you work")
        #expect(WorkspaceInstructionPresentation.emptyPromptBody == "Add conventions, tone, and what to avoid. They apply to every task in this workspace.")
        #expect(WorkspaceInstructionPresentation.emptyActionTitle == "Add instructions")
        #expect(WorkspaceInstructionPresentation.configuredSubtitle == "Workspace prompt")
        #expect(WorkspaceInstructionPresentation.previewItemLimit == 2)
    }

    @Test("Workspace instructions summarize and group repeated guidance")
    func workspaceInstructionsSummarizeAndGroupRepeatedGuidance() {
        let instructions = """
        try to use Test-driven development (TDD) , write regression and e2e test . validate results by runnign the full test suite. on git pull requests: always use first principles to adres the isues found. once a solution is in please add detailed comments for the reviewer.

        try to use Test-driven development (TDD) , write regression and e2e test . validate results by runnign the full test suite.

        on git pull requests:
        always use first principles to adres the isues found.
        once a solution is in please add detailed comments for the reviewer.
        """

        let blocks = WorkspaceInstructionPresentation.blocks(from: instructions)

        #expect(WorkspaceInstructionPresentation.subtitle(for: instructions) == "4 guidance items")
        #expect(WorkspaceInstructionPresentation.previewItems(from: instructions) == [
            "try to use Test-driven development (TDD), write regression and e2e test.",
            "validate results by runnign the full test suite."
        ])
        #expect(blocks == [
            WorkspaceInstructionBlock(title: nil, items: [
                "try to use Test-driven development (TDD), write regression and e2e test.",
                "validate results by runnign the full test suite."
            ]),
            WorkspaceInstructionBlock(title: "On git pull requests", items: [
                "always use first principles to adres the isues found.",
                "once a solution is in please add detailed comments for the reviewer."
            ])
        ])
    }

    @Test("Workspace apps presentation hides empty state and sorts active apps first")
    func workspaceAppsPresentationHidesEmptyStateAndSortsActiveAppsFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = WorkspaceApp(
            workspaceID: UUID(),
            logicalID: "draft-app",
            name: "Draft App",
            icon: "",
            appDescription: "",
            lifecycleStatus: .draft,
            permissionMode: .draftOnly,
            dependencyStatus: .unresolved,
            manifestRelativePath: ".astra/apps/draft-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/draft-app",
            manifestDigest: "digest",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-7_200)
        )
        let recent = WorkspaceApp(
            workspaceID: older.workspaceID,
            logicalID: "published-app",
            name: "Published App",
            icon: "chart.bar",
            appDescription: "Shows actionable metrics.",
            lifecycleStatus: .published,
            permissionMode: .readOnly,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/published-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/published-app",
            manifestDigest: "digest",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-60)
        )
        recent.lastRunAt = now.addingTimeInterval(-300)

        let cards = WorkspaceAppsPresentation.cards(for: [older, recent], now: now)

        #expect(WorkspaceAppsPresentation.shouldShowSection(apps: []) == false)
        #expect(WorkspaceAppsPresentation.shouldShowSection(apps: [older]) == true)
        #expect(cards.map { $0.logicalID } == ["published-app", "draft-app"])
        #expect(cards[0].icon == "chart.bar")
        #expect(cards[0].subtitle == "Shows actionable metrics.")
        #expect(cards[0].statusLabel == "Published")
        #expect(cards[0].dependencyLabel == nil)
        #expect(cards[0].lastActivityLabel == "Run 5m ago")
        #expect(cards[0].primaryActionTitle == "Open")
        #expect(cards[1].icon == "square.grid.2x2")
        #expect(cards[1].subtitle == "Workspace app")
        #expect(cards[1].statusLabel == "Draft")
        #expect(cards[1].dependencyLabel == "Needs mapping")
        #expect(cards[1].primaryActionTitle == "Open draft")
    }

    @Test("Workspace app detail presentation exposes status permission and action readiness")
    func workspaceAppDetailPresentationExposesStatusPermissionAndActionReadiness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = WorkspaceApp(
            workspaceID: UUID(),
            logicalID: "metrics-app",
            name: "Metrics App",
            icon: "chart.bar",
            appDescription: "Shows actionable metrics.",
            lifecycleStatus: .published,
            permissionMode: .preApproved,
            dependencyStatus: .ready,
            manifestRelativePath: ".astra/apps/metrics-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/metrics-app",
            manifestDigest: "digest",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-60)
        )
        ready.lastOpenedAt = now.addingTimeInterval(-120)
        let blocked = WorkspaceApp(
            workspaceID: ready.workspaceID,
            logicalID: "blocked-app",
            name: "Blocked App",
            icon: "",
            appDescription: "",
            lifecycleStatus: .blocked,
            permissionMode: .approvalRequired,
            dependencyStatus: .missingRequired,
            manifestRelativePath: ".astra/apps/blocked-app/manifest.json",
            appDirectoryRelativePath: ".astra/apps/blocked-app",
            manifestDigest: "digest",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-60)
        )

        let readyDetail = WorkspaceAppsPresentation.detail(for: ready, now: now)
        let blockedDetail = WorkspaceAppsPresentation.detail(for: blocked, now: now)

        #expect(readyDetail.logicalID == "metrics-app")
        #expect(readyDetail.permissionLabel == "Pre-approved")
        #expect(readyDetail.surfaceTitle == "App surface")
        #expect(readyDetail.surfaceSubtitle == "This app can run pre-approved actions inside its capability contract.")
        #expect(readyDetail.lastActivityLabel == "Opened 2m ago")
        #expect(readyDetail.canRunLocalActions == true)
        #expect(blockedDetail.icon == "square.grid.2x2")
        #expect(blockedDetail.dependencyLabel == "Missing dependency")
        #expect(blockedDetail.permissionLabel == "Approval required")
        #expect(blockedDetail.surfaceTitle == "Review required")
        #expect(blockedDetail.surfaceSubtitle == "Resolve dependencies before running live actions.")
        #expect(blockedDetail.canRunLocalActions == false)
    }

    @Test("Workspace app detail actions enable storage queries and inserts")
    func workspaceAppDetailActionsEnableStorageQueriesAndInserts() throws {
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "grocery", name: "Grocery"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "price", type: "double"),
                    WorkspaceAppStorageColumn(name: "purchased", type: "bool")
                ])
            ]),
            actions: [
                WorkspaceAppActionSpec(id: "listItems", type: "appStorage.query", label: "List Items"),
                WorkspaceAppActionSpec(id: "addItem", type: "appStorage.insert", label: "Add Item"),
                WorkspaceAppActionSpec(id: "submit", type: "capability.write", label: "Submit")
            ]
        )
        let storageTables = [
            WorkspaceAppStorageTableSnapshot(
                name: "items",
                columns: ["id", "name"],
                rows: [],
                errorMessage: nil
            )
        ]

        let actions = WorkspaceAppDetailActionsPresentation.actions(
            manifest: manifest,
            storageTables: storageTables
        )

        #expect(actions.count == 3)
        #expect(actions[0].id == "listItems")
        #expect(actions[0].isEnabled)
        #expect(actions[0].input.table == "items")
        #expect(actions[1].id == "addItem")
        #expect(actions[1].isEnabled)
        #expect(actions[1].input.table == "items")
        #expect(actions[2].id == "submit")
        #expect(!actions[2].isEnabled)
        #expect(actions[2].disabledReason == "This action type is not wired into the app renderer yet.")

        let table = try #require(manifest.storage?.tables.first)
        let fields = WorkspaceAppStorageRecordDraftBuilder.fields(for: table)
        #expect(fields.map(\.name) == ["name", "price", "purchased"])

        let record = try WorkspaceAppStorageRecordDraftBuilder.record(
            for: table,
            values: ["name": "Apples", "price": "2.49", "purchased": "yes"],
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000123")! }
        )
        #expect(record["id"] == .text("00000000-0000-0000-0000-000000000123"))
        #expect(record["name"] == .text("Apples"))
        #expect(record["price"] == .real(2.49))
        #expect(record["purchased"] == .bool(true))
    }

    @Test("Workspace app storage record draft validates required and typed input")
    func workspaceAppStorageRecordDraftValidatesRequiredAndTypedInput() throws {
        let table = WorkspaceAppStorageTable(name: "items", columns: [
            WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
            WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
            WorkspaceAppStorageColumn(name: "quantity", type: "integer"),
            WorkspaceAppStorageColumn(name: "purchased", type: "bool")
        ])

        #expect(throws: WorkspaceAppStorageRecordDraftError.missingRequiredField("name")) {
            try WorkspaceAppStorageRecordDraftBuilder.record(for: table, values: [:])
        }
        #expect(throws: WorkspaceAppStorageRecordDraftError.invalidValue(field: "quantity", type: "integer", value: "many")) {
            try WorkspaceAppStorageRecordDraftBuilder.record(for: table, values: [
                "name": "Apples",
                "quantity": "many"
            ])
        }
        #expect(throws: WorkspaceAppStorageRecordDraftError.invalidValue(field: "purchased", type: "bool", value: "maybe")) {
            try WorkspaceAppStorageRecordDraftBuilder.record(for: table, values: [
                "name": "Apples",
                "purchased": "maybe"
            ])
        }
    }

    @Test("App Studio turns a local database intent into a valid publishable draft")
    func appStudioBuildsValidLocalDatabaseDraft() {
        let workspace = Workspace(name: "Household", primaryPath: "/tmp/household")

        let draft = WorkspaceAppStudioBuilder.draft(
            intent: "Build me a database app to store my groceries.",
            workspace: workspace
        )

        #expect(draft.workspaceID == workspace.id)
        #expect(draft.canPublish)
        #expect(draft.manifest.app.id == "grocery-tracker")
        #expect(draft.manifest.storage?.tables.map(\.name) == ["items", "shopping_lists", "purchases"])
        #expect(draft.manifest.views.map(\.type).contains("dashboard"))
        #expect(draft.manifest.actions.contains { $0.type == "appStorage.insert" })
        #expect(draft.manifest.permissions.defaultMode == .draftOnly)
    }

    @Test("App Studio publishing assigns unique logical IDs")
    func appStudioPublishManifestAvoidsExistingLogicalIDs() {
        let workspace = Workspace(name: "Household", primaryPath: "/tmp/household")
        let draft = WorkspaceAppStudioBuilder.draft(
            intent: "Build me a database app to store my groceries.",
            workspace: workspace
        )

        let manifest = WorkspaceAppStudioBuilder.manifestForPublishing(
            draft.manifest,
            existingLogicalIDs: ["grocery-tracker", "grocery-tracker-2"]
        )

        #expect(manifest.app.id == "grocery-tracker-3")
        #expect(manifest.app.name == "Grocery Tracker 3")
    }
}
