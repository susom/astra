import CryptoKit
import Foundation
import SwiftData

enum WorkspaceAppPackageExportMode: String, Codable, Sendable, Equatable, CaseIterable {
    case templateOnly
    case templatePlusSampleData
    case templatePlusSeedData
    case fullAppExport
}

enum WorkspaceAppPackageInstallState: String, Codable, Sendable, Equatable, CaseIterable {
    case decoded
    case validated
    case needsDependencyMapping
    case needsPermissionReview
    case readyToInstall
    case installedDisabled
    case installedReady
    case blocked
}

struct WorkspaceAppPackageManifest: Codable, Sendable, Equatable {
    var packageID: String
    var appID: String
    var appName: String
    var version: String
    var minimumASTRAVersion: String
    var sourceManifestDigest: String
    var exportMode: WorkspaceAppPackageExportMode
    var createdAt: Date
    var author: String?
    var requiredContracts: [WorkspaceAppPackageContractRequirement]
}

struct WorkspaceAppPackageContractRequirement: Codable, Sendable, Equatable {
    var id: String
    var contract: String
    var minVersion: String?
    var operations: [String]
    var providerHint: String?
    var providerRequired: String?
    var optional: Bool
}

struct WorkspaceAppPackageChecksum: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
}

struct WorkspaceAppPackageValidationReport: Equatable {
    struct Issue: Equatable {
        enum Severity: String, Equatable {
            case blocker
            case warning
        }

        var severity: Severity
        var path: String
        var message: String
    }

    var package: WorkspaceAppPackageManifest?
    var manifest: WorkspaceAppManifest?
    var issues: [Issue]
    var installState: WorkspaceAppPackageInstallState

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var canInstall: Bool {
        blockers.isEmpty && package != nil && manifest != nil
    }
}

enum WorkspaceAppPackageError: LocalizedError, Equatable {
    case invalidPackage(WorkspaceAppPackageValidationReport)
    case invalidManifest([WorkspaceAppManifestValidationReport.Issue])
    case packageAlreadyExists(String)
    case unsupportedExportMode(WorkspaceAppPackageExportMode)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let report):
            let messages = report.blockers.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app package is invalid.\n\(messages)"
        case .invalidManifest(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app manifest is invalid.\n\(messages)"
        case .packageAlreadyExists(let path):
            return "Workspace app package already exists at \(path)."
        case .unsupportedExportMode(let mode):
            return "Workspace app package export mode \(mode.rawValue) is not implemented yet."
        }
    }
}

struct WorkspaceAppPackageImportResult {
    var app: WorkspaceApp
    var report: WorkspaceAppPackageValidationReport
    var manifestURL: URL
}

struct WorkspaceAppPackageService {
    var fileManager: FileManager = .default
    var appService = WorkspaceAppService()

    func exportPackage(
        manifest: WorkspaceAppManifest,
        to packageURL: URL,
        packageID: String? = nil,
        version: String = "1.0.0",
        minimumASTRAVersion: String = "0.1.0",
        mode: WorkspaceAppPackageExportMode = .templateOnly,
        author: String? = nil,
        createdAt: Date = Date()
    ) throws -> URL {
        guard mode == .templateOnly else {
            throw WorkspaceAppPackageError.unsupportedExportMode(mode)
        }
        let report = WorkspaceAppManifestValidator.validate(manifest)
        guard report.isValid else {
            throw WorkspaceAppPackageError.invalidManifest(report.blockers)
        }
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw WorkspaceAppPackageError.packageAlreadyExists(packageURL.path)
        }

