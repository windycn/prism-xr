import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import SwiftUI

struct OutputDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String

    var supportsGTMaxControls: Bool {
        CGDisplayVendorNumber(id) == 20588 && CGDisplayModelNumber(id) == 980
    }
}

struct DesktopRequest: Equatable {
    let enabled: Bool
    let layout: WorkspaceLayout
    let targets: [String: ScreenTarget]
    let refresh: RefreshRate
    let mirroredPanel: Int?
}

@MainActor
@Observable
final class SpatialDesktop: NSObject, SCStreamDelegate {
    private(set) var isEnabled = false
    private(set) var isStarting = false
    private(set) var outputAvailable = false
    private(set) var outputDisplays: [OutputDisplay] = []
    private(set) var selectedOutputID: CGDirectDisplayID?
    var automaticOutputLabel: String {
        outputDisplays.filter(\.supportsGTMaxControls).count == 1 ? "已识别 RayNeo GT Max" : "自动选择"
    }

    var supportsOutputTracking: Bool {
        outputDisplays.first(where: { $0.id == glassesDisplayID })?.supportsGTMaxControls == true
    }

    func selectOutput(_ id: CGDirectDisplayID?) {
        guard !isEnabled else { return }
        selectedOutputID = id
        error = nil
        refreshGlassesConnection()
    }
    private(set) var requiresCapturePermission = false
    private(set) var activeCount = 0
    private(set) var frames: [Int: CGImage] = [:]
    let frameStore = SpatialFrameStore()
    private(set) var error: String?
    private(set) var status = "尚未启动空间桌面"

    private var operation: Task<Void, Never>?
    private var resources: DesktopResources?
    private var activeLayout: WorkspaceLayout?
    private var generation = UUID()
    private var cursorTimer: Timer?
    private var cursorMap: [CursorScreen] = []
    private var primaryDisplayID: CGDirectDisplayID?
    private var lastCursor: CGPoint?
    private var lastSafeCursor: CGPoint?
    private var lastWarp = Date.distantPast
    private var originalGlasses: (id: CGDirectDisplayID, mirror: CGDirectDisplayID, origin: CGPoint)?
    private(set) var glassesDisplayID: CGDirectDisplayID?
    private var identificationPanels: [NSPanel] = []
    private var identificationTask: Task<Void, Never>?

    func request(layout: WorkspaceLayout, preferences: LayoutPreferences) -> DesktopRequest {
        DesktopRequest(enabled: isEnabled, layout: layout, targets: preferences.targets, refresh: preferences.refresh,
                       mirroredPanel: layout.mirroredPanelID(using: preferences))
    }

    override init() {
        super.init()
        refreshGlassesConnection()
    }

    func enable() {
        refreshGlassesConnection()
        guard outputAvailable else {
            error = "尚未检测到眼镜视频输出。可以先调整布局，连接眼镜后再启动。"
            return
        }
        isEnabled = true
    }

