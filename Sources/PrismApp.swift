import AppKit
import SwiftUI

struct PrismApp: App {
    @State private var capture = CaptureSession()
    @State private var stereo = StereoSession()
    @State private var layouts = LayoutLibrary()
    @State private var tracker = RayneoTracker()
    @State private var desktop = SpatialDesktop()
    @State private var glassesOutput = GlassesOutput()
    @State private var brightness = InternalBrightness()
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var roll = 0.0
    @State private var workspaceStereoEnabled = false
    @AppStorage("stereoDisparity") private var disparity = 12.0
    @AppStorage("stereoSwapEyes") private var swapEyes = false

    var body: some Scene {
        Window("Prism XR", id: "main") {
            AppWindow(capture: capture, stereo: stereo, layouts: layouts, tracker: tracker, desktop: desktop, glassesOutput: glassesOutput, brightness: brightness, yaw: $yaw, pitch: $pitch, roll: $roll,
                      workspaceStereoEnabled: $workspaceStereoEnabled)
                .tint(Palette.accent)
                .frame(minWidth: 830, minHeight: 610)
        }
        .defaultSize(width: 1150, height: 805)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { Task { await ReleaseCheck.run() } }
                    .disabled(ReleaseCheck.shared.isChecking)
            }
        }

        Window("工作区 SBS 输出", id: "workspace-output") {
            WorkspaceStereoOutput(capture: capture, desktop: desktop, stereo: stereo, layout: layouts.selection,
                                  preferences: layouts.preferences, yaw: yaw, pitch: pitch, roll: roll,
                                  convertsPrimary: workspaceStereoEnabled, swapEyes: swapEyes)
        }
        .defaultSize(width: 960, height: 270)
        .windowToolbarStyle(.unified)

        Window("SBS 输出", id: "stereo-output") {
            StereoSurface(source: stereo.source, pair: stereo.pair, disparity: disparity, swapEyes: swapEyes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        }
        .defaultSize(width: 960, height: 270)
        .windowToolbarStyle(.unified)
    }
}

@main
enum PrismLauncher {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--brightness-keeper") {
            BrightnessKeeper.run()
        } else {
            PrismApp.main()
        }
    }
}

struct AppWindow: View {
    let capture: CaptureSession
    let stereo: StereoSession
    let layouts: LayoutLibrary
    let tracker: RayneoTracker
    let desktop: SpatialDesktop
    let glassesOutput: GlassesOutput
    let brightness: InternalBrightness
    @AppStorage("stereoDisparity") private var disparity = 12.0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var yaw: Double
    @Binding var pitch: Double
    @Binding var roll: Double
    @Binding var workspaceStereoEnabled: Bool
    @State private var destination: Destination = .workspace
    @State private var displayRefreshTask: Task<Void, Never>?
    @AppStorage("lockWorkspaceHorizon") private var lockHorizon = true

    var body: some View {
        ZStack {
            page
                .id(destination)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: destination)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaBar(edge: .bottom, spacing: 0) {
            BottomTabBar(selection: $destination)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if destination == .workspace {
                    Button {
                        if tracker.isRunning { tracker.recenter() }
                        yaw = 0
                        pitch = 0
                        roll = 0
                    } label: {
                        Label("视角回正", systemImage: "scope")
                    }
                    .help("视角回正（⇧⌘R）")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                if destination == .stereo {
                    Button {
                        openWindow(id: destination == .workspace ? "workspace-output" : "stereo-output")
                    } label: {
                        Label("SBS 输出", systemImage: "rectangle.split.2x1")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(destination == .stereo && stereo.source != .pattern && stereo.pair == nil)
                    .help("打开独立的左右眼输出窗口")
                }
            }
        }
        .task(id: desktop.request(layout: layouts.selection, preferences: layouts.preferences)) {
            desktop.update(desktop.request(layout: layouts.selection, preferences: layouts.preferences))
        }
        .onChange(of: desktop.activeCount) {
            if desktop.activeCount > 0, let id = desktop.glassesDisplayID {
                glassesOutput.present(displayID: id,
                    content: WorkspaceGPUOutput(layouts: layouts, desktop: desktop, tracker: tracker))
                if desktop.supportsOutputTracking && layouts.preferences.mode == .lookAround && !tracker.isRunning {
                    tracker.startAutomatically()
                }
            } else {
                if !desktop.isEnabled { brightness.restore() }
                glassesOutput.close()
            }
        }
        .onChange(of: desktop.glassesDisplayID) { updateGlassesOutput() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayRefreshTask?.cancel()
            displayRefreshTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                desktop.refreshGlassesConnection()
                updateGlassesOutput()
            }
        }
        .onChange(of: desktop.isEnabled) {
            if !desktop.isEnabled { tracker.stop(); brightness.restore() }
        }
        .onChange(of: layouts.preferences.mode) {
            if desktop.activeCount > 0, desktop.supportsOutputTracking, layouts.preferences.mode == .lookAround, !tracker.isRunning {
                tracker.startAutomatically()
            }
        }
        .onChange(of: tracker.connected) {
            if desktop.supportsOutputTracking, !tracker.connected, tracker.status == "眼镜已断开", desktop.isEnabled { desktop.stop(); brightness.restore() }
        }
        .task(id: stereo.source) {
            guard stereo.source == .live else { return }
            var lastFrame: CGImage?
            while !Task.isCancelled {
                if let frame = capture.frame, frame !== lastFrame, !stereo.isProcessing {
                    lastFrame = frame
                    stereo.submit(frame, disparity: disparity)
                }
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
        }
        .onChange(of: capture.isCapturing) {
            if !capture.isCapturing, stereo.source == .live { stereo.reset() }
        }
        .onChange(of: tracker.pose) {
            guard tracker.isRunning else { yaw = 0; pitch = 0; roll = 0; return }
            yaw = min(40, max(-40, tracker.pose.yaw))
            pitch = min(26, max(-26, tracker.pose.pitch))
            roll = lockHorizon ? 0 : tracker.pose.roll
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            tracker.stop()
            desktop.stop()
            brightness.restore()
            glassesOutput.close()
        }
        .onDisappear { displayRefreshTask?.cancel(); capture.stop(); tracker.stop(); desktop.stop(); brightness.restore(); glassesOutput.close() }
    }

    private func updateGlassesOutput() {
        guard desktop.isEnabled, desktop.activeCount > 0, let id = desktop.glassesDisplayID else {
            glassesOutput.close()
            if !desktop.isEnabled || desktop.glassesDisplayID == nil {
                brightness.restore()
                if tracker.isRunning { tracker.stop() }
            }
            return
        }
        glassesOutput.present(displayID: id, content: WorkspaceGPUOutput(layouts: layouts, desktop: desktop, tracker: tracker))
        if desktop.supportsOutputTracking && layouts.preferences.mode == .lookAround && !tracker.isRunning { tracker.startAutomatically() }
    }

    @ViewBuilder
    private var page: some View {
        switch destination {
        case .workspace:
            WorkspaceView(capture: capture, stereo: stereo, layouts: layouts, desktop: desktop, tracker: tracker,
                          brightness: brightness, roll: roll,
                          yaw: $yaw, pitch: $pitch,
                          stereoEnabled: $workspaceStereoEnabled)
        case .stereo:
            StereoView(session: stereo, capture: capture)
        case .devices:
            DeviceView(tracker: tracker, desktop: desktop)
        }
    }
}

private struct BottomTabBar: View {
    @Binding var selection: Destination
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tabs = Destination.allCases

