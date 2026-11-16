import Foundation
import Observation

enum ScreenShape: String, CaseIterable, Identifiable, Codable {
    case landscape, laptop, classic, square, portrait, portraitClassic, cinematic, ultrawide, custom

    var id: Self { self }

    var label: String {
        switch self {
        case .landscape: "横屏 16:9"
        case .laptop: "横屏 16:10"
        case .classic: "横屏 4:3"
        case .square: "方屏 1:1"
        case .portrait: "竖屏 9:16"
        case .portraitClassic: "竖屏 3:4"
        case .cinematic: "超宽 21:9"
        case .ultrawide: "超宽 32:9"
        case .custom: "自定义宽高比"
        }
    }

    var aspect: CGFloat {
        switch self {
        case .landscape, .custom: 16.0 / 9
        case .laptop: 16.0 / 10
        case .classic: 4.0 / 3
        case .square: 1
        case .portrait: 9.0 / 16
        case .portraitClassic: 3.0 / 4
        case .cinematic: 21.0 / 9
        case .ultrawide: 32.0 / 9
        }
    }
}

struct CustomScreen: Identifiable, Codable, Equatable {
    static let canvasHeight: CGFloat = 9.0 / 16
    static let aspectRange: ClosedRange<Double> = 0.25...5
    let id: UUID
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var shape: ScreenShape
    var customAspect: Double?

    init(id: UUID = UUID(), x: CGFloat = 0, y: CGFloat = 0,
         width: CGFloat = 0.38, shape: ScreenShape = .landscape) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.shape = shape
        fit()
    }

    var aspect: CGFloat {
        if shape == .custom, let customAspect, customAspect.isFinite {
            return min(Self.aspectRange.upperBound, max(Self.aspectRange.lowerBound, customAspect))
        }
        return shape.aspect
    }

    var height: CGFloat { width / aspect }

    var widthRange: ClosedRange<CGFloat> {
        0.12...min(0.78, (Self.canvasHeight - 0.04) * aspect)
    }

    var rect: CGRect {
        CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    func position(x: CGFloat, y: CGFloat) -> CGPoint {
        let limitX = (1 - width) / 2 - 0.02
        let limitY = (Self.canvasHeight - height) / 2 - 0.02
        return CGPoint(x: min(limitX, max(-limitX, x)), y: min(limitY, max(-limitY, y)))
    }

    mutating func move(x: CGFloat, y: CGFloat) {
        let center = position(x: x, y: y)
        self.x = center.x
        self.y = center.y
    }

    mutating func fit() {
        if let customAspect, customAspect.isFinite {
            self.customAspect = min(Self.aspectRange.upperBound, max(Self.aspectRange.lowerBound, customAspect))
        }
        width = min(widthRange.upperBound, max(widthRange.lowerBound, width))
        move(x: x, y: y)
    }
}

struct CustomLayout: Identifiable, Codable, Equatable {
    static let maximumScreens = 8

    let id: UUID
    var name: String
    var screens: [CustomScreen]
    var primaryID: CustomScreen.ID

    init(name: String) {
        let screen = CustomScreen()
        id = UUID()
        self.name = name
        screens = [screen]
        primaryID = screen.id
    }

    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool {
        !displayName.isEmpty && !screens.isEmpty && screens.count <= Self.maximumScreens &&
            screens.contains(where: { $0.id == primaryID })
    }

    mutating func addScreen() -> CustomScreen.ID? {
        guard screens.count < Self.maximumScreens else { return nil }
        var new = CustomScreen(width: 0.28)
        var best = new
        var lowestOverlap = CGFloat.infinity
        for y in [0, -0.16, 0.16] {
            for x in [0.31, -0.31, 0.0] {
                new.move(x: x, y: y)
                let overlap = screens.reduce(CGFloat.zero) { total, screen in
                    let intersection = new.rect.intersection(screen.rect)
                    return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
                if overlap < lowestOverlap {
                    lowestOverlap = overlap
                    best = new
                }
            }
        }
        screens.append(best)
        return best.id
    }

    mutating func removeScreen(_ id: CustomScreen.ID) {
        guard screens.count > 1 else { return }
        screens.removeAll { $0.id == id }
        if primaryID == id { primaryID = screens[0].id }
    }

    mutating func updateScreen(_ id: CustomScreen.ID, update: (inout CustomScreen) -> Void) {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        update(&screens[index])
        screens[index].fit()
    }
}

enum WorkspaceLayout: Equatable, Identifiable {
    case preset(ScreenLayout)
    case custom(CustomLayout)