    func openCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func update(_ request: DesktopRequest) {
        operation?.cancel()
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await clearResources()
            guard request.enabled, isEnabled else {
                isStarting = false
                restoreGlasses()
                status = "空间桌面已停止"
                return
            }
            await start(request)
        }
    }

    func stop() {
        isEnabled = false
        generation = UUID()
        frames = [:]
        operation?.cancel()
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            await self?.clearResources()
            self?.restoreGlasses()
            self?.isStarting = false
            self?.status = "空间桌面已停止"
        }
    }

    private func start(_ request: DesktopRequest) async {
        isStarting = true
        error = nil
        requiresCapturePermission = false
        status = "正在创建独立显示器…"
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = "请在系统设置中允许 Prism XR 录制屏幕，再启动空间桌面。"
            requiresCapturePermission = true
            isEnabled = false
            isStarting = false
            status = "需要屏幕录制权限"
            return
        }
        let token = UUID()
        generation = token
        let pending = DesktopResources()
        do {
            guard let mirroredPanel = request.mirroredPanel, let mac = findMacDisplay() else {
                throw DesktopError.macUnavailable
            }
            let screens = request.layout.configurableScreens
            for screen in screens {
                try Task.checkCancellation()
                let target = request.targets[screen.id] ?? screen.target
                if screen.panel.id == mirroredPanel {
                    pending.sources.append(DesktopSource(panel: screen.panel.id, displayID: mac, target: target, isMirror: true, name: screen.name))
                    continue
                }
                guard target.isValid,
                      let display = PrismVirtualDisplay(width: UInt(target.width), height: UInt(target.height),
                                                        hiDPI: target.hiDPI,
                                                        refreshRate: Double(request.refresh.rawValue),
                                                        number: identity(request.layout.id + screen.id),
                                                        name: "Prism XR · \(screen.name)") else {
                    throw DesktopError.createDisplay
                }
                pending.displays.append((screen.panel.id, display, target))
                pending.sources.append(DesktopSource(panel: screen.panel.id, displayID: display.displayID, target: target, isMirror: false, name: screen.name))
            }
            try await Task.sleep(for: .milliseconds(350))
            guard findGlasses() != nil else { throw DesktopError.outputDisconnected }
            try configure(pending, layout: request.layout)
            var available: SCShareableContent?
            status = "正在接入桌面来源…"
            for _ in 0..<12 {
                try Task.checkCancellation()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let ids = Set(content.displays.map(\.displayID))
                if pending.sources.allSatisfy({ ids.contains($0.displayID) }) {
                    available = content
                    break
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            guard let available else { throw DesktopError.notVisible }
            for entry in pending.sources {
                try Task.checkCancellation()
                guard let display = available.displays.first(where: { $0.displayID == entry.displayID }) else {
                    throw DesktopError.notVisible
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                let target = entry.target
                let scale = target.hiDPI ? 2 : 1
                let displayMode = CGDisplayCopyDisplayMode(entry.displayID)
                let sourceWidth = entry.isMirror ? (displayMode?.pixelWidth ?? target.width) : target.width * scale
                let sourceHeight = entry.isMirror ? (displayMode?.pixelHeight ?? target.height) : target.height * scale
                let captureScale = min(1, 4096.0 / Double(max(sourceWidth, sourceHeight)))
                configuration.width = max(2, Int(Double(sourceWidth) * captureScale) / 2 * 2)
                configuration.height = max(2, Int(Double(sourceHeight) * captureScale) / 2 * 2)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.queueDepth = 3
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = true
                let panelID = entry.panel
                let output = SpatialCaptureOutput(store: frameStore, panel: panelID, previewEnabled: !entry.isMirror) { [weak self] image in
                    guard let self, self.generation == token, self.isEnabled else { return }
                    self.frames[panelID] = image
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                pending.streams.append((stream, output))
                try await stream.startCapture()
            }
            for _ in 0..<50 {
                try Task.checkCancellation()
                let ready = frameStore.latest()
                if pending.sources.allSatisfy({ ready[$0.panel] != nil }) { break }
                status = "等待画面就绪 · \(ready.count)/\(pending.sources.count)"
                try await Task.sleep(for: .milliseconds(100))
            }
            let ready = frameStore.latest()
            guard pending.sources.allSatisfy({ ready[$0.panel] != nil }) else { throw DesktopError.noFrames }
            try Task.checkCancellation()
            guard generation == token, isEnabled else { throw CancellationError() }
            guard findGlasses() == glassesDisplayID, glassesDisplayID != nil else { throw DesktopError.outputDisconnected }
            resources = pending
            activeLayout = request.layout
            activeCount = pending.sources.count
            startCursorBridge()
            isStarting = false
            status = "\(activeCount) 块工作屏 · 1 块 Mac 内屏镜像 + \(pending.displays.count) 块独立副屏"
        } catch {
            await pending.close()
            guard generation == token, !Task.isCancelled else { return }
            frameStore.reset()
            restoreGlasses()
            self.error = error.localizedDescription
            isStarting = false
            isEnabled = false
            activeCount = 0
            frames = [:]
            status = "空间桌面启动失败"
        }
    }

    private func clearResources() async {
        closeIdentification()
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorMap = []
        lastCursor = nil
        lastSafeCursor = nil
        generation = UUID()
        let old = resources
        resources = nil
        activeLayout = nil
        frames = [:]
        frameStore.reset()
        activeCount = 0
        await old?.close()
    }

    private func identity(_ key: String) -> UInt32 {
        key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } | 1
    }

    private func configure(_ pending: DesktopResources, layout: WorkspaceLayout) throws {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw DesktopError.configure
        }
        var commit = false
        defer { if !commit { CGCancelDisplayConfiguration(configuration) } }
        let owned = Set(pending.displays.map { $0.display.displayID })
        let glasses = findGlasses()
        let physicalRight = NSScreen.screens.compactMap { screen -> CGFloat? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  !owned.contains(id.uint32Value), id.uint32Value != glasses else { return nil }
            return CGDisplayBounds(id.uint32Value).maxX
        }.max() ?? 1920
        let arrangement = arrangement(for: pending, layout: layout, originX: physicalRight + 64)
        if let glasses {
            glassesDisplayID = glasses
            if originalGlasses == nil {
                originalGlasses = (glasses, CGDisplayMirrorsDisplay(glasses), CGDisplayBounds(glasses).origin)
            }
            // The physical output must never overlap a source desktop.
            let outputX = max(physicalRight, arrangement.values.map(\.maxX).max() ?? physicalRight) + 64
            guard CGConfigureDisplayMirrorOfDisplay(configuration, glasses, kCGNullDirectDisplay) == .success,
                  CGConfigureDisplayOrigin(configuration, glasses, Int32(outputX), 0) == .success else {
                throw DesktopError.configure
            }
        }
        for entry in pending.displays {
            let displayID = entry.display.displayID
            let scale = entry.target.hiDPI ? 2 : 1
            let modes = (CGDisplayCopyAllDisplayModes(displayID,
                [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]) ?? []
            guard let mode = modes.first(where: {
                $0.width == entry.target.width && $0.height == entry.target.height &&
                    $0.pixelWidth == entry.target.width * scale && $0.pixelHeight == entry.target.height * scale
            }) else { throw DesktopError.unavailableMode(entry.target.logicalLabel, entry.target.hiDPI) }
            guard CGConfigureDisplayMirrorOfDisplay(configuration, displayID, kCGNullDirectDisplay) == .success,
                  CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success,
                  CGConfigureDisplayOrigin(configuration, displayID,
                                           Int32(arrangement[entry.panel]?.origin.x ?? physicalRight),
                                           Int32(arrangement[entry.panel]?.origin.y ?? 0)) == .success else {
                throw DesktopError.configure
            }
        }
        guard CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success else {
            throw DesktopError.configure
        }
        commit = true
        primaryDisplayID = pending.sources.first(where: { source in layout.panels.contains { $0.id == source.panel && $0.primary } })?.displayID
        cursorMap = pending.sources.compactMap { entry in
            guard let panel = layout.panels.first(where: { $0.id == entry.panel }),
                  let bounds = arrangement[entry.panel] else { return nil }
            return CursorScreen(displayID: entry.displayID, bounds: bounds,
                                sceneBounds: CGRect(x: panel.x - panel.width / 2, y: panel.y - panel.height / 2,
                                                    width: panel.width, height: panel.height))
        }
    }

    private func arrangement(for resources: DesktopResources, layout: WorkspaceLayout, originX: CGFloat) -> [Int: CGRect] {
        let panels = Dictionary(uniqueKeysWithValues: layout.panels.map { ($0.id, $0) })
        let scale = resources.sources.compactMap { entry -> CGFloat? in
            guard let panel = panels[entry.panel] else { return nil }
            let bounds = entry.isMirror ? CGDisplayBounds(entry.displayID) : CGRect(x: 0, y: 0, width: entry.target.width, height: entry.target.height)
            return max(bounds.width / panel.width, bounds.height / panel.height)
        }.max() ?? 4000
        var rects = resources.sources.map { entry -> (Int, CGRect) in
            let panel = panels[entry.panel]!
            let width = entry.isMirror ? CGDisplayBounds(entry.displayID).width : CGFloat(entry.target.width)
            let height = entry.isMirror ? CGDisplayBounds(entry.displayID).height : CGFloat(entry.target.height)
            let x = panel.x * scale - width / 2
            let y = panel.y * scale - height / 2
            return (entry.panel, CGRect(x: x, y: y, width: width, height: height))
        }
        // Remove empty strips while preserving the visual order and alignment.
        for horizontal in [true, false] {
            let intervals = rects.map { horizontal ? ($0.1.minX, $0.1.maxX) : ($0.1.minY, $0.1.maxY) }
                .sorted { $0.0 < $1.0 }
            var end = intervals.first?.1 ?? 0
            var gaps: [(CGFloat, CGFloat)] = []
            for interval in intervals.dropFirst() {
                if interval.0 > end { gaps.append((end, interval.0)) }
                end = max(end, interval.1)
            }
            rects = rects.map { id, rect in
                let start = horizontal ? rect.minX : rect.minY
                let removed = gaps.filter { $0.1 <= start + 0.01 }.reduce(CGFloat.zero) { $0 + $1.1 - $1.0 }
                return (id, rect.offsetBy(dx: horizontal ? -removed : 0, dy: horizontal ? 0 : -removed))
            }
        }
        let minX = rects.map { $0.1.minX }.min() ?? 0
        let minY = rects.map { $0.1.minY }.min() ?? 0
        var dx = originX - minX, dy = -minY
        if let mirrored = resources.sources.first(where: \.isMirror),
           let virtual = rects.first(where: { $0.0 == mirrored.panel })?.1 {
            let actual = CGDisplayBounds(mirrored.displayID)
            dx = actual.minX - virtual.minX
            dy = actual.minY - virtual.minY
        }
        return Dictionary(uniqueKeysWithValues: rects.map { id, rect in
            (id, rect.offsetBy(dx: dx, dy: dy).integral)
        })
    }

    private func startCursorBridge() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridgeCursor() }
        }
        if let cursorTimer { RunLoop.main.add(cursorTimer, forMode: .common) }
    }

    private func bridgeCursor() {
        guard let point = CGEvent(source: nil)?.location else { return }
        let previous = lastCursor
        lastCursor = point
        if cursorMap.contains(where: { $0.bounds.contains(point) }) { lastSafeCursor = point }
        if let glassesDisplayID,
           let fenced = SpatialCursorRouter.fenceOutput(point: point, output: CGDisplayBounds(glassesDisplayID),
                                                       screens: cursorMap, lastSafe: lastSafeCursor),
           Date().timeIntervalSince(lastWarp) > 0.15 {
            CGWarpMouseCursorPosition(fenced)
            lastCursor = fenced
            lastWarp = Date()
            return
        }
        guard Date().timeIntervalSince(lastWarp) > 0.15, let previous,
              let transfer = SpatialCursorRouter.transfer(previous: previous, current: point, screens: cursorMap) else { return }
        CGWarpMouseCursorPosition(transfer.point)
        lastCursor = transfer.point
        lastWarp = Date()
    }

    func moveCursorToPrimary() {
        guard let primaryDisplayID else { return }
        let rect = CGDisplayBounds(primaryDisplayID)
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
    }

    func identifyDisplays() {
        closeIdentification()
        guard let resources else { return }
        for (index, entry) in resources.sources.enumerated() {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == entry.displayID
            }) else { continue }
            let size = CGSize(width: min(620, screen.frame.width * 0.75), height: min(360, screen.frame.height * 0.7))
            let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false, screen: screen)
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView:
                VStack(spacing: 12) {
                    Text("\(index + 1)").font(.system(size: 100, weight: .bold, design: .rounded))
                    Text(entry.name).font(.title.weight(.semibold))
                    Text(entry.isMirror ? "Mac 内屏镜像" : "独立副屏").font(.headline)
                    Text("\(Int(CGDisplayBounds(entry.displayID).width)) × \(Int(CGDisplayBounds(entry.displayID).height)) pt")
                        .font(.subheadline.monospacedDigit())
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hue: Double(index) / Double(max(3, resources.sources.count)), saturation: 0.65, brightness: 0.48)))
            panel.orderFrontRegardless()
            identificationPanels.append(panel)
        }
        identificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.closeIdentification()
        }
    }

    private func closeIdentification() {
        identificationTask?.cancel()
        identificationTask = nil
        identificationPanels.forEach { $0.close() }
        identificationPanels = []
    }

    func refreshGlassesConnection() {
        outputDisplays = externalDisplays()
        let connected = findGlasses()
        outputAvailable = connected != nil
        if connected == nil, selectedOutputID != nil {
            selectedOutputID = nil
            error = "所选视频输出已断开，请重新选择。"
            if isEnabled { stop() }
            outputAvailable = findGlasses() != nil
            return
        }
        guard isEnabled, activeCount > 0 else { return }
        let previous = glassesDisplayID
        if let previous, previous != connected { restoreGlasses() }
        glassesDisplayID = connected
        if let connected, (connected != previous || CGDisplayMirrorsDisplay(connected) != kCGNullDirectDisplay),
           let resources, let activeLayout {
            do { try configure(resources, layout: activeLayout) }
            catch {
                self.error = error.localizedDescription
                stop()
                return
            }
        }
        status = "\(activeCount) 块工作屏 · 1 块 Mac 内屏镜像 + \(max(0, activeCount - 1)) 块独立副屏" +
            (connected == nil ? " · 等待眼镜视频连接" : "")
    }

    private func findMacDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let online = ids.prefix(Int(count))
        return online.first(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    private func findGlasses() -> CGDirectDisplayID? {
        let displays = externalDisplays()
        if let selectedOutputID {
            return displays.first { $0.id == selectedOutputID }?.id
        }
        let matches = displays.filter(\.supportsGTMaxControls)
        return matches.count == 1 ? matches.first?.id : nil
    }

    private func externalDisplays() -> [OutputDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0, CGDisplayVendorNumber(id) != 0x5052 else { return nil }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? "外接显示器"
            return OutputDisplay(id: id, name: "\(name) · \(id)")
        }
    }

    private func restoreGlasses() {
        glassesDisplayID = nil
        guard let original = originalGlasses else { return }
        originalGlasses = nil
        guard CGDisplayIsOnline(original.id) != 0 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if CGConfigureDisplayMirrorOfDisplay(config, original.id, original.mirror) == .success &&
            CGConfigureDisplayOrigin(config, original.id, Int32(original.origin.x), Int32(original.origin.y)) == .success {
            CGCompleteDisplayConfiguration(config, .forAppOnly)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            guard resources?.streams.contains(where: { ObjectIdentifier($0.stream) == id }) == true else { return }
            self.error = error.localizedDescription
            stop()
        }
    }
}

