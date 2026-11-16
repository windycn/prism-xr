import SwiftUI

struct ScreenPanel: View {
    let content: SampleContent
    let primary: Bool
    let liveFrame: CGImage?
    var waitingForDesktop = false
    var mirrorsMac = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.047, green: 0.074, blue: 0.14)
                if mirrorsMac {
                    VStack(spacing: 9) {
                        Image(systemName: "laptopcomputer").font(.system(size: max(20, min(48, geometry.size.height / 4))))
                        Text("Mac 内屏镜像").font(.system(size: max(10, min(18, geometry.size.height / 9)), weight: .semibold))
                        Text("与 Mac 内屏显示同一个桌面")
                            .font(.system(size: max(8, min(12, geometry.size.height / 14))))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let liveFrame {
                    Image(decorative: liveFrame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if waitingForDesktop {
                    Text("正在连接桌面…").font(.caption).foregroundStyle(.white.opacity(0.7))
                } else {
                    sampleScreen(size: geometry.size)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Palette.cyan.opacity(primary ? 0.78 : 0.35), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.55), radius: 9, x: 0, y: 10)
        .shadow(color: Palette.accent.opacity(primary ? 0.48 : 0.22), radius: 13)
    }

    private func sampleScreen(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach([Color(red: 1, green: 0.39, blue: 0.43),
                         Color(red: 1, green: 0.79, blue: 0.39), Palette.cyan], id: \.self) { color in
                    Circle().fill(color.opacity(0.82)).frame(width: 3.3, height: 3.3)
                }
                Spacer()
                if size.width > 80 {
                    Text(sampleTitle)
                        .font(.system(size: min(7, size.height * 0.086), weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                    Spacer()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: max(7, min(14, size.height * 0.16)))
            .background(.white.opacity(0.085))

            Canvas { context, size in
                switch content {
                case .browser: drawLandscape(context, size)
                case .editor: drawCode(context, size)
                case .notes: drawNotes(context, size)
                case .activity: drawActivity(context, size)
                }
            }
        }
    }

    private var sampleTitle: String {
        switch content {
        case .browser: "地平线"
        case .editor: "Editor.swift"
        case .notes: "备忘录"
        case .activity: "活动监视器"
        }
    }

    private func drawLandscape(_ context: GraphicsContext, _ size: CGSize) {
        let w = size.width
        let h = size.height
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.42),
                              Color(red: 0.44, green: 0.46, blue: 0.79),
                              Color(red: 0.96, green: 0.63, blue: 0.57)]),
            startPoint: .zero, endPoint: CGPoint(x: w * 0.22, y: h * 0.88)))
        let sun = CGRect(x: w * 0.63, y: h * 0.22, width: h * 0.26, height: h * 0.26)
        context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.86, blue: 0.67)))
        let layers: [([CGPoint], Color)] = [
            ([.init(x: 0, y: 0.61), .init(x: 0.27, y: 0.38), .init(x: 0.52, y: 0.67),
              .init(x: 0.75, y: 0.39), .init(x: 1, y: 0.62)], Color(red: 0.29, green: 0.31, blue: 0.56)),
            ([.init(x: 0, y: 0.73), .init(x: 0.21, y: 0.58), .init(x: 0.53, y: 0.79),
              .init(x: 0.79, y: 0.52), .init(x: 1, y: 0.64)], Color(red: 0.16, green: 0.21, blue: 0.43)),
            ([.init(x: 0, y: 0.76), .init(x: 0.32, y: 0.72), .init(x: 0.61, y: 0.87),
              .init(x: 0.81, y: 0.76), .init(x: 1, y: 0.78)], Color(red: 0.075, green: 0.12, blue: 0.28))
        ]
        for (points, color) in layers {
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: h))
            for point in points { shape.addLine(to: CGPoint(x: point.x * w, y: point.y * h)) }
            shape.addLine(to: CGPoint(x: w, y: h))
            shape.closeSubpath()
            context.fill(shape, with: .color(color))
        }
    }

    private func drawCode(_ context: GraphicsContext, _ size: CGSize) {
        let colors: [Color] = [.purple, Palette.cyan, .mint, .orange]
        let rowHeight = size.height / 11
        for index in 0..<10 {
            let x = CGFloat(index % 3 + 1) * size.width * 0.055
            let y = rowHeight * CGFloat(index) + rowHeight * 0.58
            let w = size.width * (0.19 + CGFloat((index * 7) % 11) * 0.028)
            let rect = CGRect(x: x, y: y, width: w, height: max(1, rowHeight * 0.21))
            context.fill(Path(roundedRect: rect, cornerRadius: 0.65),
                         with: .color(colors[index % colors.count].opacity(0.76)))
            if !index.isMultiple(of: 3) {
                let tail = rect.offsetBy(dx: w + 3, dy: 0).intersection(
                    CGRect(x: 0, y: 0, width: size.width * 0.89, height: size.height))
                if !tail.isNull {
                    context.fill(Path(roundedRect: tail, cornerRadius: 0.6), with: .color(.white.opacity(0.22)))
                }
            }
        }
    }

    private func drawActivity(_ context: GraphicsContext, _ size: CGSize) {
        let values: [CGFloat] = [0.27, 0.43, 0.34, 0.60, 0.53, 0.77, 0.64, 0.83, 0.57, 0.70]
        let unit = size.width * 0.82 / CGFloat(values.count)
        let baseline = size.height * 0.84
        for (index, value) in values.enumerated() {
            let height = size.height * 0.74 * value
            let bar = CGRect(x: size.width * 0.09 + CGFloat(index) * unit, y: baseline - height,
                             width: unit * 0.68, height: height)
            let tint = index.isMultiple(of: 3) ? Palette.cyan : Palette.accent
            context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(tint.opacity(0.8)))
        }
    }

    private func drawNotes(_ context: GraphicsContext, _ size: CGSize) {
        let rowHeight = size.height / 7
        for index in 0..<5 {
            let y = rowHeight * CGFloat(index + 1)
            let bullet = CGRect(x: size.width * 0.105, y: y, width: 2.6, height: 2.6)
            context.stroke(Path(ellipseIn: bullet), with: .color(Palette.cyan.opacity(0.8)), lineWidth: 0.6)
            let rect = CGRect(x: size.width * 0.2, y: y + 0.6,
                              width: size.width * (0.55 - CGFloat(index % 3) * 0.09), height: 1.5)
            context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(.white.opacity(0.44)))
        }
    }
}
