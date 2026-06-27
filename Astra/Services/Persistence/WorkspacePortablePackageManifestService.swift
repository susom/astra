import Foundation

enum WorkspacePortablePackageManifestService {
    static let schemaVersion = 1
    static let workspaceManifestFileName = "workspace_manifest.json"
    static let taskManifestFileName = "task_manifest.json"

    struct WorkspaceManifest: Codable, Sendable {
        var schemaVersion: Int
        var workspaceID: String?
        var name: String
        var workspaceConfigFile: String
        var supportDirectory: String
        var taskCount: Int
        var tasks: [TaskIndex]
        var portableIncludes: [String]
        var localOnlyExcludes: [String]
        var exportedAt: Date
    }

    struct TaskIndex: Codable, Sendable {
        var id: String
        var title: String
        var status: String
        var taskFolder: String
        var manifestFile: String
    }

    struct TaskManifest: Codable, Sendable {
        var schemaVersion: Int
        var taskID: String
        var title: String
        var status: String
        var taskFolder: String
        var stateFiles: [String]
        var outputDirectory: String
        var task: WorkspaceConfigManager.TaskConfig
        var portableIncludes: [String]
        var localOnlyExcludes: [String]
        var exportedAt: Date
    }

    static func workspaceManifestURL(workspaceURL: URL) -> URL {
        workspaceURL
            .appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(workspaceManifestFileName)
    }

    static func taskManifestURL(workspaceURL: URL, taskID: String) -> URL? {
        guard let prefix = taskFolderPrefix(taskID) else { return nil }
        return workspaceURL
            .appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(taskManifestFileName)
    }

    static func writePackageManifests(
        for config: WorkspaceConfigManager.WorkspaceConfig,
        workspaceURL: URL,
        exportedAt: Date = Date()
    ) throws {
        let supportURL = workspaceURL.appendingPathComponent(WorkspaceFileLayout.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let taskIndexes = try writeTaskManifests(
            for: config.tasks ?? [],
            workspaceURL: workspaceURL,
            exportedAt: exportedAt
        )
        let manifest = WorkspaceManifest(
            schemaVersion: schemaVersion,
            workspaceID: config.id,
            name: config.name,
            workspaceConfigFile: WorkspaceFileLayout.workspaceConfigFileName,
            supportDirectory: WorkspaceFileLayout.supportDirectoryName,
            taskCount: taskIndexes.count,
            tasks: taskIndexes,
            portableIncludes: [
                "workspace identity and instructions",
                "redacted tasks, runs, events, artifact metadata, and skill snapshots",
                "task-local current_state, session_history, outputs, diagnostics, and generated artifacts"
            ],
            localOnlyExcludes: [
                "Keychain secrets and credential values",
                "provider session identifiers",
                "draft composer state",
                "unread/sidebar presentation state",
                "runtime caches and helper binaries",
                "absolute artifact paths outside the workspace"
            ],
            exportedAt: exportedAt
        )
        try write(manifest, to: workspaceManifestURL(workspaceURL: workspaceURL))
    }

    private static func writeTaskManifests(
        for tasks: [WorkspaceConfigManager.TaskConfig],
        workspaceURL: URL,
        exportedAt: Date
    ) throws -> [TaskIndex] {
        var indexes: [TaskIndex] = []
        for task in tasks {
            guard let taskID = task.id,
                  let prefix = taskFolderPrefix(taskID),
                  let manifestURL = taskManifestURL(workspaceURL: workspaceURL, taskID: taskID) else {
                continue
            }
            let relativeTaskFolder = [
                WorkspaceFileLayout.supportDirectoryName,
                "tasks",
                prefix
            ].joined(separator: "/")
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let manifest = TaskManifest(
                schemaVersion: schemaVersion,
                taskID: taskID,
                title: task.title,
                status: task.status,
                taskFolder: relativeTaskFolder,
                stateFiles: [
                    "\(relativeTaskFolder)/\(TaskContextStateManager.jsonFileName)",
                    "\(relativeTaskFolder)/\(TaskContextStateManager.markdownFileName)",
                    "\(relativeTaskFolder)/\(SessionHistoryManager.historyFileName)"
                ],
                outputDirectory: "\(relativeTaskFolder)/outputs",
                task: task,
                portableIncludes: [
                    "task identity, goal, status, timing, constraints, and acceptance criteria",
                    "redacted run summaries, events, file changes, artifact metadata, and skill snapshots",
                    "task-local state and output files referenced by relative path"
                ],
                localOnlyExcludes: [
                    "provider session identifiers",
                    "draft composer state",
                    "unread/sidebar presentation state",
                    "runtime caches and helper binaries",
                    "artifact references outside the workspace"
                ],
                exportedAt: exportedAt
            )
            try write(manifest, to: manifestURL)
            indexes.append(TaskIndex(
                id: taskID,
                title: task.title,
                status: task.status,
                taskFolder: relativeTaskFolder,
                manifestFile: "\(relativeTaskFolder)/\(taskManifestFileName)"
            ))
        }
        return indexes
    }

    private static func taskFolderPrefix(_ taskID: String) -> String? {
        guard UUID(uuidString: taskID) != nil else { return nil }
        return String(taskID.prefix(8))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