        let manifestData = try WorkspaceAppService.encodeManifest(manifest)
        let package = WorkspaceAppPackageManifest(
            packageID: packageID ?? "\(manifest.app.id).astra-app",
            appID: manifest.app.id,
            appName: manifest.app.name,
            version: version,
            minimumASTRAVersion: minimumASTRAVersion,
            sourceManifestDigest: WorkspaceAppService.digest(for: manifestData),
            exportMode: mode,
            createdAt: createdAt,
            author: author,
            requiredContracts: manifest.requirements.map(Self.packageRequirement)
        )

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try writeJSON(package, to: packageURL.appendingPathComponent("package.json"))
        try manifestData.write(to: packageURL.appendingPathComponent("manifest.json"), options: [.atomic])
        if let storage = manifest.storage {
            let storageURL = packageURL
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent("schema.json")
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJSON(storage, to: storageURL)
        }
        let readmeURL = packageURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("README.md")
        try fileManager.createDirectory(at: readmeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(manifest.app.name)\n\nExported ASTRA Workspace App package.\n".utf8)
            .write(to: readmeURL, options: [.atomic])
        try writeJSON(checksums(in: packageURL), to: packageURL.appendingPathComponent("checksums.json"))
        return packageURL
    }

    func validatePackage(at packageURL: URL) -> WorkspaceAppPackageValidationReport {
        var issues: [WorkspaceAppPackageValidationReport.Issue] = []
        let package: WorkspaceAppPackageManifest? = decode(
            WorkspaceAppPackageManifest.self,
            at: packageURL.appendingPathComponent("package.json"),
            path: "/package.json",
            issues: &issues
        )
        let manifest: WorkspaceAppManifest? = decode(
            WorkspaceAppManifest.self,
            at: packageURL.appendingPathComponent("manifest.json"),
            path: "/manifest.json",
            issues: &issues
        )
        let declaredChecksums: [WorkspaceAppPackageChecksum]? = decode(
            [WorkspaceAppPackageChecksum].self,
            at: packageURL.appendingPathComponent("checksums.json"),
            path: "/checksums.json",
            issues: &issues
        )

        if let manifest {
            let manifestReport = WorkspaceAppManifestValidator.validate(manifest)
            for issue in manifestReport.issues {
                issues.append(WorkspaceAppPackageValidationReport.Issue(
                    severity: issue.severity == .blocker ? .blocker : .warning,
                    path: "/manifest.json\(issue.path)",
                    message: issue.message
                ))
            }
        }
        if let package, let manifest {
            if package.appID != manifest.app.id {
                issues.append(blocker("/package.json/appID", "Package app ID does not match manifest app ID."))
            }
            if package.sourceManifestDigest != digest(for: packageURL.appendingPathComponent("manifest.json")) {
                issues.append(blocker("/package.json/sourceManifestDigest", "Package manifest digest does not match manifest.json."))
            }
        }
        if let declaredChecksums {
            validateChecksums(declaredChecksums, packageURL: packageURL, issues: &issues)
            validateAllFilesAreChecksummed(declaredChecksums, packageURL: packageURL, issues: &issues)
        }
        validateNoForbiddenPortableContent(packageURL: packageURL, issues: &issues)

        return WorkspaceAppPackageValidationReport(
            package: package,
            manifest: manifest,
            issues: issues,
            installState: installState(package: package, manifest: manifest, issues: issues)
        )
    }