    var id: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .custom(let custom): custom.id.uuidString
        }
    }

    var name: String {
        switch self {
        case .preset(let preset): preset.name
        case .custom(let custom): custom.displayName
        }
    }

    var detail: String {
        switch self {
        case .preset(let preset): preset.detail
        case .custom(let custom): "\(custom.screens.count) 块屏幕"
        }
    }

    var drawingAspect: CGFloat {
        switch self {
        case .preset(let preset): preset.drawingAspect
        case .custom: 1 / CustomScreen.canvasHeight
        }
    }

    var isContinuousCanvas: Bool { self == .preset(.seamless) }

    var panels: [ScreenLayout.Panel] {
        switch self {
        case .preset(let preset):
            preset.panels
        case .custom(let custom):
            custom.screens.enumerated().map { index, screen in
                let primary = screen.id == custom.primaryID
                let samples: [SampleContent] = [.editor, .notes, .activity]
                return ScreenLayout.Panel(index, screen.x, screen.y, screen.width, screen.height,
                                          content: primary ? .browser : samples[index % samples.count],
                                          primary: primary)
            }
        }
    }
}

@MainActor
@Observable
final class LayoutLibrary {
    private struct Saved: Codable {
        var layouts: [CustomLayout] = []
        var selectedID: UUID?
        var configurations: [String: LayoutPreferences]?
    }

    private static let customKey = "workspaceCustomLayouts"
    private static let presetKey = "workspaceLayout"

    private let defaults: UserDefaults
    private var saved: Saved
    private var preset: ScreenLayout

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = defaults.string(forKey: Self.presetKey).flatMap(ScreenLayout.init(rawValue:)) ?? .triple
        saved = defaults.data(forKey: Self.customKey)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        if saved.configurations == nil {
            var next = saved
            var initial = LayoutPreferences()
            if let rawRate = defaults.object(forKey: "workspaceRefresh") as? Int,
               let rate = RefreshRate(rawValue: rawRate) {
                initial.refresh = rate
            }
            next.configurations = initial == LayoutPreferences() ? [:] : [preset.rawValue: initial]
            store(next)
        }
    }

    var customLayouts: [CustomLayout] { saved.layouts }

    var selection: WorkspaceLayout {
        if let custom = saved.layouts.first(where: { $0.id == saved.selectedID }) {
            return .custom(custom)
        }
        return .preset(preset)
    }

    var preferences: LayoutPreferences { preferences(for: selection) }

    func preferences(for layout: WorkspaceLayout) -> LayoutPreferences {
        saved.configurations?[layout.id] ?? LayoutPreferences()
    }

    func updatePreferences(for layout: WorkspaceLayout, _ update: (inout LayoutPreferences) -> Void) {
        var next = saved
        var updated = preferences(for: layout)
        update(&updated)
        guard updated != preferences(for: layout) else { return }
        next.configurations?[layout.id] = updated
        store(next)
    }

    func resetPresets() {
        var next = saved
        for preset in ScreenLayout.allCases { next.configurations?.removeValue(forKey: preset.rawValue) }
        store(next)
    }

    func newDraft() -> CustomLayout {
        var number = 1
        let names = Set(saved.layouts.map(\.displayName))
        while names.contains("自定义布局 \(number)") { number += 1 }
        return CustomLayout(name: "自定义布局 \(number)")
    }

    func select(_ layout: WorkspaceLayout) {
        switch layout {
        case .preset(let preset):
            defaults.set(preset.rawValue, forKey: Self.presetKey)
            self.preset = preset
            if saved.selectedID != nil {
                var next = saved
                next.selectedID = nil
                store(next)
            }
        case .custom(let custom):
            guard saved.layouts.contains(where: { $0.id == custom.id }), saved.selectedID != custom.id else { return }
            var next = saved
            next.selectedID = custom.id
            store(next)
        }
    }

    @discardableResult
    func save(_ draft: CustomLayout) -> Bool {
        guard draft.isValid else { return false }
        var next = saved
        var clean = draft
        clean.name = draft.displayName
        if let index = next.layouts.firstIndex(where: { $0.id == draft.id }) {
            next.layouts[index] = clean
        } else {
            next.layouts.append(clean)
        }
        let key = clean.id.uuidString
        let screenIDs = Set(clean.screens.map { $0.id.uuidString })
        if var preferences = next.configurations?[key] {
            preferences.targets = preferences.targets.filter { screenIDs.contains($0.key) }
            next.configurations?[key] = preferences
        }
        next.selectedID = draft.id
        return store(next)
    }

    func delete(_ id: CustomLayout.ID) {
        var next = saved
        next.layouts.removeAll { $0.id == id }
        next.configurations?.removeValue(forKey: id.uuidString)
        if next.selectedID == id { next.selectedID = nil }
        store(next)
    }

    @discardableResult
    private func store(_ next: Saved) -> Bool {
        guard let data = try? JSONEncoder().encode(next) else { return false }
        defaults.set(data, forKey: Self.customKey)
        saved = next
        return true
    }
}

