import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GlassesOutput {
    private(set) var isVisible = false
    private var panel: NSPanel?
    private var activity: NSObjectProtocol?
    private var displayID: CGDirectDisplayID?

    func present(displayID: CGDirectDisplayID, content: some View) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        if let panel, self.displayID == displayID {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            isVisible = true
            return
        }
        let panel = self.panel ?? NSPanel(contentRect: screen.frame,
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false, screen: screen)
        panel.title = "Prism XR · 空间桌面"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.backgroundColor = .black
        panel.ignoresMouseEvents = true
        // The output already contains the source desktop's menu bar. Cover the
        // physical glasses display's menu/status bars without changing the Mac.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        self.displayID = displayID
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                            reason: "空间桌面低延迟显示")
        }
        isVisible = true
    }

    func close() {
        panel?.close()
        panel = nil
        displayID = nil
        isVisible = false
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
