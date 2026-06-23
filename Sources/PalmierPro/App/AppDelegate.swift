import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitConfirmationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        HomeWindowController.shared.showWindow(nil)
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()

        AppState.shared.startMCPService()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard GeneralPreferences.confirmBeforeClosingProject,
              let window = AppState.shared.activeProject?.windowControllers.first?.window else {
            return .terminateNow
        }
        guard !quitConfirmationPending else { return .terminateLater }

        quitConfirmationPending = true
        let alert = NSAlert()
        alert.messageText = "Quit Palmier Slate?"
        alert.informativeText = "The open project will close."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak sender] response in
            self?.quitConfirmationPending = false
            sender?.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
        }
        return .terminateLater
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createNewProject()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