    @MainActor
    func importPackage(
        at packageURL: URL,
        into workspace: Workspace,
        modelContext: ModelContext
    ) throws -> WorkspaceAppPackageImportResult {
        let report = validatePackage(at: packageURL)
        guard report.canInstall,
              let package = report.package,
              let manifest = report.manifest else {
            throw WorkspaceAppPackageError.invalidPackage(report)
        }
        let checksumsURL = packageURL.appendingPathComponent("checksums.json")
        let packageDigest = digest(for: checksumsURL)
        let result = try appService.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: modelContext,
            status: .draft,
            sourcePackageID: package.packageID,
            sourcePackageVersion: package.version,
            sourcePackageDigest: packageDigest
        )
        return WorkspaceAppPackageImportResult(
            app: result.app,
            report: report,
            manifestURL: result.manifestURL
        )
    }

    private static func packageRequirement(
        _ requirement: WorkspaceAppRequirement
    ) -> WorkspaceAppPackageContractRequirement {
        WorkspaceAppPackageContractRequirement(
            id: requirement.id,
            contract: requirement.contract,
            minVersion: requirement.minVersion,
            operations: requirement.operations,
            providerHint: requirement.providerHint,
            providerRequired: requirement.providerRequired,
            optional: requirement.optional
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        path: String,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) -> T? {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            issues.append(blocker(path, "Could not decode required package file: \(error.localizedDescription)"))
            return nil
        }
    }

    private func checksums(in packageURL: URL) throws -> [WorkspaceAppPackageChecksum] {
        let paths = portableFilePaths(in: packageURL)
            .filter { $0 != "checksums.json" }
        return try paths.map { path in
            let data = try Data(contentsOf: packageURL.appendingPathComponent(path))
            return WorkspaceAppPackageChecksum(path: path, sha256: WorkspaceAppService.digest(for: data))
        }
    }

    private func validateChecksums(
        _ checksums: [WorkspaceAppPackageChecksum],
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        for checksum in checksums {
            guard isPortableRelativePath(checksum.path) else {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum path must be relative and portable."))
                continue
            }
            let url = packageURL.appendingPathComponent(checksum.path)
            guard let data = try? Data(contentsOf: url) else {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum references a missing file."))
                continue
            }
            let actual = WorkspaceAppService.digest(for: data)
            if actual != checksum.sha256 {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum does not match package file."))
            }
        }
    }

    private func validateAllFilesAreChecksummed(
        _ checksums: [WorkspaceAppPackageChecksum],
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        let declared = Set(checksums.map(\.path) + ["checksums.json"])
        for path in portableFilePaths(in: packageURL) where !declared.contains(path) {
            issues.append(blocker("/\(path)", "Package file is not listed in checksums.json."))
        }
    }

    private func validateNoForbiddenPortableContent(
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        for path in portableFilePaths(in: packageURL) where path.hasSuffix(".json") || path.hasSuffix(".md") {
            guard let data = try? Data(contentsOf: packageURL.appendingPathComponent(path)),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let lowercased = text.lowercased()
            let forbiddenKeys = ["api_key", "apikey", "oauth", "password", "secret", "token"]
            if forbiddenKeys.contains(where: { lowercased.contains($0) }) {
                issues.append(blocker("/\(path)", "Package content appears to include credential material."))
            }
            if text.contains(NSHomeDirectory()) || lowercased.contains("/users/") {
                issues.append(blocker("/\(path)", "Package content appears to include an absolute local path."))
            }
        }
    }

    private func portableFilePaths(in packageURL: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let basePath = packageURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let filePath = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard filePath.hasPrefix("\(basePath)/") else { return nil }
            return String(filePath.dropFirst(basePath.count + 1))
        }
        .sorted()
    }

    private func isPortableRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("..")
            && !path.contains("\\")
    }

    private func installState(
        package: WorkspaceAppPackageManifest?,
        manifest: WorkspaceAppManifest?,
        issues: [WorkspaceAppPackageValidationReport.Issue]
    ) -> WorkspaceAppPackageInstallState {
        guard issues.allSatisfy({ $0.severity != .blocker }),
              let manifest else {
            return .blocked
        }
        let registry = WorkspaceAppContractRegistry()
        let unresolvedRequired = registry.resolveAll(manifest.requirements).contains { !$0.isSatisfied }
        if unresolvedRequired {
            return .needsDependencyMapping
        }
        if manifest.permissions.defaultMode != .readOnly {
            return .needsPermissionReview
        }
        return package == nil ? .decoded : .readyToInstall
    }

    private func digest(for url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func blocker(_ path: String, _ message: String) -> WorkspaceAppPackageValidationReport.Issue {
        WorkspaceAppPackageValidationReport.Issue(severity: .blocker, path: path, message: message)
    }
}
