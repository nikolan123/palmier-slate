import CryptoKit
import Foundation

enum ConsolidationScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case used

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All media"
        case .used: "Timeline-used media"
        }
    }
}

enum ConsolidationOperation: String, CaseIterable, Identifiable, Sendable {
    case copy
    case move

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ProjectMediaConsolidationPlan: Sendable {
    struct File: Sendable, Identifiable {
        let id: String
        let sourceURL: URL
        let sourceURLs: [URL]
        let entryIDs: [String]
        let byteCount: Int64
        let preferredFilename: String
    }

    struct Missing: Sendable, Identifiable {
        let id: String
        let name: String
        let path: String
    }

    let files: [File]
    let missing: [Missing]
    let skippedInternalCount: Int
    let cleanupEntryIDs: Set<String>
    let cleanupURLs: [URL]
    let totalBytes: Int64
    let availableBytes: Int64?
    let destinationURL: URL
    let renamedForConflictCount: Int
}

enum ProjectMediaConsolidator {
    struct AppliedChange: Sendable {
        let manifest: MediaManifest
        let assetURLs: [String: URL]
        let installedURLs: [URL]
        let sourceURLsToRemove: [URL]
        let cleanupURLs: [URL]
    }

    enum Error: LocalizedError {
        case projectNotSaved
        case insufficientSpace(required: Int64, available: Int64)
        case sourceChanged(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .projectNotSaved:
                "Save the project before consolidating media."
            case .insufficientSpace(let required, let available):
                "Not enough free space. \(format(required)) required, \(format(available)) available."
            case .sourceChanged(let name):
                "\"\(name)\" changed or became unavailable."
            case .verificationFailed(let name):
                "Could not verify \"\(name)\" after copying."
            }
        }

