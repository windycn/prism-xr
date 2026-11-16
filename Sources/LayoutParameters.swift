import SwiftUI

struct LayoutParameters: View {
    let layout: WorkspaceLayout
    let library: LayoutLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var inputs: [String: ResolutionInput]
    @State private var refresh: RefreshRate

    private let screens: [ConfigurableScreen]

    init(layout: WorkspaceLayout, library: LayoutLibrary) {
        self.layout = layout
        self.library = library
        let preferences = library.preferences(for: layout)
        let screens = layout.configurableScreens
        self.screens = screens
        _selectedID = State(initialValue: screens.first?.id)
        _inputs = State(initialValue: Dictionary(uniqueKeysWithValues: screens.map { screen in
            (screen.id, ResolutionInput(preferences.targets[screen.id] ?? screen.target))
        }))
        _refresh = State(initialValue: preferences.refresh)
    }

    private var selectedScreen: ConfigurableScreen? {
        screens.first { $0.id == selectedID }
    }

    private var isValid: Bool {
        screens.allSatisfy { inputs[$0.id]?.target != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading(title: "布局参数", detail: "\(layout.name) · 参数保存在此布局中")

            HStack(alignment: .top, spacing: 18) {
                screenList
                    .frame(width: 196)
                if let screen = selectedScreen, let input = inputs[screen.id] {
                    resolutionForm(screen, input: input)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button("恢复本页默认值") {
                    inputs = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, ResolutionInput($0.target)) })
                    refresh = LayoutPreferences().refresh
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存参数", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 700)
    }

    private var screenList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(screens) { screen in
                    let active = screen.id == selectedID
                    Button {
                        selectedID = screen.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "display")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(screen.name).font(.subheadline.weight(.medium))
                                Text(inputs[screen.id]?.target?.logicalLabel ?? "尺寸超出范围")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(active ? Palette.accent.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 9))
                        .contentShape(.rect(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(6)
        }
        .frame(height: 245)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    private func resolutionForm(_ screen: ConfigurableScreen, input: ResolutionInput) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if layout.mirroredPanelID(using: library.preferences(for: layout)) == screen.panel.id {
                Text("此屏镜像 Mac 桌面，实际分辨率沿用 Mac 显示器。以下参数会在此屏改为独立桌面时使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("目标逻辑分辨率").font(.headline)
                Spacer()
                Menu("常用分辨率") {
                    ForEach(resolutionChoices(screen), id: \.logicalLabel) { choice in
                        Button(choice.logicalLabel) {
                            inputs[screen.id] = ResolutionInput(choice, hiDPI: input.hiDPI)
                        }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                TextField("宽", text: field(\.width, for: screen))
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .accessibilityLabel("目标逻辑宽度")
                Text("×").foregroundStyle(.secondary)
                TextField("高", text: field(\.height, for: screen))
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .accessibilityLabel("目标逻辑高度")
                Text("pt").foregroundStyle(.secondary)
            }
            Toggle("HiDPI（2×）", isOn: field(\.hiDPI, for: screen))
                .toggleStyle(.switch)
            Text(input.target.map { "目标渲染像素  \($0.backingLabel) px" } ?? "宽度 320–7680，高度 240–4320。")
                .font(.caption.monospacedDigit())
                .foregroundStyle(input.target == nil ? Color.red : Color.secondary)
            Divider()
            Picker("刷新率偏好", selection: $refresh) {
                ForEach(RefreshRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            Text("分辨率、HiDPI 和刷新率保存在此布局中。空间桌面运行时，保存会重新配置独立显示器。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Value>(_ key: WritableKeyPath<ResolutionInput, Value>,
                              for screen: ConfigurableScreen) -> Binding<Value> {
        Binding {
            (inputs[screen.id] ?? ResolutionInput(screen.target))[keyPath: key]
        } set: { value in
            var input = inputs[screen.id] ?? ResolutionInput(screen.target)
            input[keyPath: key] = value
            inputs[screen.id] = input
        }
    }

    private func resolutionChoices(_ screen: ConfigurableScreen) -> [ScreenTarget] {
        let aspect = CGFloat(screen.target.width) / CGFloat(screen.target.height)
        return [720, 1080, 1440, 2160].map { ScreenTarget.suggested(aspect: aspect, shortEdge: $0) }
            .filter(\.isValid)
    }

    private func save() {
        guard isValid else { return }
        let overrides = screens.compactMap { screen -> (String, ScreenTarget)? in
            guard let target = inputs[screen.id]?.target, target != screen.target else { return nil }
            return (screen.id, target)
        }
        library.updatePreferences(for: layout) {
            $0.targets = Dictionary(uniqueKeysWithValues: overrides)
            $0.refresh = refresh
        }
        dismiss()
    }
}

private struct ResolutionInput {
    var width: String
    var height: String
    var hiDPI: Bool

    init(_ target: ScreenTarget, hiDPI: Bool? = nil) {
        width = String(target.width)
        height = String(target.height)
        self.hiDPI = hiDPI ?? target.hiDPI
    }

    var target: ScreenTarget? {
        guard let width = Int(width.trimmingCharacters(in: .whitespaces)),
              let height = Int(height.trimmingCharacters(in: .whitespaces)) else { return nil }
        let target = ScreenTarget(width: width, height: height, hiDPI: hiDPI)
        return target.isValid ? target : nil
    }
}
