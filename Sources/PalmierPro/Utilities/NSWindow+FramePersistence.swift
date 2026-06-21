import AppKit
import ObjectiveC

@MainActor
private final class WindowFramePersistence: NSObject {
    private weak var window: NSWindow?
    private let autosaveName: String

    init(window: NSWindow, autosaveName: String) {
        self.window = window
        self.autosaveName = autosaveName
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveFrame(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveFrame(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func saveFrame(_ notification: Notification) {
        window?.saveFrame(usingName: autosaveName)
        UserDefaults.standard.synchronize()
    }
}

private nonisolated(unsafe) var windowFramePersistenceKey: UInt8 = 0

extension NSWindow {
    func restoreFrameOrCenter(autosaveName: String) {
        let restored = setFrameUsingName(autosaveName)
        _ = setFrameAutosaveName(autosaveName)
        if !restored {
            center()
        }

        let persistence = WindowFramePersistence(window: self, autosaveName: autosaveName)
        objc_setAssociatedObject(
            self,
            &windowFramePersistenceKey,
            persistence,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
