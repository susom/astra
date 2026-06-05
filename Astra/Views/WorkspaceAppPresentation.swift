import Foundation
import SwiftUI

struct WorkspaceAppCardPresentation: Identifiable, Equatable {
    var id: UUID
    var logicalID: String
    var name: String
    var icon: String
    var subtitle: String
    var statusLabel: String
    var statusSystemImage: String
    var dependencyLabel: String?
    var dependencySystemImage: String?
    var lastActivityLabel: String
    var primaryActionTitle: String
}

struct WorkspaceAppDetailPresentation: Equatable {
    var id: UUID
    var logicalID: String
    var name: String
    var icon: String
    var subtitle: String
    var statusLabel: String
    var statusSystemImage: String
    var dependencyLabel: String?
    var dependencySystemImage: String?
    var lastActivityLabel: String
    var permissionLabel: String
    var surfaceTitle: String
    var surfaceSubtitle: String
    var canRunLocalActions: Bool
}

struct WorkspaceAppDetailActionPresentation: Identifiable, Equatable {
    var id: String
    var label: String
    var type: String
    var isEnabled: Bool
    var disabledReason: String?
    var input: WorkspaceAppActionInput
}

enum WorkspaceAppDetailActionsPresentation {
    static func actions(
        manifest: WorkspaceAppManifest?,
        storageTables: [WorkspaceAppStorageTableSnapshot]
    ) -> [WorkspaceAppDetailActionPresentation] {
        guard let manifest else { return [] }
        return manifest.actions.map { action in
            presentation(for: action, storageTables: storageTables)
        }
    }

    private static func presentation(
        for action: WorkspaceAppActionSpec,
        storageTables: [WorkspaceAppStorageTableSnapshot]
    ) -> WorkspaceAppDetailActionPresentation {
        let label = action.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.type {
        case "appStorage.query":
            guard let table = storageTables.first?.name else {
                return WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: label?.isEmpty == false ? label! : action.id,
                    type: action.type,
                    isEnabled: false,
                    disabledReason: "No app storage table is available.",
                    input: WorkspaceAppActionInput()
                )
            }
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(table: table)
            )

        case "appStorage.insert", "appStorage.update", "appStorage.delete":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: false,
                disabledReason: "This action needs record input before it can run.",
                input: WorkspaceAppActionInput()
            )

        default:
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: false,
                disabledReason: "This action type is not wired into the app renderer yet.",
                input: WorkspaceAppActionInput()
            )
        }
    }
}

enum WorkspaceAppsPresentation {
    static let sectionTitle = "Apps"
    static let newAppActionTitle = "New App"
    static let editActionTitle = "Open in App Studio"
    static let appCardsAppearBeforeTasks = true
    static let hidesEmptySection = true
    static let sectionIsUnframed = true
    static let cardCornerRadius: CGFloat = 8
    static let cardMinHeight = WorkspaceHomePresentation.rowMinHeight

    static func cards(
        for apps: [WorkspaceApp],
        now: Date = Date()
    ) -> [WorkspaceAppCardPresentation] {
        apps
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { card(for: $0, now: now) }
    }

    static func shouldShowSection(apps: [WorkspaceApp]) -> Bool {
        !apps.isEmpty
    }

    static func detail(for app: WorkspaceApp, now: Date = Date()) -> WorkspaceAppDetailPresentation {
        WorkspaceAppDetailPresentation(
            id: app.id,
            logicalID: app.logicalID,
            name: normalizedName(for: app),
            icon: normalizedIcon(for: app),
            subtitle: subtitle(for: app),
            statusLabel: statusLabel(for: app.lifecycleStatus),
            statusSystemImage: statusSystemImage(for: app.lifecycleStatus),
            dependencyLabel: dependencyLabel(for: app.dependencyStatus),
            dependencySystemImage: dependencySystemImage(for: app.dependencyStatus),
            lastActivityLabel: lastActivityLabel(for: app, now: now),
            permissionLabel: permissionLabel(for: app.permissionMode),
            surfaceTitle: surfaceTitle(for: app),
            surfaceSubtitle: surfaceSubtitle(for: app),
            canRunLocalActions: app.lifecycleStatus != .disabled && app.dependencyStatus == .ready
        )
    }

