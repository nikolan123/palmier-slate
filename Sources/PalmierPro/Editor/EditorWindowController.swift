import AppKit
import UniformTypeIdentifiers

/// Window controller that handles keyboard shortcuts via the responder chain.
/// Forwards actions to the EditorViewModel owned by VideoProject.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorViewModel: EditorViewModel
    private nonisolated(unsafe) var keyMonitor: Any?
    private nonisolated(unsafe) var mouseMonitor: Any?
    private var closeConfirmed = false
    private var closeConfirmationVisible = false

    init(editorViewModel: EditorViewModel, window: NSWindow) {
        self.editorViewModel = editorViewModel
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let hitView = self.window?.contentView?.hitTest(event.locationInWindow)
            self.resignStaleFocus(hitView: hitView)
            self.handlePanelClick(hitView: hitView)
            return event
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard GeneralPreferences.confirmBeforeClosingProject, !closeConfirmed else {
            closeConfirmed = false
            return true
        }
        guard !closeConfirmationVisible else { return false }

        closeConfirmationVisible = true
        let alert = NSAlert()
        alert.messageText = "Close this project?"
        alert.informativeText = "The project window will close."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.closeConfirmationVisible = false
            guard response == .alertFirstButtonReturn, let sender else { return }
            self.closeConfirmed = true
            DispatchQueue.main.async {
                sender.performClose(nil)
            }
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if handleEditorWindowShortcut(event) {
            return true
        }

        // Don't intercept keys when a text field has focus
        if isTextInputFocused {
            return false
        }

        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let cmd = mods.contains(.command)
        let rangeMarkShortcut = mods.intersection([.command, .option, .control]).isEmpty

        if editorViewModel.focusedPanel == .media, !shift,
           let direction = mediaArrowDirection(for: event.keyCode) {
            editorViewModel.moveMediaSelection(direction: direction)
            return true
        }

        switch event.keyCode {
        case 49: // Space
            editorViewModel.togglePlayback()
            return true

        case 123: // Left arrow
            if shift { editorViewModel.skipBackward() } else { editorViewModel.stepBackward() }
            return true

        case 124: // Right arrow
            if shift { editorViewModel.skipForward() } else { editorViewModel.stepForward() }
            return true

        case 51: // Delete/Backspace
            if !editorViewModel.selectedFolderIds.isEmpty || !editorViewModel.selectedMediaAssetIds.isEmpty {
                if !editorViewModel.selectedFolderIds.isEmpty {
                    editorViewModel.deleteFolders(ids: editorViewModel.selectedFolderIds)
                }
                if !editorViewModel.selectedMediaAssetIds.isEmpty {
                    editorViewModel.deleteSelectedMediaAssets()
                }
            } else if shift {
                if editorViewModel.selectedGap != nil {
                    editorViewModel.rippleDeleteSelectedGap()
                } else {
                    editorViewModel.rippleDeleteSelectedClips()
                }
            } else {
                editorViewModel.deleteSelectedClips()
            }
            return true

        case 8: // C key
            if !cmd {
                editorViewModel.toolMode = .razor
                return true
            }
            return false

        case 9: // V key
            if !cmd {
                editorViewModel.toolMode = .pointer
                return true
            }
            return false

        case 34: // I key
            if rangeMarkShortcut {
                editorViewModel.markTimelineRangeStart()
                return true
            }
            return false

        case 31: // O key
            if rangeMarkShortcut {
                editorViewModel.markTimelineRangeEnd()
                return true
            }
            return false

        case 33: // [ key
            editorViewModel.trimStartToPlayhead()
            return true

        case 30: // ] key
            editorViewModel.trimEndToPlayhead()
            return true

        case 50: // ` (backtick) — toggle panel maximize
            if mods.intersection([.command, .option, .control, .shift]).isEmpty {
                toggleMaximizePanelAction()
                return true
            }
            return false

        case 36: // Return / Enter
            if editorViewModel.focusedPanel == .media,
               editorViewModel.selectedFolderIds.count == 1,
               let folderId = editorViewModel.selectedFolderIds.first {
                editorViewModel.mediaPanelOpenFolderId = folderId
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            return false

        case 53: // Escape
            if editorViewModel.pendingSwapClipId != nil {
                editorViewModel.cancelMediaSwap()
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            if editorViewModel.maximizedPanel != nil {
                editorViewModel.maximizedPanel = nil
                return true
            }
            editorViewModel.selectedClipIds.removeAll()
            editorViewModel.clearTimelineRange()
            editorViewModel.toolMode = .pointer
            return true

        default:
            return false
        }
    }

    private func handleEditorWindowShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch event.keyCode {
        case 13 where mods == [.command]: // W
            editorViewModel.closeActivePreviewTab()
            return true
        case 13 where mods == [.command, .shift]: // Shift-W
            window?.performClose(nil)
            return true
        case 48 where mods == [.control]: // Tab
            editorViewModel.cyclePreviewTab()
            return true
        case 48 where mods == [.control, .shift]: // Shift-Tab
            editorViewModel.cyclePreviewTab(forward: false)
            return true
        default:
            return false
        }
    }

    private func mediaArrowDirection(for keyCode: UInt16) -> EditorViewModel.MediaSelectionDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    private var isTextInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let textField = responder as? NSTextField { return textField.isEditable }
        return false
    }

    private func handlePanelClick(hitView: NSView?) {
        var view = hitView
        while let v = view {
            if let panel = EditorViewModel.FocusedPanel(accessibilityID: v.accessibilityIdentifier()) {
                editorViewModel.focusedPanel = panel
                if panel == .media { editorViewModel.selectedClipIds.removeAll() }
                if panel == .timeline { editorViewModel.selectedMediaAssetIds.removeAll() }
                return
            }
            view = v.superview
        }
    }

    /// Clear stale first-responder focus before the click is dispatched.
    private func resignStaleFocus(hitView: NSView?) {
        // Don't disturb a deliberate click into a text input.
        if hitView is NSTextView || hitView is NSTextField { return }
        guard let responder = window?.firstResponder,
              let view = responder as? NSView, view !== window?.contentView else { return }
        window?.makeFirstResponder(nil)
    }
}

