import AppKit
import SwiftUI

@Observable
@MainActor
final class ProjectMediaConsolidationService {
    private(set) var plan: ProjectMediaConsolidationPlan?
    private(set) var isPlanning = false
    private(set) var isConsolidating = false
    private(set) var progress = 0.0
    private(set) var error: String?
    private(set) var result: String?

    private var planningTask: Task<Void, Never>?
    private var consolidationTask: Task<Void, Never>?

    func refresh(
        manifest: MediaManifest,
        timeline: Timeline,
        projectURL: URL?,
        scope: ConsolidationScope,
        cleanUnusedManagedMedia: Bool
    ) {
        planningTask?.cancel()
        error = nil
        result = nil
        isPlanning = true
        plan = nil
        planningTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try ProjectMediaConsolidator.makePlan(
                    manifest: manifest,
                    timeline: timeline,
                    projectURL: projectURL,
                    scope: scope,
                    cleanUnusedManagedMedia: cleanUnusedManagedMedia
                )
            }
            do {
                let nextPlan = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                plan = nextPlan
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            isPlanning = false
        }
    }

    func consolidate(
        project: VideoProject,
        operation: ConsolidationOperation,
        completion: @escaping @MainActor (String) -> Void
    ) {
        guard let plan, let projectURL = project.fileURL else { return }
        consolidationTask?.cancel()
        isConsolidating = true
        progress = 0
        error = nil
        result = nil

        let editor = project.editorViewModel
        let oldManifest = editor.mediaManifest
        let oldAssets = editor.mediaAssets
        consolidationTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try ProjectMediaConsolidator.apply(
                    plan: plan,
                    manifest: oldManifest,
                    projectURL: projectURL,
                    operation: operation,
                    progress: { value in
                        Task { @MainActor in self.progress = value }
                    }
                )
            }
            do {
                let change = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                do {
                    try Task.checkCancellation()
                } catch {
                    ProjectMediaConsolidator.removeFiles(change.installedURLs)
                    throw error
                }

                editor.mediaManifest = change.manifest
                editor.mediaAssets.removeAll { plan.cleanupEntryIDs.contains($0.id) }
                for asset in editor.mediaAssets {
                    if let url = change.assetURLs[asset.id] {
                        asset.url = url
                    }
                }
                project.updateChangeCount(.changeDone)

                do {
                    try await save(project)
                } catch {
                    editor.mediaManifest = oldManifest
                    editor.mediaAssets = oldAssets
                    ProjectMediaConsolidator.removeFiles(change.installedURLs)
                    project.updateChangeCount(.changeUndone)
                    throw error
                }

                let removalFailures = ProjectMediaConsolidator.removeFiles(
                    change.sourceURLsToRemove + change.cleanupURLs
                )
                progress = 1
                let count = change.assetURLs.count
                if removalFailures.isEmpty {
                    let removed = plan.cleanupEntryIDs.count
                    if count == 0, removed > 0 {
                        result = removed == 1 ? "Removed 1 unused media item." : "Removed \(removed) unused media items."
                    } else {
                        result = count == 1 ? "Consolidated 1 media file." : "Consolidated \(count) media files."
                    }
                } else {
                    result = "Media was consolidated, but \(removalFailures.count) original file\(removalFailures.count == 1 ? "" : "s") could not be removed."
                }
                if let result {
                    completion(result)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            isConsolidating = false
        }
    }

    func cancel() {
        planningTask?.cancel()
        consolidationTask?.cancel()
    }

    private func save(_ project: VideoProject) async throws {
        guard let url = project.fileURL else {
            throw ProjectMediaConsolidator.Error.projectNotSaved
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            project.save(
                to: url,
                ofType: VideoProject.typeIdentifier,
                for: .saveOperation
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

struct ConsolidateProjectMediaView: View {
    let project: VideoProject

    @State private var service = ProjectMediaConsolidationService()
    @State private var scope: ConsolidationScope = .all
    @State private var operation: ConsolidationOperation = .copy
    @State private var cleanUnusedManagedMedia = false
    @State private var confirmDestructiveOperation = false

    private var editor: EditorViewModel { project.editorViewModel }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsPanel
                    .frame(width: AppTheme.Window.exportSettingsWidth)
                summaryPanel
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(width: AppTheme.Window.export.width, height: AppTheme.Window.export.height)
        .presentationBackground {
            AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.sheet)
                .background(.ultraThinMaterial)
        }
        .task(id: refreshKey) {
            service.refresh(
                manifest: editor.mediaManifest,
                timeline: editor.timeline,
                projectURL: project.fileURL,
                scope: scope,
                cleanUnusedManagedMedia: cleanUnusedManagedMedia
            )
        }
        .onDisappear { service.cancel() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $confirmDestructiveOperation,
            titleVisibility: .visible
        ) {
            Button(confirmationButtonTitle, role: .destructive) {
                startConsolidation(operation)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var refreshKey: String {
        "\(scope.rawValue)-\(cleanUnusedManagedMedia)-\(editor.mediaManifest.entries.count)"
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            panelHeader("Consolidate")

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    settingRow(label: "Media") {
                        Picker("", selection: $scope) {
                            ForEach(ConsolidationScope.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(AppTheme.Opacity.moderate)

                    settingRow(label: "Operation") {
                        Picker("", selection: $operation) {
                            ForEach(ConsolidationOperation.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(AppTheme.Opacity.moderate)

                    if scope == .used {
                        settingRow(label: "Remove Unused") {
                            Toggle("", isOn: $cleanUnusedManagedMedia)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        Divider().opacity(AppTheme.Opacity.moderate)
                    }
                }

                Text(operationDescription)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.sm)

                if service.isPlanning {
                    HStack(spacing: AppTheme.Spacing.smMd) {
                        ProgressView().controlSize(.small)
                        Text("Calculating media size…")
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.top, AppTheme.Spacing.md)
                }

                if service.isConsolidating {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView(value: service.progress)
                            .progressViewStyle(.linear)
                        Text("\(Int(service.progress * 100))%")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .padding(.top, AppTheme.Spacing.md)
                }

                if let error = service.error {
                    Text(error)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .padding(.top, AppTheme.Spacing.sm)
                }

                if let result = service.result {
                    Text(result)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.top, AppTheme.Spacing.sm)
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.xl)
        }
    }

    private var operationDescription: String {
        switch operation {
        case .copy:
            "Copies external media into the project. Original files stay in place."
        case .move:
            "Copies media into the project, saves it, then removes the original files."
        }
    }

    private func settingRow<Control: View>(
        label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var summaryPanel: some View {
        ZStack {
            AppTheme.Background.baseColor

            if let plan = service.plan {
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.xl) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: AppTheme.FontSize.display, weight: AppTheme.FontWeight.light))
                            .foregroundStyle(AppTheme.Text.mutedColor)

                        VStack(spacing: AppTheme.Spacing.xs) {
                            Text(formatted(plan.totalBytes))
                                .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .monospacedDigit()
                            Text("\(externalFileCount(plan)) external file\(externalFileCount(plan) == 1 ? "" : "s")")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }

                        VStack(spacing: AppTheme.Spacing.smMd) {
                            summaryRow("Space available", value: plan.availableBytes.map(formatted) ?? "Unknown")
                            if plan.skippedInternalCount > 0 {
                                summaryRow("Already consolidated", value: "\(plan.skippedInternalCount)")
                            }
                            let duplicateCount = externalFileCount(plan) - plan.files.count
                            if duplicateCount > 0 {
                                summaryRow("Identical files", value: "\(duplicateCount) deduplicated")
                            }
                            if plan.renamedForConflictCount > 0 {
                                summaryRow("Name conflicts", value: "\(plan.renamedForConflictCount) renamed")
                            }
                            if !plan.cleanupEntryIDs.isEmpty {
                                summaryRow("Unused managed media", value: "\(plan.cleanupEntryIDs.count) to remove")
                            }
                        }
                        .frame(maxWidth: AppTheme.ComponentSize.consolidationSummaryWidth)

                        VStack(spacing: AppTheme.Spacing.xs) {
                            Text("Destination")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                            Text(plan.destinationURL.path)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: AppTheme.ComponentSize.consolidationSummaryWidth)

                        if !plan.missing.isEmpty {
                            missingFiles(plan.missing)
                                .frame(maxWidth: AppTheme.ComponentSize.consolidationSummaryWidth)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(AppTheme.Spacing.xlXxl)
                }
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .padding(AppTheme.Spacing.xl)
    }

    private func externalFileCount(_ plan: ProjectMediaConsolidationPlan) -> Int {
        plan.files.reduce(0) { $0 + $1.sourceURLs.count }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .monospacedDigit()
        }
        .font(.system(size: AppTheme.FontSize.smMd))
    }

    private func missingFiles(_ files: [ProjectMediaConsolidationPlan.Missing]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Label(
                "\(files.count) missing media file\(files.count == 1 ? "" : "s")",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Status.errorColor)

            ForEach(files.prefix(8)) { file in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(file.name)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(file.path)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: AppTheme.FontSize.sm))
            }
            if files.count > 8 {
                Text("\(files.count - 8) more")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }

    private var bottomBar: some View {
        HStack {
            if let plan = service.plan {
                HStack(spacing: AppTheme.Spacing.lg) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc.on.doc")
                        Text(formatted(plan.totalBytes))
                    }
                    Text("\(externalFileCount(plan)) file\(externalFileCount(plan) == 1 ? "" : "s")")
                    if !plan.missing.isEmpty {
                        Text("\(plan.missing.count) missing")
                            .foregroundStyle(AppTheme.Status.errorColor)
                    }
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            }

            Spacer()

            Button(service.isConsolidating ? "Stop" : "Cancel") {
                if service.isConsolidating {
                    service.cancel()
                } else {
                    editor.showConsolidateDialog = false
                }
            }
            .keyboardShortcut(.cancelAction)

            Button(operation == .copy ? "Consolidate" : "Move Media") {
                if operation == .move || cleanUnusedManagedMedia {
                    confirmDestructiveOperation = true
                } else {
                    startConsolidation(.copy)
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConsolidate)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private var canConsolidate: Bool {
        guard let plan = service.plan, !service.isPlanning, !service.isConsolidating else { return false }
        return !plan.files.isEmpty || !plan.cleanupEntryIDs.isEmpty
    }

    private var confirmationTitle: String {
        if operation == .move {
            return cleanUnusedManagedMedia ? "Move media and remove unused files?" : "Move original media?"
        }
        return "Remove unused managed media?"
    }

    private var confirmationButtonTitle: String {
        if operation == .move {
            return cleanUnusedManagedMedia ? "Move and Remove" : "Move Media"
        }
        return "Copy and Remove"
    }

    private var confirmationMessage: String {
        if operation == .move {
            return "Original files will be removed after the project is saved successfully."
        }
        return "Unused media already stored inside the project will be removed after the project is saved successfully."
    }

    private func startConsolidation(_ selectedOperation: ConsolidationOperation) {
        service.consolidate(project: project, operation: selectedOperation) { message in
            editor.showConsolidateDialog = false
            DispatchQueue.main.asyncAfter(deadline: .now() + AppTheme.Anim.transition) {
                showCompletionAlert(message)
            }
        }
    }

    private func showCompletionAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Project Media Consolidated"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")

        if let window = project.windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func formatted(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
