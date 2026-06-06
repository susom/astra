import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Storage")
struct WorkspaceAppStorageTests {
    @Test("storage schema creates app SQLite tables and reads records back")
    func storageSchemaCreatesTablesAndReadsRecordsBack() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        try service.applySchema(Self.grocerySchema(), databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("item-1"),
                "name": .text("Apples"),
                "category": .text("Produce"),
                "quantity": .integer(6),
                "purchased": .bool(false)
            ],
            into: "items",
            databaseURL: databaseURL
        )

        let rows = try service.records(in: "items", databaseURL: databaseURL)

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .text("item-1"))
        #expect(rows[0]["name"] == .text("Apples"))
        #expect(rows[0]["quantity"] == .integer(6))
        #expect(rows[0]["purchased"] == .integer(0))
    }

    @Test("storage rejects unsafe table and column identifiers")
    func storageRejectsUnsafeIdentifiers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items; DROP TABLE items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "text")
            ])
        ])

        #expect(throws: WorkspaceAppStorageError.invalidIdentifier("items; DROP TABLE items")) {
            try service.applySchema(schema, databaseURL: root.appendingPathComponent("app.sqlite"))
        }
    }

    @Test("storage rejects unsupported column types before creating SQL")
    func storageRejectsUnsupportedColumnTypes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "payload", type: "blob")
            ])
        ])

        #expect(throws: WorkspaceAppStorageError.unsupportedColumnType("blob")) {
            try service.applySchema(schema, databaseURL: root.appendingPathComponent("app.sqlite"))
        }
    }

    @Test("storage schema supports App Studio double and date aliases")
    func storageSupportsAppStudioColumnAliases() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "purchases", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "price", type: "double"),
                WorkspaceAppStorageColumn(name: "purchased_at", type: "date")
            ])
        ])

        try service.applySchema(schema, databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("purchase-1"),
                "price": .real(2.49),
                "purchased_at": .text("2026-06-05")
            ],
            into: "purchases",
            databaseURL: databaseURL
        )

        let rows = try service.records(in: "purchases", databaseURL: databaseURL)

        #expect(rows.count == 1)
        #expect(rows[0]["price"] == .real(2.49))
        #expect(rows[0]["purchased_at"] == .text("2026-06-05"))
    }

    static func grocerySchema() -> WorkspaceAppStorageSchema {
        WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                WorkspaceAppStorageColumn(name: "category", type: "text"),
                WorkspaceAppStorageColumn(name: "quantity", type: "integer"),
                WorkspaceAppStorageColumn(name: "purchased", type: "bool")
            ])
        ])
    }
}