    private var selectedIndex: Int { tabs.firstIndex(of: selection) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, destination in
                tabButton(destination)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
            }
        }
        .background {
            GeometryReader { proxy in
                let tabWidth = proxy.size.width / CGFloat(tabs.count)
                Capsule()
                    .fill(.primary.opacity(0.075))
                    .frame(width: tabWidth)
                    .offset(x: CGFloat(selectedIndex) * tabWidth)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.29), value: selectedIndex)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(4)
        .frame(maxWidth: 400)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("应用导航")
    }

    private func tabButton(_ destination: Destination) -> some View {
        let selected = destination == selection
        return Button {
            selection = destination
        } label: {
            VStack(spacing: 3) {
                destination.icon
                    .font(.system(size: 22, weight: selected ? .semibold : .medium))
                    .frame(width: 26, height: 24)
                    .accessibilityHidden(true)
                Text(destination.name)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Palette.accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selected)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(destination.name)
    }
}

struct PageHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 31, weight: .semibold, design: .default))
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Observable
private final class ReleaseCheck {
    static let shared = ReleaseCheck()
    private(set) var isChecking = false

    private struct Release: Decodable {
        let tag_name: String
    }

    static func run() async {
        guard !shared.isChecking else { return }
        shared.isChecking = true
        defer { shared.isChecking = false }

        let alert = NSAlert()
        do {
            guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let current = version(installed) else { throw URLError(.cannotParseResponse) }
            let tag = try await latestTag()
            guard let latest = version(tag) else { throw URLError(.cannotParseResponse) }
            if current.lexicographicallyPrecedes(latest) {
                alert.messageText = "发现新版 Prism XR"
                alert.informativeText = "当前版本 \(installed)，最新版本 \(tag)。"
                alert.addButton(withTitle: "打开 GitHub 发布页")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "https://github.com/windycn/prism-xr/releases/latest")!)
                }
                return
            }
            alert.messageText = "Prism XR 已是最新版本"
            alert.informativeText = "当前版本 \(installed)。"
        } catch {
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = "请检查网络连接，稍后从 Prism XR 菜单重试。"
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func latestTag() async throws -> String {
        let endpoint = URL(string: "https://api.github.com/repos/windycn/prism-xr/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let release = try? JSONDecoder().decode(Release.self, from: data) {
            return release.tag_name
        }

        // The public Releases API may rate-limit shared networks.
        let page = URL(string: "https://github.com/windycn/prism-xr/releases/latest")!
        var fallback = URLRequest(url: page, timeoutInterval: 10)
        fallback.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: fallback)
        let prefix = "/windycn/prism-xr/releases/tag/"
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let url = response.url, url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix(prefix), version(url.lastPathComponent) != nil else {
            throw URLError(.badServerResponse)
        }
        return url.lastPathComponent
    }

    private static func version(_ text: String) -> [Int]? {
        let tag = text.first?.lowercased() == "v" ? text.dropFirst() : text[...]
        let components = tag.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }
        guard (2...3).contains(components.count), numbers.count == components.count,
              numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers.count == 2 ? numbers + [0] : numbers
    }
}