        private func format(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    static func makePlan(
        manifest: MediaManifest,
        timeline: Timeline,
        projectURL: URL?,
        scope: ConsolidationScope,
        cleanUnusedManagedMedia: Bool
    ) throws -> ProjectMediaConsolidationPlan {
        guard let projectURL else { throw Error.projectNotSaved }
        let fm = FileManager.default
        let usedIDs = Set(timeline.tracks.flatMap(\.clips).map(\.mediaRef))
        let selectedEntries = manifest.entries.filter { entry in
            scope == .all || usedIDs.contains(entry.id)
        }

        var externalByPath: [String: [MediaManifestEntry]] = [:]
        var missing: [ProjectMediaConsolidationPlan.Missing] = []
        var skippedInternalCount = 0

        for entry in selectedEntries {
            try Task.checkCancellation()
            let sourceURL: URL
            switch entry.source {
            case .external(let path):
                sourceURL = URL(fileURLWithPath: path)
            case .project:
                skippedInternalCount += 1
                continue
            }
            guard fm.fileExists(atPath: sourceURL.path) else {
                missing.append(.init(id: entry.id, name: entry.name, path: sourceURL.path))
                continue
            }
            externalByPath[sourceURL.standardizedFileURL.path, default: []].append(entry)
        }

        var fileByDigest: [String: ProjectMediaConsolidationPlan.File] = [:]
        for path in externalByPath.keys.sorted() {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path)
            let entries = externalByPath[path] ?? []
            let size = fileSize(url)
            let digest = try fileDigest(url)
            if let existing = fileByDigest[digest] {
                fileByDigest[digest] = .init(
                    id: existing.id,
                    sourceURL: existing.sourceURL,
                    sourceURLs: existing.sourceURLs + [url],
                    entryIDs: existing.entryIDs + entries.map(\.id),
                    byteCount: existing.byteCount,
                    preferredFilename: existing.preferredFilename
                )
            } else if let first = entries.first {
                fileByDigest[digest] = .init(
                    id: digest,
                    sourceURL: url,
                    sourceURLs: [url],
                    entryIDs: entries.map(\.id),
                    byteCount: size,
                    preferredFilename: filename(for: first, sourceURL: url)
                )
            }
        }

        let cleanupEntries = manifest.entries.filter { entry in
            guard cleanUnusedManagedMedia, scope == .used, !usedIDs.contains(entry.id) else { return false }
            if case .project = entry.source { return true }
            return false
        }
        let cleanupEntryIDs = Set(cleanupEntries.map(\.id))
        let retainedManagedPaths = Set(manifest.entries.compactMap { entry -> String? in
            guard !cleanupEntryIDs.contains(entry.id),
                  case .project(let relativePath) = entry.source else { return nil }
            return relativePath
        })
        let cleanupURLs = cleanupEntries.compactMap { entry -> URL? in
            guard case .project(let relativePath) = entry.source else { return nil }
            guard !retainedManagedPaths.contains(relativePath) else { return nil }
            return projectURL.appendingPathComponent(relativePath)
        }
        let mediaDirectory = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let existingNames = Set(
            (try? fm.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []
        )
        var reservedNames = existingNames
        var renamedForConflictCount = 0
        let files = fileByDigest.values
            .sorted { $0.preferredFilename < $1.preferredFilename }
            .map { file in
                let filename = uniqueFilename(file.preferredFilename, reserved: &reservedNames)
                if filename != file.preferredFilename {
                    renamedForConflictCount += 1
                }
                return ProjectMediaConsolidationPlan.File(
                    id: file.id,
                    sourceURL: file.sourceURL,
                    sourceURLs: file.sourceURLs,
                    entryIDs: file.entryIDs,
                    byteCount: file.byteCount,
                    preferredFilename: filename
                )
            }
        let totalBytes = files.reduce(0) { $0 + $1.byteCount }
        let availableBytes = try? projectURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage

        return .init(
            files: files,
            missing: missing,
            skippedInternalCount: skippedInternalCount,
            cleanupEntryIDs: cleanupEntryIDs,
            cleanupURLs: cleanupURLs,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            destinationURL: mediaDirectory,
            renamedForConflictCount: renamedForConflictCount
        )
    }

    static func apply(
        plan: ProjectMediaConsolidationPlan,
        manifest: MediaManifest,
        projectURL: URL,
        operation: ConsolidationOperation,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> AppliedChange {
        if let available = plan.availableBytes, available < plan.totalBytes {
            throw Error.insufficientSpace(required: plan.totalBytes, available: available)
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(
            "palmier-consolidation-\(UUID().uuidString)",
            isDirectory: true
        )
        let mediaDirectory = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var installedURLs: [URL] = []
        do {
            var stagedByID: [String: URL] = [:]
            for (index, file) in plan.files.enumerated() {
                try Task.checkCancellation()
                for sourceURL in file.sourceURLs {
                    guard fm.fileExists(atPath: sourceURL.path),
                          fileSize(sourceURL) == file.byteCount,
                          try fileDigest(sourceURL) == file.id else {
                        throw Error.sourceChanged(sourceURL.lastPathComponent)
                    }
                }
                let stagedURL = staging.appendingPathComponent(file.preferredFilename)
                try fm.copyItem(at: file.sourceURL, to: stagedURL)
                guard fileSize(stagedURL) == file.byteCount,
                      try fileDigest(stagedURL) == file.id else {
                    throw Error.verificationFailed(file.sourceURL.lastPathComponent)
                }
                stagedByID[file.id] = stagedURL
                progress(Double(index + 1) / Double(max(1, plan.files.count + 1)))
            }

            var relativePathByEntryID: [String: String] = [:]
            for file in plan.files {
                try Task.checkCancellation()
                guard let stagedURL = stagedByID[file.id] else { continue }
                let destination = uniqueURL(in: mediaDirectory, preferredName: file.preferredFilename)
                try fm.moveItem(at: stagedURL, to: destination)
                installedURLs.append(destination)
                let relativePath = "\(Project.mediaDirectoryName)/\(destination.lastPathComponent)"
                for entryID in file.entryIDs {
                    relativePathByEntryID[entryID] = relativePath
                }
            }

            var rewrittenManifest = manifest
            rewrittenManifest.entries.removeAll { plan.cleanupEntryIDs.contains($0.id) }
            for index in rewrittenManifest.entries.indices {
                let id = rewrittenManifest.entries[index].id
                if let relativePath = relativePathByEntryID[id] {
                    rewrittenManifest.entries[index].source = .project(relativePath: relativePath)
                }
            }

            let assetURLs = Dictionary(uniqueKeysWithValues: relativePathByEntryID.map {
                ($0.key, projectURL.appendingPathComponent($0.value))
            })
            progress(1)
            return AppliedChange(
                manifest: rewrittenManifest,
                assetURLs: assetURLs,
                installedURLs: installedURLs,
                sourceURLsToRemove: operation == .move ? plan.files.flatMap(\.sourceURLs) : [],
                cleanupURLs: plan.cleanupURLs
            )
        } catch {
            removeFiles(installedURLs)
            throw error
        }
    }

    @discardableResult
    static func removeFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var failures: [URL] = []
        for url in Set(urls.map(\.standardizedFileURL)) where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                failures.append(url)
            }
        }
        return failures
    }

    private static func filename(for entry: MediaManifestEntry, sourceURL: URL) -> String {
        let originalName = sourceURL.lastPathComponent
        if !originalName.isEmpty {
            return originalName
        }
        let ext = sourceURL.pathExtension
        let base = "import-\(entry.id.prefix(8))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var suffix = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }

    private static func uniqueFilename(_ preferredName: String, reserved: inout Set<String>) -> String {
        guard reserved.contains(preferredName) else {
            reserved.insert(preferredName)
            return preferredName
        }
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var suffix = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            if reserved.insert(name).inserted {
                return name
            }
            suffix += 1
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
