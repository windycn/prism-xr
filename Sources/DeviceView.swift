import AppKit
import CoreGraphics
import IOKit
import SwiftUI

private struct DisplayModeInfo: Hashable {
    let logicalSize: String
    let renderSize: String
    let refresh: String

    init(_ mode: CGDisplayMode) {
        logicalSize = "\(mode.width) × \(mode.height) pt"
        renderSize = "\(mode.pixelWidth) × \(mode.pixelHeight) px"
        refresh = mode.refreshRate > 0
            ? "\(mode.refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Hz"
            : "未知"
    }

    var summary: String { "\(logicalSize) → \(renderSize) · \(refresh)" }
}

private struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let selectedOutput: Bool
    let builtIn: Bool
    let mirrored: Bool
    let workspaceSize: String
    let backingScale: String
    let activeMode: DisplayModeInfo?
    let modes: [DisplayModeInfo]

    var isGlassesOutput: Bool { selectedOutput || CGDisplayVendorNumber(id) == 20588 && CGDisplayModelNumber(id) == 980 }
    var isWorkspaceSource: Bool { builtIn || CGDisplayVendorNumber(id) == 0x5052 }
    var role: String {
        if isGlassesOutput { return "眼镜输出 · 不计入工作屏" }
        if builtIn { return "Mac 内屏 · 镜像来源" }
        if CGDisplayVendorNumber(id) == 0x5052 { return "独立副屏" }
        return mirrored ? "外接 · 镜像" : "外接 · 扩展"
    }
}

struct DeviceView: View {
    let tracker: RayneoTracker
    let desktop: SpatialDesktop
    @State private var displays: [DisplayInfo] = []
    @State private var matchingUSB = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack(alignment: .center, spacing: 12) {
                    PageHeading(title: "显示设备", detail: "查看眼镜识别状态和本机显示器的实际模式。")
                    Button("重新扫描", systemImage: "arrow.clockwise", action: refresh)
                    Button(copied ? "已复制" : "复制诊断", systemImage: copied ? "checkmark" : "doc.on.doc",
                           action: copyReport)
                }

                HStack(spacing: 12) {
                    summaryCard(title: "RayNeo GT Max", value: matchingUSB ? "发现 USB 标识" : "未发现 USB 标识",
                                detail: "USB 3941:AF50", symbol: "eyeglasses",
                                tint: matchingUSB ? .green : .orange)
                    summaryCard(title: "桌面来源", value: "\(displays.filter(\.isWorkspaceSource).count) 块",
                                detail: "Mac 内屏和独立副屏；眼镜输出另列",
                                symbol: "display.2", tint: Palette.accent)
                    summaryCard(title: "主显示器 HiDPI", value: displays.first?.backingScale ?? "未知",
                                detail: displays.first?.workspaceSize ?? "系统未返回显示器",
                                symbol: "square.on.square", tint: .teal)
                }

                HStack(alignment: .top, spacing: 12) {
                    glassesModeCard
                        .frame(width: 266)
                    trackingCard
                        .frame(maxWidth: .infinity)
                }

                Text("显示器详情").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if displays.isEmpty {
                    ContentUnavailableView("未发现显示器", systemImage: "display")
                }
                ForEach(displays) { display in
                    displayCard(display)
                }