@MainActor
private final class DesktopResources {
    var displays: [(panel: Int, display: PrismVirtualDisplay, target: ScreenTarget)] = []
    var sources: [DesktopSource] = []
    var streams: [(stream: SCStream, output: SpatialCaptureOutput)] = []

    func close() async {
        for entry in streams { try? await entry.stream.stopCapture() }
        streams = []
        displays = []
        sources = []
    }
}

private struct DesktopSource {
    let panel: Int
    let displayID: CGDirectDisplayID
    let target: ScreenTarget
    let isMirror: Bool
    let name: String
}

private enum DesktopError: LocalizedError {
    case outputDisconnected
    case createDisplay, configure, notVisible, macUnavailable, noFrames
    case unavailableMode(String, Bool)

    var errorDescription: String? {
        switch self {
        case .outputDisconnected: "眼镜视频输出已断开，请重新连接或选择输出后再试。"
        case .createDisplay: "无法创建虚拟显示器。"
        case .macUnavailable: "未找到可镜像的 Mac 显示器，请稍后重新启动空间桌面。"
        case .noFrames: "屏幕来源尚未返回画面，请停止后重新启动空间桌面。"
        case .configure: "无法配置虚拟显示器的分辨率和排列。"
        case .notVisible: "系统尚未返回新创建的显示器。"
        case .unavailableMode(let size, let hiDPI):
            "系统未提供目标 \(size)\(hiDPI ? " HiDPI" : "") 模式，请调整布局参数后重试。"
        }
    }
}
