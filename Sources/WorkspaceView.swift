import AppKit
import SwiftUI

struct WorkspaceView: View {
    let capture: CaptureSession
    let stereo: StereoSession
    let layouts: LayoutLibrary
    let desktop: SpatialDesktop
    let tracker: RayneoTracker
    let brightness: InternalBrightness
    let roll: Double
    @Binding var yaw: Double
    @Binding var pitch: Double
    @Binding var stereoEnabled: Bool
    @State private var editorDraft: CustomLayout?
    @State private var pendingDelete: CustomLayout?
    @State private var parametersLayout: WorkspaceLayout?
    @State private var confirmPresetReset = false
    @AppStorage("lockWorkspaceHorizon") private var lockHorizon = true
    @State private var renderMetrics = SpatialRenderMetrics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: WorkspaceLayout { layouts.selection }
    private var preferences: LayoutPreferences { layouts.preferences }

    private var convertsPrimary: Bool { stereoEnabled && stereo.source == .live }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    PageHeading(title: "空间工作台", detail: desktop.isEnabled ? desktop.status :
                                    (desktop.outputAvailable ? "一块镜像 Mac 内屏，其余屏幕独立扩展。" : "眼镜未连接，可先调整布局和参数。"))
                    if desktop.isStarting { ProgressView().controlSize(.small).accessibilityLabel("正在启动空间桌面") }
                    if desktop.isEnabled {
                        Button("识别屏幕", systemImage: "number.square", action: desktop.identifyDisplays)
                            .disabled(desktop.activeCount == 0)
                        Button("鼠标移入主屏", systemImage: "cursorarrow", action: desktop.moveCursorToPrimary)
                            .disabled(desktop.activeCount == 0)
                        Button("停止空间桌面", systemImage: "stop.fill", action: desktop.stop)
                    } else {
                        Button(desktop.outputAvailable ? "开始空间桌面" : "连接眼镜后启动", systemImage: "play.fill", action: desktop.enable)
                            .buttonStyle(.borderedProminent)
                            .disabled(!desktop.outputAvailable)
                    }
                }
                if !desktop.isEnabled, !desktop.outputDisplays.isEmpty {
                    Picker("眼镜视频输出", selection: Binding(
                        get: { desktop.selectedOutputID },
                        set: { desktop.selectOutput($0) }
                    )) {
                        Text("自动识别 GT Max").tag(nil as CGDirectDisplayID?)
                        ForEach(desktop.outputDisplays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                if let error = desktop.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
                }
                if desktop.requiresCapturePermission {
                    HStack(spacing: 10) {
                        Button("打开录屏设置", systemImage: "gearshape", action: desktop.openCaptureSettings)
                        Button("在访达显示当前应用", systemImage: "folder", action: desktop.revealCurrentApplication)
                        Text("更新测试包后如仍无法采集，可移除旧条目，再添加当前应用并重开。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if desktop.isEnabled, desktop.supportsOutputTracking, preferences.mode == .lookAround {
                    HStack(spacing: 10) {
                        Image(systemName: tracker.isCalibrated ? "viewfinder" : "sensor")
                            .foregroundStyle(tracker.isCalibrated ? Color.green : Color.orange)
                        Text(tracker.isRunning ? (tracker.isCalibrated ? (tracker.isStationary ? "静止锁定 · 视角保持" : "软件空间追踪 · 重力校正已启用") : tracker.status) :
                             (tracker.usesDeviceTracking ? "机身模式已接管 · 软件追踪已暂停" : "头部追踪已暂停，当前视角固定"))
                            .font(.subheadline)
                        if tracker.isCalibrated {
                            Text("左右 \(Int(tracker.pose.yaw))° · 上下 \(Int(tracker.pose.pitch))°")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tracker.isRunning ? "视角回正" : "恢复转头查看") {
                            if tracker.isRunning { tracker.recenter() } else { tracker.start() }
                        }
                        .controlSize(.small)
                        if tracker.isRunning {
                            Button("静止校准", systemImage: "viewfinder", action: tracker.recalibrate)
                                .controlSize(.small)
                                .help("保持静止约一秒，重新估计零偏和水平线")
                        }
                    }
                    .padding(10)
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 10))
                    if let error = tracker.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 18) {
                        WorkspaceStage(layout: layout, preferences: preferences, desktop: desktop, liveFrame: nil,
                                       mode: setting(\.mode), field: setting(\.field), yaw: $yaw, pitch: $pitch, roll: roll)
                            .frame(height: 324)
                        layoutSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    inspector
                        .frame(width: 224)
                        .frame(minHeight: 324, alignment: .top)
                }
            }
            .frame(maxWidth: 1140)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: layout.id)
        .task {
            while !Task.isCancelled {
                renderMetrics = desktop.frameStore.readMetrics()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: layout.id) { resetViewpoint() }
        .sheet(item: $parametersLayout) { layout in
            LayoutParameters(layout: layout, library: layouts)
        }
        .alert("还原九个预设？", isPresented: $confirmPresetReset) {
            Button("还原预设", role: .destructive) {
                layouts.resetPresets()
                resetViewpoint()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("九个内置布局的分辨率、HiDPI、刷新率和观看方式将恢复初始值。自定义布局会保留。")
        }
        .sheet(item: $editorDraft) { draft in
            LayoutEditor(library: layouts, draft: draft)
        }
        .alert("删除自定义布局？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { layout in
            Button("删除", role: .destructive) { layouts.delete(layout.id) }
            Button("取消", role: .cancel) {}
        } message: { layout in
            Text("「\(layout.displayName)」将从你的自定义布局中移除。")
        }
    }

    private func setting<Value>(_ path: WritableKeyPath<LayoutPreferences, Value>) -> Binding<Value> {
        let selected = layout
        return Binding {
            layouts.preferences(for: selected)[keyPath: path]
        } set: { value in
            layouts.updatePreferences(for: selected) { $0[keyPath: path] = value }
        }
    }

    private func resetViewpoint() {
        if tracker.isRunning && preferences.mode == .lookAround { tracker.recenter() }
        yaw = 0
        pitch = 0
    }

    private var layoutGrid: some View {
        let options = Array(ScreenLayout.allCases.enumerated())
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 9) {
            ForEach(options, id: \.element.id) { index, option in
                layoutCard(.preset(option))
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("屏幕布局").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("自定义布局", systemImage: "plus") { editorDraft = layouts.newDraft() }
                    .controlSize(.small)
                Button("还原预设", systemImage: "arrow.counterclockwise") { confirmPresetReset = true }
                    .controlSize(.small)
                    .help("还原九个内置布局")
            }
            if !layouts.customLayouts.isEmpty { customLayouts }
            layoutGrid
            Text("⌘1–9 切换预设")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var customLayouts: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(layouts.customLayouts) { saved in
                HStack(spacing: 6) {
                    layoutCard(.custom(saved))
                    Menu {
                        Button("布局参数…", systemImage: "gearshape") { parametersLayout = .custom(saved) }
                        Button("编辑布局…", systemImage: "pencil") { editorDraft = saved }
                        Button("删除布局…", systemImage: "trash", role: .destructive) { pendingDelete = saved }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("管理\(saved.displayName)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("自定义布局")
    }

    private func setStereo(_ enabled: Bool) {
        stereoEnabled = enabled
        if enabled {
            stereo.setSource(.live)
            stereo.retryLive()
        } else if stereo.source == .live {
            stereo.setSource(.pattern)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("预览设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("布局参数", systemImage: "gearshape") { parametersLayout = layout }
                    .controlSize(.small)
                    .help("目标分辨率与 HiDPI")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("桌面组成").font(.subheadline.weight(.medium))
                Label(desktop.isEnabled ? desktop.status : "1 块 Mac 内屏镜像 + \(max(0, layout.panels.count - 1)) 块独立副屏",
                      systemImage: "display.2")
                    .font(.caption).foregroundStyle(.secondary)
                Text("镜像屏与 Mac 内屏显示同一个桌面。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("内屏镜像放在哪块屏幕").font(.subheadline.weight(.medium))
                Picker("内屏镜像放在哪块屏幕", selection: Binding(
                    get: {
                        return preferences.mirrorScreenID ?? "primary"
                    },
                    set: { selected in
                        layouts.updatePreferences(for: layout) {
                            $0.mirrorScreenID = selected == "primary" ? nil : selected
                        }
                    })) {
                    Text("主屏（默认）").tag("primary")
                    ForEach(layout.configurableScreens) { screen in Text(screen.name).tag(screen.id) }
                }
                .labelsHidden()
                Text("Mac 内屏保持原桌面，其余工作屏独立扩展。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Button("清晰优先", systemImage: "textformat.size.larger") {
                layouts.updatePreferences(for: layout) { value in
                    for screen in layout.configurableScreens {
                        let aspect = CGFloat(screen.target.width) / CGFloat(screen.target.height)
                        value.targets[screen.id] = ScreenTarget.suggested(aspect: aspect, shortEdge: min(900, Int(4320 * aspect)), hiDPI: true)
                    }
                }
            }
            .help("独立桌面采用较大文字与 2× HiDPI；Mac 镜像沿用本机显示分辨率")
            VStack(alignment: .leading, spacing: 6) {
                Text("虚拟桌面刷新率").font(.subheadline.weight(.medium))
                Picker("虚拟桌面刷新率", selection: setting(\.refresh)) {
                    ForEach(RefreshRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(desktop.isEnabled ? "桌面采集最高 60 fps，转头由独立渲染驱动。" : "启动空间桌面时应用到虚拟显示器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if desktop.isEnabled {
                    Text("Metal \(Int(renderMetrics.fps.rounded())) fps · \(renderMetrics.width) × \(renderMetrics.height)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let error = renderMetrics.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }

            if desktop.activeCount > 0 {
                Divider()
                Button(brightness.isDimmed ? "恢复内屏亮度" : "内屏亮度降至最低",
                       systemImage: brightness.isDimmed ? "sun.max" : "sun.min") {
                    if brightness.isDimmed { brightness.restore() }
                    else if let id = desktop.glassesDisplayID { brightness.dim(output: id) }
                }
                .disabled(brightness.isChanging)
                Text("关闭此功能、停止桌面、拔掉眼镜或退出时恢复原亮度。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = brightness.error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("观看方式").font(.subheadline.weight(.medium))
                Picker("观看方式", selection: Binding(
                    get: { preferences.mode },
                    set: { mode in
                        setting(\.mode).wrappedValue = mode
                        resetViewpoint()
                    }
                )) {
                    ForEach(WorkspaceViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if preferences.mode == .lookAround {
                    Toggle("锁定水平线", isOn: $lockHorizon)
                        .font(.subheadline)
                    HStack {
                        Text("视野大小").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(preferences.field.rounded()))°")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: setting(\.field), in: WorkspaceViewMode.fieldRange) { Text("视野大小") }
                        .labelsHidden()
                        .accessibilityValue("\(Int(preferences.field.rounded()))°")
                } else {
                    Text("让所有屏幕同时可见。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.08))
        }
    }

    private func layoutCard(_ option: WorkspaceLayout) -> some View {
        let selected = layout.id == option.id
        return Button {
            layouts.select(option)
        } label: {
            HStack(spacing: 10) {
                LayoutThumbnail(layout: option)
                    .frame(width: 69, height: 43)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.name).font(.subheadline.weight(.semibold))
                    Text(option.detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(7)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.accent.opacity(0.095) : Color.primary.opacity(0.032),
                        in: .rect(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? Palette.accent.opacity(0.72) : .primary.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(option.name) · \(option.detail)")
    }
}

struct LayoutThumbnail: View {
    let layout: WorkspaceLayout

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width * 0.94, size.height * layout.drawingAspect)
            for panel in layout.panels {
                let w = unit * panel.width
                let h = unit * panel.height
                let rect = CGRect(x: size.width / 2 + unit * panel.x - w / 2,
                                  y: size.height / 2 + unit * panel.y - h / 2,
                                  width: w, height: h)
                let outline = Path(roundedRect: rect, cornerRadius: 2.1)
                let colors = panel.primary
                    ? [Palette.cyan, Palette.accent]
                    : [Color(red: 0.24, green: 0.46, blue: 0.84), Color(red: 0.10, green: 0.21, blue: 0.51)]
                context.fill(outline, with: .linearGradient(Gradient(colors: colors),
                                                           startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                context.stroke(outline, with: .color(.white.opacity(panel.primary ? 0.58 : 0.23)), lineWidth: 0.6)
                if layout.isContinuousCanvas {
                    let guides = Path { path in
                        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                    }
                    context.stroke(guides, with: .color(.white.opacity(0.68)), lineWidth: 0.55)
                }
            }
        }
        .background(
            .linearGradient(colors: [Palette.stage, Palette.night], startPoint: .top, endPoint: .bottom),
            in: .rect(cornerRadius: 7)
        )
        .accessibilityHidden(true)
    }
}

struct WorkspaceStage: View {
    let layout: WorkspaceLayout
    let preferences: LayoutPreferences
    let desktop: SpatialDesktop
    let liveFrame: CGImage?
    @Binding var mode: WorkspaceViewMode
    @Binding var field: Double
    @Binding var yaw: Double
    @Binding var pitch: Double
    let roll: Double
    @GestureState private var drag: CGSize = .zero

    private var effectiveYaw: Double { min(40, max(-40, (mode == .overview ? 0 : yaw) + drag.width / 5)) }
    private var effectivePitch: Double { min(26, max(-26, (mode == .overview ? 0 : pitch) + drag.height / 5)) }
    private var visibleMode: WorkspaceViewMode { drag == .zero ? mode : .lookAround }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                StageBackdrop()
                ScenePanels(layout: layout, preferences: preferences, primaryFrame: liveFrame,
                            desktopFrames: desktop.frames, isDesktopActive: desktop.isEnabled, mode: visibleMode, field: field,
                            yaw: effectiveYaw, pitch: effectivePitch, roll: roll, size: geometry.size)
                    .accessibilityHidden(true)
                VStack {
                    HStack {
                        Label(desktop.isEnabled ? "独立空间桌面" : (liveFrame == nil ? "模拟预览" : "实时桌面预览"),
                              systemImage: liveFrame == nil ? "cube" : "record.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.33), in: .capsule)
                            .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
                        Spacer()
                        Text(layout.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.73))
                    }
                    Spacer()
                    HStack {
                        Label("拖动模拟转头 · 滚轮调视野", systemImage: "hand.draw")
                        Spacer()
                        Text(visibleMode == .overview ? "一览" :
                             "\(Int(field.rounded()))°  ·  偏航 \(Int(effectiveYaw.rounded()))°  俯仰 \(Int(effectivePitch.rounded()))°")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                }
                .padding(15)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    yaw = min(40, max(-40, (mode == .overview ? 0 : yaw) + value.translation.width / 5))
                    pitch = min(26, max(-26, (mode == .overview ? 0 : pitch) + value.translation.height / 5))
                    mode = .lookAround
                })
        }
        .background { PreviewScrollWheel(onScroll: adjustField) }
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.11)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(layout.name)工作区预览")
        .accessibilityValue(desktop.isEnabled ? desktop.status : (liveFrame == nil ? "模拟画面" : "实时桌面采集"))
    }

    private func adjustField(delta: Double) -> Bool {
        let range = WorkspaceViewMode.fieldRange
        if mode == .overview {
            guard delta > 0 else { return false }
            yaw = 0
            pitch = 0
            field = WorkspaceViewMode.defaultField
            mode = .lookAround
        }
        field = min(range.upperBound, max(range.lowerBound, field - delta))
        return true
    }
}

struct StageBackdrop: View {
    var body: some View {
        ZStack {
            Palette.night
            RadialGradient(colors: [Color(red: 0.14, green: 0.24, blue: 0.48), Palette.stage, Palette.night],
                           center: .init(x: 0.50, y: 0.47), startRadius: 1, endRadius: 360)
            Canvas { context, size in
                let horizon = size.height * 0.63
                var grid = Path()
                for index in -10...10 {
                    grid.move(to: CGPoint(x: size.width / 2 + CGFloat(index) * size.width / 32, y: horizon))
                    grid.addLine(to: CGPoint(x: size.width / 2 + CGFloat(index) * size.width / 8,
                                             y: size.height + 9))
                }
                for index in 1...9 {
                    let step = CGFloat(index) / 9
                    let y = horizon + (size.height - horizon) * step * step
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .linearGradient(
                    Gradient(colors: [Palette.cyan.opacity(0.015), Palette.accent.opacity(0.28)]),
                    startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)),
                    lineWidth: 0.55)
                for index in 0..<67 {
                    let x = size.width * CGFloat((index * 41 + 13) % 101) / 101
                    let y = horizon * CGFloat((index * 53 + 3) % 103) / 103
                    let alpha = index.isMultiple(of: 5) ? 0.36 : 0.15
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.15, height: 1.15)),
                                 with: .color(Palette.cyan.opacity(alpha)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ScenePanels: View {
    let layout: WorkspaceLayout
    let preferences: LayoutPreferences
    let primaryFrame: CGImage?
    let desktopFrames: [Int: CGImage]
    let isDesktopActive: Bool
    let mode: WorkspaceViewMode
    let field: Double
    let yaw: Double
    let pitch: Double
    let roll: Double
    let size: CGSize
    var eyeOffset: CGFloat = 0

    var body: some View {
        let panels = layout.panels(using: preferences)
        let width = max(1, size.width - 24)
        let height = max(1, size.height - 46)
        let halfWidth = panels.map { abs($0.x) + $0.width / 2 }.max() ?? 0.5
        let halfHeight = panels.map { abs($0.y) + $0.height / 2 }.max() ?? 0.5
        let fit = min(width, (size.height - 34) * layout.drawingAspect,
                      width / (2 * halfWidth), height / (2 * halfHeight))
        let primary = panels.first(where: \.primary)
        let unit = viewUnit(fit: fit, width: width, height: height, primary: primary)
        let center = centerPoint(for: panels, primary: primary)
        let rotationYaw = mode == .overview ? 0 : yaw
        let rotationPitch = mode == .overview ? 0 : pitch
        ZStack {
            ForEach(panels) { panel in
                ScreenPanel(content: panel.content, primary: panel.primary,
                            liveFrame: desktopFrames[panel.id] ?? (panel.primary ? primaryFrame : nil),
                            waitingForDesktop: isDesktopActive && desktopFrames[panel.id] == nil,
                            mirrorsMac: isDesktopActive && layout.mirroredPanelID(using: preferences) == panel.id)
                    .frame(width: unit * panel.width, height: unit * panel.height)
                    .overlay(alignment: .bottomLeading) {
                        if isDesktopActive {
                            Text((layout.configurableScreens.first(where: { $0.panel.id == panel.id })?.name ?? "屏幕") +
                                 (layout.mirroredPanelID(using: preferences) == panel.id ? " · Mac 内屏镜像" : " · 独立副屏"))
                                .font(.system(size: max(10, min(16, size.width / 100)), weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.65), in: .capsule)
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                    }
                    .rotation3DEffect(.degrees(panel.turn - rotationYaw * 0.24), axis: (0, 1, 0),
                                      perspective: 0.35)
                    .rotation3DEffect(.degrees(panel.tilt + rotationPitch * 0.2), axis: (1, 0, 0),
                                      perspective: 0.32)
                    .position(x: size.width / 2 + unit * (panel.x - center.x) +
                              eyeOffset * size.width * (panel.primary ? 0.0035 : 0.001),
                              y: size.height * 0.49 + unit * (panel.y - center.y))
            }
        }
        .rotationEffect(.degrees(mode == .lookAround ? -roll : 0))
    }

    private func viewUnit(fit: CGFloat, width: CGFloat, height: CGFloat, primary: ScreenLayout.Panel?) -> CGFloat {
        guard mode == .lookAround else { return max(1, fit) }
        let zoom = mode.zoom(field: field)
        if !layout.centersOnCanvas, let primary {
            let primaryFit = min(width / primary.width, height / primary.height) * 0.96
            return max(1, max(fit, primaryFit) * zoom)
        }
        return max(1, fit * zoom)
    }

    private func centerPoint(for panels: [ScreenLayout.Panel], primary: ScreenLayout.Panel?) -> CGPoint {
        guard mode == .lookAround else { return .zero }
        let origin = layout.centersOnCanvas ? CGPoint.zero : CGPoint(x: primary?.x ?? 0, y: primary?.y ?? 0)
        let xTarget = yaw >= 0 ? panels.map(\.x).max() : panels.map(\.x).min()
        let yTarget = pitch >= 0 ? panels.map(\.y).max() : panels.map(\.y).min()
        return CGPoint(x: origin.x + ((xTarget ?? origin.x) - origin.x) * abs(yaw) / 40,
                       y: origin.y + ((yTarget ?? origin.y) - origin.y) * abs(pitch) / 26)
    }
}

private struct PreviewScrollWheel: NSViewRepresentable {
    let onScroll: (Double) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        var onScroll: ((Double) -> Bool)?
        private var monitor: Any?

        func install(on view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let view, let window = view.window, event.window === window,
                      !view.isHiddenOrHasHiddenAncestor, !event.modifierFlags.contains(.shift),
                      event.momentumPhase.isEmpty,
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                let multiplier = event.hasPreciseScrollingDeltas ? 0.16 : 3.0
                let delta = min(8, max(-8, Double(event.scrollingDeltaY) * multiplier))
                return self?.onScroll?(delta) == true ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct WorkspaceStereoOutput: View {
    let capture: CaptureSession
    let desktop: SpatialDesktop
    let stereo: StereoSession
    let layout: WorkspaceLayout
    let preferences: LayoutPreferences
    let yaw: Double
    let pitch: Double
    let roll: Double
    let convertsPrimary: Bool
    let swapEyes: Bool


    var body: some View {
        HStack(spacing: 0) {
            eye(left: !swapEyes)
            eye(left: swapEyes)
        }
        .aspectRatio(32.0 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("工作区左右眼画面")
    }

    private func eye(left: Bool) -> some View {
        let pair = convertsPrimary && stereo.source == .live ? stereo.pair : nil
        let primary = (left ? pair?.left : pair?.right) ?? capture.frame
        return GeometryReader { geometry in
            ZStack {
                StageBackdrop()
                ScenePanels(layout: layout, preferences: preferences, primaryFrame: primary,
                            desktopFrames: desktop.frames, isDesktopActive: desktop.isEnabled,
                            mode: preferences.mode, field: preferences.field,
                            yaw: yaw, pitch: pitch, roll: roll, size: geometry.size, eyeOffset: left ? 1 : -1)
            }
        }
        .clipped()
    }
}


struct WorkspaceFlatOutput: View {
    let layouts: LayoutLibrary
    let desktop: SpatialDesktop
    let tracker: RayneoTracker

    var body: some View {
        GeometryReader { geometry in
            ScenePanels(layout: layouts.selection, preferences: layouts.preferences, primaryFrame: nil,
                        desktopFrames: desktop.frames, isDesktopActive: desktop.isEnabled,
                        mode: layouts.preferences.mode, field: layouts.preferences.field,
                        yaw: min(40, max(-40, tracker.pose.yaw)),
                        pitch: min(26, max(-26, tracker.pose.pitch)), roll: tracker.pose.roll, size: geometry.size)
        }
        .background(.black)
        .clipped()
    }
}
