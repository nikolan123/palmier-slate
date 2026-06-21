import Foundation
import Testing
@testable import PalmierPro

@Suite("Project media consolidation")
struct ProjectMediaConsolidatorTests {
    private let fm = FileManager.default

    @Test func usedScopeCollectsOnlyTimelineReferences() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        var manifest = MediaManifest()
        manifest.entries = [
            entry(id: "used", path: fixture.externalA.path),
            entry(id: "unused", path: fixture.externalB.path),
        ]
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "used", start: 0, duration: 30)]),
        ])

        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: timeline,
            projectURL: fixture.project,
            scope: .used,
            cleanUnusedManagedMedia: false
        )

        #expect(plan.files.count == 1)
        #expect(plan.files[0].entryIDs == ["used"])
    }

    @Test func identicalFilesAtDifferentPathsAreDeduplicated() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        try Data("A".utf8).write(to: fixture.externalB)
        var manifest = MediaManifest()
        manifest.entries = [
            entry(id: "a", path: fixture.externalA.path),
            entry(id: "b", path: fixture.externalB.path),
        ]

        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: Fixtures.timeline(),
            projectURL: fixture.project,
            scope: .all,
            cleanUnusedManagedMedia: false
        )

        #expect(plan.files.count == 1)
        #expect(Set(plan.files[0].entryIDs) == ["a", "b"])
        #expect(plan.files[0].sourceURLs.count == 2)
    }

    @Test func applyCopiesAndRewritesManifest() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        var manifest = MediaManifest()
        manifest.entries = [entry(id: "a", path: fixture.externalA.path)]
        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: Fixtures.timeline(),
            projectURL: fixture.project,
            scope: .all,
            cleanUnusedManagedMedia: false
        )

        let change = try ProjectMediaConsolidator.apply(
            plan: plan,
            manifest: manifest,
            projectURL: fixture.project,
            operation: .copy,
            progress: { _ in }
        )

        #expect(change.installedURLs.count == 1)
        #expect(change.sourceURLsToRemove.isEmpty)
        #expect(fm.fileExists(atPath: fixture.externalA.path))
        #expect(try Data(contentsOf: change.installedURLs[0]) == Data("A".utf8))
        if case .project(let relativePath) = change.manifest.entries[0].source {
            #expect(change.installedURLs[0] == fixture.project.appendingPathComponent(relativePath))
        } else {
            Issue.record("Expected a project-relative media source")
        }
    }

    @Test func moveDefersDeletingEveryDeduplicatedOriginal() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        try Data("A".utf8).write(to: fixture.externalB)
        var manifest = MediaManifest()
        manifest.entries = [
            entry(id: "a", path: fixture.externalA.path),
            entry(id: "b", path: fixture.externalB.path),
        ]
        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: Fixtures.timeline(),
            projectURL: fixture.project,
            scope: .all,
            cleanUnusedManagedMedia: false
        )

        let change = try ProjectMediaConsolidator.apply(
            plan: plan,
            manifest: manifest,
            projectURL: fixture.project,
            operation: .move,
            progress: { _ in }
        )

        #expect(Set(change.sourceURLsToRemove) == [fixture.externalA, fixture.externalB])
        #expect(fm.fileExists(atPath: fixture.externalA.path))
        #expect(fm.fileExists(atPath: fixture.externalB.path))
    }

    @Test func filenameConflictsArePlannedWithoutClobbering() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let mediaDirectory = fixture.project.appendingPathComponent(Project.mediaDirectoryName)
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: mediaDirectory.appendingPathComponent("a.mov"))
        var manifest = MediaManifest()
        manifest.entries = [entry(id: "a", path: fixture.externalA.path)]

        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: Fixtures.timeline(),
            projectURL: fixture.project,
            scope: .all,
            cleanUnusedManagedMedia: false
        )

        #expect(plan.renamedForConflictCount == 1)
        #expect(plan.files[0].preferredFilename == "a-1.mov")
    }

    @Test func cleanupDoesNotDeleteFileRetainedByAnotherEntry() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let managed = fixture.project.appendingPathComponent("media/shared.mov")
        try fm.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: managed)
        var manifest = MediaManifest()
        manifest.entries = [
            projectEntry(id: "used", relativePath: "media/shared.mov"),
            projectEntry(id: "unused", relativePath: "media/shared.mov"),
        ]
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "used", start: 0, duration: 30)]),
        ])

        let plan = try ProjectMediaConsolidator.makePlan(
            manifest: manifest,
            timeline: timeline,
            projectURL: fixture.project,
            scope: .used,
            cleanUnusedManagedMedia: true
        )

        #expect(plan.cleanupEntryIDs == ["unused"])
        #expect(plan.cleanupURLs.isEmpty)
    }

    private func makeFixture() throws -> (root: URL, project: URL, externalA: URL, externalB: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("pp-consolidate-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Project.palmier", isDirectory: true)
        let externalA = root.appendingPathComponent("a.mov")
        let externalB = root.appendingPathComponent("b.mov")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: externalA)
        try Data("B".utf8).write(to: externalB)
        return (root, project, externalA, externalB)
    }

    private func entry(id: String, path: String) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id,
            name: id,
            type: .video,
            source: .external(absolutePath: path),
            duration: 1
        )
    }

    private func projectEntry(id: String, relativePath: String) -> MediaManifestEntry {
        MediaManifestEntry(
            id: id,
            name: id,
            type: .video,
            source: .project(relativePath: relativePath),
            duration: 1
        )
    }
}
