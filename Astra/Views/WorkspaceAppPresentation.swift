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

    private static func card(for app: WorkspaceApp, now: Date) -> WorkspaceAppCardPresentation {
        WorkspaceAppCardPresentation(
            id: app.id,
            logicalID: app.logicalID,
            name: app.name,
            icon: app.icon.isEmpty ? "square.grid.2x2" : app.icon,
            subtitle: subtitle(for: app),
            statusLabel: statusLabel(for: app.lifecycleStatus),
            statusSystemImage: statusSystemImage(for: app.lifecycleStatus),
            dependencyLabel: dependencyLabel(for: app.dependencyStatus),
            dependencySystemImage: dependencySystemImage(for: app.dependencyStatus),
            lastActivityLabel: lastActivityLabel(for: app, now: now),
            primaryActionTitle: primaryActionTitle(for: app.lifecycleStatus)
        )
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
