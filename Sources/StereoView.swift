import SwiftUI
import UniformTypeIdentifiers

struct StereoView: View {
    let session: StereoSession
    let capture: CaptureSession
    @AppStorage("stereoDisparity") private var disparity = 12.0
    @AppStorage("stereoSwapEyes") private var swapEyes = false
    @Environment(\.openWindow) private var openWindow
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeading(title: "立体显示", detail: "检查左右眼、调节视差，或在 Mac 上将 2D 内容转为 SBS。")
                    Button("SBS 输出", systemImage: "rectangle.split.2x1") {
                        openWindow(id: "stereo-output")
                    }
                    .disabled(session.source != .pattern && session.pair == nil)
                    .help("打开独立的左右眼输出窗口")
                }

                sourceSelector
                previewCard
                calibration
                if let error = importError ?? session.error ?? (session.source == .live ? capture.error : nil) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Label("将 SBS 输出窗口拖到眼镜显示器，再进入全屏。", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                importError = nil
                session.importImage(url, disparity: disparity)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var sourceSelector: some View {
        HStack(spacing: 4) {
            ForEach(StereoSession.Source.allCases) { source in
                let selected = session.source == source
                Button {
                    changeSource(source)
                } label: {
                    Label(source.rawValue, systemImage: source.symbol)
                        .font(.system(size: 15, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Palette.accent : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(selected ? Palette.accent.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 11))
                        .contentShape(.rect(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.08)) }
        .frame(maxWidth: 546)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画面来源")
    }

    private var previewCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Palette.night
                if session.source == .pattern || session.pair != nil {
                    StereoSurface(source: session.source, pair: session.pair,
                                  disparity: disparity, swapEyes: swapEyes)
                        .padding(13)
                } else if session.isProcessing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成左右眼画面").font(.subheadline)
                    }
                    .foregroundStyle(.white)
                    .colorScheme(.dark)
                } else {
                    VStack(spacing: 11) {
                        Image(systemName: session.source.symbol)
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Palette.cyan)
                        Text(session.source == .image ? "从图片生成双眼画面" : "从屏幕或窗口生成双眼画面")
                            .font(.headline)
                        sourceAction
                            .buttonStyle(.borderedProminent)
                    }
                    .foregroundStyle(.white)
                    .colorScheme(.dark)
                }
            }
            .frame(height: 267)

            HStack(spacing: 10) {
                Label("Full SBS · 32:9", systemImage: "rectangle.split.2x1")
                    .font(.subheadline.weight(.medium))
                if let name = session.imageName, session.source == .image {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let latency = session.latency, session.source != .pattern {
                    let milliseconds = Double(latency.components.seconds) * 1000 +
                        Double(latency.components.attoseconds) / 1.0e15
                    Text("最近一帧 \(milliseconds, format: .number.precision(.fractionLength(0))) ms")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if session.pair != nil, session.source != .pattern { sourceAction }
                if session.source == .live, capture.isCapturing {
                    Button("停止采集", systemImage: "stop.fill") { capture.stop() }
                        .labelStyle(.iconOnly)
                        .help("停止采集")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(.primary.opacity(0.035))
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.09)) }
    }

    @ViewBuilder
    private var sourceAction: some View {
        if session.source == .image {
            Button("选取图片…", systemImage: "photo.on.rectangle") { showImporter = true }
        } else if session.source == .live {
            Button(capture.isCapturing ? "更换来源" : "选取屏幕或窗口",
                   systemImage: "rectangle.inset.filled", action: capture.chooseSource)
                .disabled(capture.isChoosing)
        }
    }

    private var calibration: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("立体视差", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(disparity, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $disparity, in: 0...36, step: 1, onEditingChanged: { editing in
                    if !editing, session.source == .image { session.refreshImage(disparity: disparity) }
                }) { Text("视差") }
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("交换左右眼", isOn: $swapEyes)
                    .toggleStyle(.switch)
                    .font(.subheadline.weight(.semibold))
                Text(swapEyes ? "输出顺序  右眼 → 左眼" : "输出顺序  左眼 → 右眼")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(15)
        .frame(height: 89)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14))
    }

    private func changeSource(_ source: StereoSession.Source) {
        importError = nil
        session.setSource(source)
        if source == .image { session.refreshImage(disparity: disparity) }
    }
}

private extension StereoSession.Source {
    var symbol: String {
        switch self {
        case .pattern: "viewfinder"
        case .image: "photo"
        case .live: "macwindow"
        }
    }
}

struct StereoSurface: View {
    let source: StereoSession.Source
    let pair: StereoPair?
    let disparity: Double
    let swapEyes: Bool

    var body: some View {
        if source == .pattern {
            StereoPattern(disparity: disparity, swapEyes: swapEyes)
        } else if let pair {
            let images = swapEyes ? [pair.right, pair.left] : [pair.left, pair.right]
            HStack(spacing: 0) {
                ForEach(0..<2) { index in
                    Image(decorative: images[index], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(32.0 / 9, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Full SBS 左右眼画面")
        } else {
            Text("等待左右眼画面").foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StereoPattern: View {
    let disparity: Double
    let swapEyes: Bool

    var body: some View {
        HStack(spacing: 0) {
            eye(left: !swapEyes)
            eye(left: swapEyes)
        }
        .aspectRatio(32.0 / 9, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(swapEyes ? "右眼与左眼测试图，已交换顺序" : "左眼与右眼测试图")
    }

    private func eye(left: Bool) -> some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let color: Color = left ? Palette.cyan : Color(red: 0.75, green: 0.61, blue: 1)
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(
                Gradient(colors: [Palette.stage, Palette.night]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: h)))
            var grid = Path()
            for index in 1..<10 {
                let x = w * CGFloat(index) / 10
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: h))
            }
            for index in 1..<6 {
                let y = h * CGFloat(index) / 6
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.6)
            context.stroke(Path(bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.45)))
            let radius = h * 0.237
            let center = CGPoint(x: w / 2 + (left ? 1 : -1) * w * disparity / 1200, y: h / 2)
            let ring = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: 2)
            context.stroke(Path(ellipseIn: ring.insetBy(dx: radius * 0.17, dy: radius * 0.17)),
                           with: .color(color.opacity(0.28)), lineWidth: 1)
            let cross = Path { path in
                path.move(to: CGPoint(x: center.x - radius * 0.26, y: center.y))
                path.addLine(to: CGPoint(x: center.x + radius * 0.26, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - radius * 0.26))
                path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 0.26))
            }
            context.stroke(cross, with: .color(color), lineWidth: 1.5)
            context.draw(Text(left ? "L  左眼" : "R  右眼")
                .font(.system(size: max(9, h * 0.085), weight: .semibold, design: .monospaced))
                .foregroundStyle(color), at: CGPoint(x: w * 0.065, y: h * 0.13), anchor: .leading)
        }
    }
}