                Label("眼镜视频输出不计入工作屏数量。",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in refresh()
        }
    }

    private var glassesModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("机身显示模式", systemImage: "visionpro")
                .font(.headline)
            ForEach(RayneoViewingMode.allCases) { mode in
                Button {
                    tracker.switchMode(mode)
                } label: {
                    HStack {
                        Label(mode.label, systemImage: mode.symbol)
                        Spacer()
                        if tracker.requestedMode == mode {
                            Text("上次请求").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(!matchingUSB || (desktop.isEnabled && !desktop.supportsOutputTracking) || tracker.modeChangePending)
            }
            Text(tracker.modeStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("切换机身模式会退出软件追踪；切换布局不会重新接管。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 15))
    }

    private var trackingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("头部追踪", systemImage: "move.3d")
                    .font(.headline)
                Spacer()
                if tracker.isRunning {
                    Button("静止校准", systemImage: "scope", action: tracker.recalibrate)
                    Button("停止", systemImage: "stop.fill", action: tracker.stop)
                } else {
                    Button("启用头部追踪", systemImage: "play.fill", action: tracker.start)
                        .disabled(!matchingUSB || (desktop.isEnabled && !desktop.supportsOutputTracking) || tracker.modeChangePending)
                }
            }
            Text(tracker.status)
                .font(.subheadline)
                .foregroundStyle(tracker.isCalibrated ? Color.green : Color.secondary)
            if tracker.isRunning {
                HStack(spacing: 8) {
                    metric("偏航", value: "\(tracker.pose.yaw.formatted(.number.precision(.fractionLength(1))))°", symbol: "arrow.left.and.right")
                    metric("俯仰", value: "\(tracker.pose.pitch.formatted(.number.precision(.fractionLength(1))))°", symbol: "arrow.up.and.down")
                    metric("侧倾", value: "\(tracker.pose.roll.formatted(.number.precision(.fractionLength(1))))°", symbol: "arrow.trianglehead.2.clockwise.rotate.90")
                    metric("IMU 采样", value: "\(tracker.reportRate.formatted(.number.precision(.fractionLength(1)))) Hz", symbol: "waveform.path")
                }
                HStack {
                    Text("已读 \(tracker.reportCount) 帧")
                    if let board = tracker.board { Text(String(format: "板卡 0x%02X", board)) }
                    Text("\(tracker.temperature.formatted(.number.precision(.fractionLength(1)))) °C")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("启用后眼镜切为随头模式，由 Mac 控制视角。校准时请平视前方并保持静止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = tracker.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(15)
        .background(Palette.accent.opacity(0.045), in: .rect(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.accent.opacity(0.17)) }
    }

    private func summaryCard(title: String, value: String, detail: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.70)
            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.075), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.15)) }
        .accessibilityElement(children: .combine)
    }

    private func displayCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(display.name, systemImage: display.isGlassesOutput ? "visionpro" : (display.builtIn ? "laptopcomputer" : "display"))
                    .font(.headline)
                Spacer()
                Text(display.role)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.primary.opacity(0.06), in: .capsule)
            }
            HStack(spacing: 8) {
                metric("逻辑工作区", value: display.workspaceSize, symbol: "rectangle.inset.filled")
                metric("渲染像素", value: display.activeMode?.renderSize ?? "未知", symbol: "square.grid.3x3")
                metric("HiDPI 倍率", value: display.backingScale, symbol: "square.on.square")
                metric("刷新率", value: display.activeMode?.refresh ?? "未知", symbol: "waveform")
            }
            if !display.modes.isEmpty {
                Divider()
                DisclosureGroup("可用模式（\(display.modes.count)）") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            Text("逻辑尺寸")
                            Text("渲染像素")
                            Text("刷新率")
                        }
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(display.modes, id: \.self) { mode in
                            GridRow {
                                Text(mode.logicalSize)
                                Text(mode.renderSize)
                                Text(mode.refresh)
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                }
                .font(.subheadline)
            }
        }
        .padding(15)
        .background(.background, in: .rect(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.10)) }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.72)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.038), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        copied = false
        matchingUSB = Self.hasGTUSBIdentifier()
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { displays = []; return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { displays = []; return }
        displays = ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let active = CGDisplayCopyDisplayMode(id)
            let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            let labels = Set(modes.map(DisplayModeInfo.init)).sorted {
                $0.summary.localizedStandardCompare($1.summary) == .orderedAscending
            }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let mirrored = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            let isRayneoDisplay = CGDisplayVendorNumber(id) == 20588 && CGDisplayModelNumber(id) == 980
            let name = screen?.localizedName ?? (isRayneoDisplay ? "SmartGlasses" : "外接显示器 \(id)")
            let size = screen?.frame.size ?? CGSize(width: active?.width ?? 0, height: active?.height ?? 0)
            let workspace = "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
            let factor = screen?.backingScaleFactor ??
                (active.map { CGFloat($0.pixelWidth) / CGFloat(max(1, $0.width)) } ?? 1)
            let scale = Double(factor).formatted(.number.precision(.fractionLength(0...2)))
            return DisplayInfo(id: id, name: name, selectedOutput: id == (desktop.glassesDisplayID ?? desktop.selectedOutputID), builtIn: builtIn, mirrored: mirrored,
                               workspaceSize: workspace, backingScale: "\(scale)×",
                               activeMode: active.map(DisplayModeInfo.init), modes: labels)
        }
    }

    private func copyReport() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let report = ["Prism XR · \(system)", "GT Max USB 3941:AF50：\(matchingUSB ? "发现" : "未发现")"] +
            displays.map { "\($0.name) | 逻辑工作区 \($0.workspaceSize) | 渲染缩放 \($0.backingScale) | \($0.activeMode?.summary ?? "未知")\n  \($0.modes.map(\.summary).joined(separator: ", "))" }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(report.joined(separator: "\n"), forType: .string)
    }

    private static func hasGTUSBIdentifier() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
                == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let vendor = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            let product = IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            if vendor?.intValue == 0x3941, product?.intValue == 0xAF50 { return true }
        }
        return false
    }
}