    private static func card(for app: WorkspaceApp, now: Date) -> WorkspaceAppCardPresentation {
        WorkspaceAppCardPresentation(
            id: app.id,
            logicalID: app.logicalID,
            name: normalizedName(for: app),
            icon: normalizedIcon(for: app),
            subtitle: subtitle(for: app),
            statusLabel: statusLabel(for: app.lifecycleStatus),
            statusSystemImage: statusSystemImage(for: app.lifecycleStatus),
            dependencyLabel: dependencyLabel(for: app.dependencyStatus),
            dependencySystemImage: dependencySystemImage(for: app.dependencyStatus),
            lastActivityLabel: lastActivityLabel(for: app, now: now),
            primaryActionTitle: primaryActionTitle(for: app.lifecycleStatus)
        )
    }

    private static func normalizedName(for app: WorkspaceApp) -> String {
        let trimmed = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? app.logicalID : trimmed
    }

    private static func normalizedIcon(for app: WorkspaceApp) -> String {
        app.icon.isEmpty ? "square.grid.2x2" : app.icon
    }

    private static func subtitle(for app: WorkspaceApp) -> String {
        let trimmed = app.appDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Workspace app" : trimmed
    }

    private static func statusLabel(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "Draft"
        case .published:
            "Published"
        case .disabled:
            "Disabled"
        case .blocked:
            "Blocked"
        }
    }

    private static func statusSystemImage(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "pencil"
        case .published:
            "checkmark.circle"
        case .disabled:
            "pause.circle"
        case .blocked:
            "exclamationmark.triangle"
        }
    }

    private static func dependencyLabel(for status: WorkspaceAppDependencyStatus) -> String? {
        switch status {
        case .ready:
            nil
        case .unresolved:
            "Needs mapping"
        case .missingRequired:
            "Missing dependency"
        case .blocked:
            "Dependency blocked"
        }
    }

    private static func dependencySystemImage(for status: WorkspaceAppDependencyStatus) -> String? {
        switch status {
        case .ready:
            nil
        case .unresolved:
            "link.badge.plus"
        case .missingRequired:
            "exclamationmark.triangle"
        case .blocked:
            "nosign"
        }
    }

    private static func primaryActionTitle(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "Open draft"
        case .published:
            "Open"
        case .disabled:
            "Disabled"
        case .blocked:
            "Review"
        }
    }

    private static func permissionLabel(for mode: WorkspaceAppPermissionMode) -> String {
        switch mode {
        case .readOnly:
            "Read only"
        case .draftOnly:
            "Draft only"
        case .approvalRequired:
            "Approval required"
        case .preApproved:
            "Pre-approved"
        }
    }

    private static func surfaceTitle(for app: WorkspaceApp) -> String {
        switch app.lifecycleStatus {
        case .draft:
            "Draft app surface"
        case .published:
            "App surface"
        case .disabled:
            "App disabled"
        case .blocked:
            "Review required"
        }
    }

    private static func surfaceSubtitle(for app: WorkspaceApp) -> String {
        if app.dependencyStatus != .ready {
            return "Resolve dependencies before running live actions."
        }
        switch app.permissionMode {
        case .readOnly:
            return "This app can read workspace data and show results."
        case .draftOnly:
            return "This draft is available for design and review."
        case .approvalRequired:
            return "This app asks for approval before running write actions."
        case .preApproved:
            return "This app can run pre-approved actions inside its capability contract."
        }
    }

    private static func lastActivityLabel(for app: WorkspaceApp, now: Date) -> String {
        if let lastRunAt = app.lastRunAt {
            return "Run \(relativeTime(from: lastRunAt, to: now))"
        }
        if let lastRefreshedAt = app.lastRefreshedAt {
            return "Refreshed \(relativeTime(from: lastRefreshedAt, to: now))"
        }
        if let lastOpenedAt = app.lastOpenedAt {
            return "Opened \(relativeTime(from: lastOpenedAt, to: now))"
        }
        return "Created \(relativeTime(from: app.createdAt, to: now))"
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        return "\(days)d ago"
    }
}
