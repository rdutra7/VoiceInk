import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    weak var engine: VoiceInkEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        recoverOrphanedMeetings()
    }

    // Re-enqueue meeting recordings orphaned by a crash / force-quit before the
    // transcription pipeline consumed them. Runs off the launch critical path.
    private func recoverOrphanedMeetings() {
        guard let engine = engine else { return }
        Task { @MainActor in
            guard let mode = ModeManager.shared.currentEffectiveConfiguration
                ?? ModeManager.shared.enabledConfigurations.first else { return }
            MeetingRecoveryService.recover(engine: engine, mode: mode)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI’s WindowGroup-created ContentView and let it process this later.
            pendingOpenFileURL = url
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            menuBarManager?.focusMainWindow()
            NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
