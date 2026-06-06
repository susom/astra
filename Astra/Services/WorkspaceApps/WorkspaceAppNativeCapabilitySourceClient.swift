import Foundation

protocol WorkspaceAppDatabaseQueryRunning {
    func run(_ request: QueryRequest) async throws -> QueryExecutionResult
}

extension DatabaseQueryService: WorkspaceAppDatabaseQueryRunning {}

struct WorkspaceAppNativeAsyncCapabilitySourceClient: WorkspaceAppAsyncCapabilitySourceClient {
    var queryRunner: any WorkspaceAppDatabaseQueryRunning = DatabaseQueryService()

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        if requirement.contract == "tabularQuery.read",
           (binding.provider == "bigQuery" || requirement.providerHint == "bigQuery") {
            return try await WorkspaceAppBigQueryReadClient(queryRunner: queryRunner)
                .read(source: source, requirement: requirement, binding: binding, input: input)
        }
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
    }
}

struct WorkspaceAppBigQueryReadClient: WorkspaceAppAsyncCapabilitySourceClient {
    var queryRunner: any WorkspaceAppDatabaseQueryRunning = DatabaseQueryService()

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        guard requirement.contract == "tabularQuery.read" else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
        }
        let operation = source.operation ?? requirement.operations.first ?? ""
        guard operation == "runReadOnlyQuery" || operation == "previewRows" else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        let sql = try sql(for: source, operation: operation, limit: input.limit)
        guard SQLClassifier.classify(sql) == .read else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        let result = try await queryRunner.run(QueryRequest(
            sql: sql,
            connection: connection(for: source, binding: binding),
            rowLimit: max(1, input.limit)
        ))
        return rows(from: result)
    }

    private func sql(
        for source: WorkspaceAppSource,
        operation: String,
        limit: Int
    ) throws -> String {
        if operation == "runReadOnlyQuery",
           let query = source.query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            return query
        }
        guard let table = source.tableRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !table.isEmpty,
              let quotedTable = quotedTableIdentifier(table, projectRef: source.projectRef) else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return "SELECT * FROM \(quotedTable) LIMIT \(max(1, limit))"
    }

    private func connection(
        for source: WorkspaceAppSource,
        binding: WorkspaceAppDependencyBinding
    ) -> DatabaseConnection {
        DatabaseConnection(
            id: binding.implementationID ?? "bigquery-cli",
            displayName: binding.provider ?? "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: datasetID(from: source.tableRef),
            projectID: source.projectRef
        )
    }

    private func quotedTableIdentifier(_ tableRef: String, projectRef: String?) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.:")
        guard tableRef.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let table = tableRef.replacingOccurrences(of: ":", with: ".")
        if table.split(separator: ".").count == 2,
           let projectRef,
           !projectRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let projectAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            guard projectRef.unicodeScalars.allSatisfy({ projectAllowed.contains($0) }) else { return nil }
            return "`\(projectRef).\(table)`"
        }
        return "`\(table)`"
    }

    private func datasetID(from tableRef: String?) -> String? {
        guard let tableRef else { return nil }
        let parts = tableRef.replacingOccurrences(of: ":", with: ".").split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    private func rows(from result: QueryExecutionResult) -> [[String: WorkspaceAppStorageValue]] {
        result.rows.map { row in
            var values: [String: WorkspaceAppStorageValue] = [:]
            for (index, column) in result.columns.enumerated() where index < row.count {
                values[column.name] = .text(row[index])
            }
            return values
        }
    }
}