struct ScreenTarget: Codable, Equatable {
    static let widthRange = 320...7680
    static let heightRange = 240...4320

    let width: Int
    let height: Int
    let hiDPI: Bool

    var isValid: Bool { Self.widthRange.contains(width) && Self.heightRange.contains(height) }
    var logicalLabel: String { "\(width) × \(height)" }
    var backingLabel: String {
        let scale = hiDPI ? 2 : 1
        return "\(width * scale) × \(height * scale)"
    }

    static func suggested(aspect: CGFloat, shortEdge: Int, hiDPI: Bool = false) -> Self {
        if aspect >= 1 {
            return Self(width: Int((CGFloat(shortEdge) * aspect).rounded()), height: shortEdge, hiDPI: hiDPI)
        }
        return Self(width: shortEdge, height: Int((CGFloat(shortEdge) / aspect).rounded()), hiDPI: hiDPI)
    }
}

struct ConfigurableScreen: Identifiable {
    let id: String
    let name: String
    let panel: ScreenLayout.Panel
    let target: ScreenTarget
}

struct LayoutPreferences: Codable, Equatable {
    var targets: [String: ScreenTarget] = [:]
    var refresh: RefreshRate = .hz60
    var mode: WorkspaceViewMode = .lookAround
    var field: Double = WorkspaceViewMode.defaultField
    var mirrorScreenID: String?
}

extension WorkspaceLayout {
    func mirroredPanelID(using preferences: LayoutPreferences) -> Int? {
        if let key = preferences.mirrorScreenID,
           let screen = configurableScreens.first(where: { $0.id == key }) { return screen.panel.id }
        return panels.first(where: \.primary)?.id ?? panels.first?.id
    }
    var centersOnCanvas: Bool { self == .preset(.tiled) || isContinuousCanvas }

    var configurableScreens: [ConfigurableScreen] {
        panels.sorted { $0.id < $1.id }.enumerated().map { index, panel in
            let key: String
            let ratio: CGFloat
            switch self {
            case .preset(let preset):
                key = String(panel.id)
                if panel.height > panel.width {
                    ratio = 9.0 / 16
                } else {
                    ratio = preset == .wide ? 32.0 / 9 : 16.0 / 9
                }
            case .custom(let layout):
                key = layout.screens[panel.id].id.uuidString
                ratio = panel.width / panel.height
            }
            let shortEdge = isContinuousCanvas ? 1440 : min(900, Int(4320 * ratio))
            let target = ScreenTarget.suggested(aspect: ratio, shortEdge: shortEdge, hiDPI: true)
            return ConfigurableScreen(id: key, name: panel.primary ? "屏幕 \(index + 1) · 主屏" : "屏幕 \(index + 1)",
                                      panel: panel, target: target)
        }
    }

    func panels(using preferences: LayoutPreferences) -> [ScreenLayout.Panel] {
        if self == .preset(.triple) || self == .preset(.stacked) { return panels }
        guard !preferences.targets.isEmpty else { return panels }
        let screens = Dictionary(uniqueKeysWithValues: configurableScreens.map { ($0.panel.id, $0.id) })
        return panels.map { panel in
            guard let key = screens[panel.id], let target = preferences.targets[key], target.isValid else {
                return panel
            }
            let ratio = CGFloat(target.width) / CGFloat(target.height)
            return ScreenLayout.Panel(panel.id, panel.x, panel.y,
                                      min(panel.width, panel.height * ratio),
                                      min(panel.height, panel.width / ratio),
                                      turn: panel.turn, tilt: panel.tilt, content: panel.content, primary: panel.primary)
        }
    }
}
