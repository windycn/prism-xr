import SwiftUI

enum ScreenLayout: String, CaseIterable, Identifiable, Codable {
    case single, dual, triple, stacked, wide, portrait
    case tiled = "surround"
    case seamless, commandCenter

    var id: Self { self }

    var name: String {
        switch self {
        case .single: "单屏"
        case .dual: "并排双屏"
        case .triple: "并排三屏"
        case .stacked: "垂直三屏"
        case .wide: "超宽屏"
        case .portrait: "一主两副"
        case .tiled: "田字四屏"
        case .seamless: "巨幕大屏"
        case .commandCenter: "一主三副"
        }
    }

    var detail: String {
        switch self {
        case .single: "16:9"
        case .dual: "2 × 16:9"
        case .triple, .stacked: "3 × 16:9"
        case .wide: "32:9"
        case .portrait: "9:16 · 16:9 · 9:16"
        case .tiled: "2 × 2 · 分屏"
        case .seamless: "2 × 2 · 连续画布"
        case .commandCenter: "主屏 + 三块工具屏"
        }
    }

    struct Panel: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let turn: Double
        let tilt: Double
        let content: SampleContent
        let primary: Bool

        init(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
             turn: Double = 0, tilt: Double = 0, content: SampleContent = .browser,
             primary: Bool = false) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.turn = turn
            self.tilt = tilt
            self.content = content
            self.primary = primary
        }
    }

    var panels: [Panel] {
        switch self {
        case .single:
            [Panel(0, 0, 0, 0.61, 0.343, primary: true)]
        case .dual:
            [Panel(0, -0.235, 0, 0.43, 0.242, turn: -10, primary: true),
             Panel(1, 0.235, 0, 0.43, 0.242, turn: 10, content: .editor)]
        case .triple:
            [Panel(1, -0.31, 0, 0.295, 0.1659375, content: .editor),
             Panel(2, 0.31, 0, 0.295, 0.1659375, content: .notes),
             Panel(0, 0, 0, 0.295, 0.1659375, primary: true)]
        case .stacked:
            [Panel(1, 0, -0.1535, 0.249, 0.1400625, content: .editor),
             Panel(2, 0, 0.1535, 0.249, 0.1400625, content: .notes),
             Panel(0, 0, 0, 0.249, 0.1400625, primary: true)]
        case .wide:
            [Panel(0, 0, 0, 0.85, 0.239, primary: true)]
        case .portrait:
            [Panel(1, -0.325, 0, 0.144, 0.256, turn: -15, content: .editor),
             Panel(2, 0.325, 0, 0.144, 0.256, turn: 15, content: .notes),
             Panel(0, 0, 0, 0.474, 0.267, primary: true)]
        case .tiled:
            [Panel(0, -0.203, -0.115, 0.375, 0.2109375, primary: true),
             Panel(1, 0.203, -0.115, 0.375, 0.2109375, content: .editor),
             Panel(2, -0.203, 0.115, 0.375, 0.2109375, content: .activity),
             Panel(3, 0.203, 0.115, 0.375, 0.2109375, content: .notes)]
        case .seamless:
            [Panel(0, 0, 0, 0.90, 0.50625, primary: true)]
        case .commandCenter:
            [Panel(1, -0.253, 0.14, 0.223, 0.125, turn: -17, tilt: -9, content: .editor),
             Panel(2, 0, 0.14, 0.223, 0.125, tilt: -9, content: .activity),
             Panel(3, 0.253, 0.14, 0.223, 0.125, turn: 17, tilt: -9, content: .notes),
             Panel(0, 0, -0.081, 0.54, 0.30375, primary: true)]
        }
    }

    var drawingAspect: CGFloat {
        switch self {
        case .seamless: 1.78
        case .stacked, .tiled, .commandCenter: 2.06
        default: 2.55
        }
    }
}

enum SampleContent {
    case browser, editor, notes, activity
}

enum Destination: String, CaseIterable, Identifiable {
    case workspace, stereo, devices

    var id: Self { self }

    var name: String {
        switch self {
        case .workspace: "空间工作台"
        case .stereo: "立体显示"
        case .devices: "显示设备"
        }
    }

    @ViewBuilder
    var icon: some View {
        switch self {
        case .workspace:
            Image(systemName: "rectangle.3.group")
        case .stereo:
            ZStack {
                Circle().strokeBorder(.foreground, lineWidth: 1.8)
                    .frame(width: 14, height: 14)
                    .offset(x: -4.5)
                Circle().strokeBorder(.foreground, lineWidth: 1.8)
                    .frame(width: 14, height: 14)
                    .offset(x: 4.5)
            }
        case .devices:
            Image(systemName: "visionpro")
        }
    }
}

enum RefreshRate: Int, CaseIterable, Identifiable, Codable {
    case hz60 = 60, hz90 = 90, hz120 = 120
    var id: Self { self }
    var label: String { "\(rawValue) Hz" }
}

enum Palette {
    static let accent = Color(red: 0.28, green: 0.43, blue: 0.99)
    static let cyan = Color(red: 0.48, green: 0.83, blue: 1)
    static let stage = Color(red: 0.033, green: 0.057, blue: 0.118)
    static let night = Color(red: 0.026, green: 0.037, blue: 0.071)
}

enum WorkspaceViewMode: String, CaseIterable, Identifiable, Codable {
    case overview, lookAround

    static let fieldRange: ClosedRange<Double> = 38...96
    static let defaultField = 62.0
    var id: Self { self }
    var label: String { self == .overview ? "一览" : "转头查看" }

    func zoom(field: Double) -> CGFloat {
        guard self == .lookAround else { return 1 }
        let range = Self.fieldRange
        let angle = min(range.upperBound, max(range.lowerBound, field))
        return tan(Self.defaultField * .pi / 360) / tan(angle * .pi / 360)
    }
}
