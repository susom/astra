import Foundation

struct WorkspaceAppManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var app: WorkspaceAppManifestMetadata
    var requirements: [WorkspaceAppRequirement]
    var storage: WorkspaceAppStorageSchema?
    var sources: [WorkspaceAppSource]
    var views: [WorkspaceAppViewSpec]
    var actions: [WorkspaceAppActionSpec]
    var automations: [WorkspaceAppAutomationSpec]
    var permissions: WorkspaceAppPermissions

    init(
        schemaVersion: Int = 1,
        app: WorkspaceAppManifestMetadata,
        requirements: [WorkspaceAppRequirement] = [],
        storage: WorkspaceAppStorageSchema? = nil,
        sources: [WorkspaceAppSource] = [],
        views: [WorkspaceAppViewSpec] = [],
        actions: [WorkspaceAppActionSpec] = [],
        automations: [WorkspaceAppAutomationSpec] = [],
        permissions: WorkspaceAppPermissions = WorkspaceAppPermissions()
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.requirements = requirements
        self.storage = storage
        self.sources = sources
        self.views = views
        self.actions = actions
        self.automations = automations
        self.permissions = permissions
    }
}

struct WorkspaceAppManifestMetadata: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var icon: String
    var description: String
    var tags: [String]
    var archetypes: [String]

    init(
        id: String,
        name: String,
        icon: String = "square.grid.2x2",
        description: String = "",
        tags: [String] = [],
        archetypes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.tags = tags
        self.archetypes = archetypes
    }
}

struct WorkspaceAppRequirement: Codable, Sendable, Equatable {
    var id: String
    var contract: String
    var minVersion: String?
    var operations: [String]
    var providerHint: String?
    var providerRequired: String?
    var dataClass: String?
    var optional: Bool
    var reason: String?

    init(
        id: String,
        contract: String,
        minVersion: String? = nil,
        operations: [String],
        providerHint: String? = nil,
        providerRequired: String? = nil,
        dataClass: String? = nil,
        optional: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.contract = contract
        self.minVersion = minVersion
        self.operations = operations
        self.providerHint = providerHint
        self.providerRequired = providerRequired
        self.dataClass = dataClass
        self.optional = optional
        self.reason = reason
    }
}

struct WorkspaceAppStorageSchema: Codable, Sendable, Equatable {
    var tables: [WorkspaceAppStorageTable]

    init(tables: [WorkspaceAppStorageTable] = []) {
        self.tables = tables
    }
}

struct WorkspaceAppStorageTable: Codable, Sendable, Equatable {
    var name: String
    var columns: [WorkspaceAppStorageColumn]

    init(name: String, columns: [WorkspaceAppStorageColumn]) {
        self.name = name
        self.columns = columns
    }
}

struct WorkspaceAppStorageColumn: Codable, Sendable, Equatable {
    var name: String
    var type: String
    var primaryKey: Bool
    var required: Bool

    init(name: String, type: String, primaryKey: Bool = false, required: Bool = false) {
        self.name = name
        self.type = type
        self.primaryKey = primaryKey
        self.required = required
    }
}

struct WorkspaceAppSource: Codable, Sendable, Equatable {
    var id: String
    var requirementRef: String?
    var operation: String?
    var mode: String
    var query: String?
    var projectRef: String?
    var tableRef: String?
    var sourceRef: String?

    init(
        id: String,
        requirementRef: String? = nil,
        operation: String? = nil,
        mode: String = "read",
        query: String? = nil,
        projectRef: String? = nil,
        tableRef: String? = nil,
        sourceRef: String? = nil
    ) {
        self.id = id
        self.requirementRef = requirementRef
        self.operation = operation
        self.mode = mode
        self.query = query
        self.projectRef = projectRef
        self.tableRef = tableRef
        self.sourceRef = sourceRef
    }
}

struct WorkspaceAppViewSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var title: String?
    var table: String?
    var widgets: [WorkspaceAppWidgetSpec]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case table
        case widgets
    }

    init(
        id: String,
        type: String,
        title: String? = nil,
        table: String? = nil,
        widgets: [WorkspaceAppWidgetSpec] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.table = table
        self.widgets = widgets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        widgets = try container.decodeIfPresent([WorkspaceAppWidgetSpec].self, forKey: .widgets) ?? []
    }
}

struct WorkspaceAppWidgetSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var label: String
    var table: String?
    var field: String?
    var groupBy: String?
    var aggregation: String?

    init(
        id: String,
        type: String,
        label: String,
        table: String? = nil,
        field: String? = nil,
        groupBy: String? = nil,
        aggregation: String? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.table = table
        self.field = field
        self.groupBy = groupBy
        self.aggregation = aggregation
    }
}

struct WorkspaceAppActionSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var label: String?
    var requirementRef: String?
    var operation: String?
    var taskTitle: String?
    var taskGoal: String?

    init(
        id: String,
        type: String,
        label: String? = nil,
        requirementRef: String? = nil,
        operation: String? = nil,
        taskTitle: String? = nil,
        taskGoal: String? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.requirementRef = requirementRef
        self.operation = operation
        self.taskTitle = taskTitle
        self.taskGoal = taskGoal
    }
}

struct WorkspaceAppAutomationSpec: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var enabledByDefault: Bool
    var action: String?

    init(id: String, type: String, enabledByDefault: Bool = false, action: String? = nil) {
        self.id = id
        self.type = type
        self.enabledByDefault = enabledByDefault
        self.action = action
    }
}

struct WorkspaceAppPermissions: Codable, Sendable, Equatable {
    var reads: [String]
    var writes: [String]
    var externalWrites: [String]
    var defaultMode: WorkspaceAppPermissionMode

    init(
        reads: [String] = [],
        writes: [String] = [],
        externalWrites: [String] = [],
        defaultMode: WorkspaceAppPermissionMode = .readOnly
    ) {
        self.reads = reads
        self.writes = writes
        self.externalWrites = externalWrites
        self.defaultMode = defaultMode
    }
}