// MARK: - EditorActions (responder chain)

extension EditorWindowController: EditorActions {
    @objc func splitAtPlayhead(_ sender: Any?) { editorViewModel.splitAtPlayhead() }
    @objc func trimStartToPlayhead(_ sender: Any?) { editorViewModel.trimStartToPlayhead() }
    @objc func trimEndToPlayhead(_ sender: Any?) { editorViewModel.trimEndToPlayhead() }
    @objc func deleteSelectedClips(_ sender: Any?) { editorViewModel.deleteSelectedClips() }
    @objc func playPause(_ sender: Any?) { editorViewModel.togglePlayback() }
    @objc func stepFrameForward(_ sender: Any?) { editorViewModel.stepForward() }
    @objc func stepFrameBackward(_ sender: Any?) { editorViewModel.stepBackward() }
    @objc func skipFramesForward(_ sender: Any?) { editorViewModel.skipForward() }
    @objc func skipFramesBackward(_ sender: Any?) { editorViewModel.skipBackward() }

    @objc func importMedia(_ sender: Any?) {
        // Handled by MediaTab directly
    }

    @objc func showExport(_ sender: Any?) {
        editorViewModel.showExportDialog = true
    }

    @objc func importSRT(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.srtContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import SRT"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let captions = try SRTCaptionCodec.parse(text)
                let ids = self.editorViewModel.importSRTCaptions(
                    captions,
                    style: TextStyle(fontSize: AppTheme.Caption.defaultFontSize),
                    center: AppTheme.Caption.defaultCenter
                )
                if ids.isEmpty { self.presentMessage("No captions were imported.") }
            } catch {
                self.presentMessage(error.localizedDescription)
            }
        }
    }

    @objc func exportSRTCaptionsOnly(_ sender: Any?) {
        exportSRT(includeAllText: false)
    }

    @objc func exportSRTAllText(_ sender: Any?) {
        exportSRT(includeAllText: true)
    }

    @objc func showConsolidateProjectMedia(_ sender: Any?) {
        editorViewModel.showConsolidateDialog = true
    }

    @objc func copy(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
    }

    @objc func cut(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
        editorViewModel.deleteSelectedClips()
    }

    @objc func paste(_ sender: Any?) {
        if editorViewModel.focusedPanel == .media {
            editorViewModel.mediaPanelPasteRequestTick &+= 1
            return
        }
        guard canHandleClipboardShortcut(),
              editorViewModel.canPasteClips else { return }
        editorViewModel.pasteClipsAtPlayhead()
    }

    private func canHandleClipboardShortcut() -> Bool {
        editorViewModel.focusedPanel == .timeline
    }

    private static var srtContentType: UTType {
        UTType(filenameExtension: "srt") ?? .plainText
    }

    private func exportSRT(includeAllText: Bool) {
        let captions = editorViewModel.exportSRTCaptions(includeAllText: includeAllText)
        guard !captions.isEmpty else {
            presentMessage(includeAllText ? "No text to export." : "No captions to export.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.srtContentType]
        panel.nameFieldStringValue = (editorViewModel.projectURL?.deletingPathExtension().lastPathComponent ?? "Captions") + ".srt"
        panel.title = "Export SRT"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try SRTCaptionCodec.encode(captions).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.presentMessage(error.localizedDescription)
            }
        }
    }

    private func presentMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func toggleMediaPanel(_ sender: Any?) { editorViewModel.mediaPanelVisible.toggle() }
    @objc func toggleInspectorPanel(_ sender: Any?) { editorViewModel.inspectorPanelVisible.toggle() }
    @objc func toggleAgentPanel(_ sender: Any?) {
        guard AppState.shared.claudeIntegrationEnabled else { return }
        editorViewModel.agentPanelVisible.toggle()
    }
    @objc func toggleMaximizePanel(_ sender: Any?) { toggleMaximizePanelAction() }
    @objc func togglePreviewFullscreen(_ sender: Any?) {
        editorViewModel.maximizedPanel = editorViewModel.maximizedPanel == .preview ? nil : .preview
        editorViewModel.focusedPanel = .preview
    }
    @objc func setLayoutDefault(_ sender: Any?) { editorViewModel.layoutPreset = .default }
    @objc func setLayoutMedia(_ sender: Any?) { editorViewModel.layoutPreset = .media }
    @objc func setLayoutVertical(_ sender: Any?) { editorViewModel.layoutPreset = .vertical }

    private func toggleMaximizePanelAction() {
        if editorViewModel.maximizedPanel != nil {
            editorViewModel.maximizedPanel = nil
        } else if let panel = editorViewModel.focusedPanel {
            editorViewModel.maximizedPanel = panel
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMediaPanel(_:)):
            menuItem.state = editorViewModel.mediaPanelVisible ? .on : .off
            return true
        case #selector(toggleInspectorPanel(_:)):
            menuItem.state = editorViewModel.inspectorPanelVisible ? .on : .off
            return true
        case #selector(toggleAgentPanel(_:)):
            menuItem.state = editorViewModel.agentPanelVisible ? .on : .off
            return AppState.shared.claudeIntegrationEnabled
        case #selector(toggleMaximizePanel(_:)):
            menuItem.state = editorViewModel.maximizedPanel != nil ? .on : .off
            return editorViewModel.maximizedPanel != nil || editorViewModel.focusedPanel != nil
        case #selector(togglePreviewFullscreen(_:)):
            menuItem.state = editorViewModel.maximizedPanel == .preview ? .on : .off
            return true
        case #selector(setLayoutDefault(_:)):
            menuItem.state = editorViewModel.layoutPreset == .default ? .on : .off
            return true
        case #selector(setLayoutMedia(_:)):
            menuItem.state = editorViewModel.layoutPreset == .media ? .on : .off
            return true
        case #selector(setLayoutVertical(_:)):
            menuItem.state = editorViewModel.layoutPreset == .vertical ? .on : .off
            return true
        case #selector(exportSRTCaptionsOnly(_:)):
            return !editorViewModel.exportSRTCaptions().isEmpty
        case #selector(exportSRTAllText(_:)):
            return !editorViewModel.exportSRTCaptions(includeAllText: true).isEmpty
        case #selector(copy(_:)), #selector(cut(_:)):
            return canHandleClipboardShortcut() && !editorViewModel.selectedClipIds.isEmpty
        case #selector(paste(_:)):
            if editorViewModel.focusedPanel == .media {
                return MediaTab.clipboardHasImportableMedia()
            }
            return canHandleClipboardShortcut() && editorViewModel.canPasteClips
        default:
            return true
        }
    }
}
