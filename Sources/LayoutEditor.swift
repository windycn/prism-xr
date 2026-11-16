import SwiftUI

struct LayoutEditor: View {
    let library: LayoutLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomLayout
    @State private var selectedID: CustomScreen.ID
    @State private var saveError = false

    init(library: LayoutLibrary, draft: CustomLayout) {
        self.library = library
        _draft = State(initialValue: draft)
        _selectedID = State(initialValue: draft.primaryID)
    }

    private var selectedScreen: CustomScreen? { draft.screens.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "自定义屏幕布局", detail: "在画布中拖动屏幕，选中后可以调整比例、大小和主屏。")
            TextField("布局名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            HStack(alignment: .top, spacing: 16) {
                editorCanvas
                    .aspectRatio(16.0 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                controls
                    .frame(width: 192)
            }

            Divider()
            HStack {
                Text("\(draft.screens.count) / \(CustomLayout.maximumScreens) 块屏幕")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("尺寸以画布比例表示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存布局") {
                    if library.save(draft) { dismiss() }
                    else { saveError = true }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
            }
        }
        .padding(24)
        .frame(width: 826)
        .alert("无法保存布局", isPresented: $saveError) {
            Button("好", role: .cancel) {}
        }
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                EditorGrid()
                ForEach(Array(draft.screens.enumerated()), id: \.element.id) { index, screen in
                    DraggableScreen(screen: screen, number: index + 1, canvas: size,
                                    selected: screen.id == selectedID, primary: screen.id == draft.primaryID,
                                    select: { selectedID = screen.id },
                                    move: { point in
                                        draft.updateScreen(screen.id) { $0.move(x: point.x, y: point.y) }
                                    })
                        .zIndex(screen.id == selectedID ? 1 : 0)
                }
            }
            .coordinateSpace(name: "layout-editor-canvas")
        }
        .clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.13)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("布局画布")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button("添加屏幕", systemImage: "plus") {
                if let id = draft.addScreen() { selectedID = id }
            }
            .disabled(draft.screens.count >= CustomLayout.maximumScreens)
            Divider()
            Picker("选中屏幕", selection: $selectedID) {
                ForEach(Array(draft.screens.enumerated()), id: \.element.id) { index, screen in
                    Text(screen.id == draft.primaryID ? "屏幕 \(index + 1) · 主屏" : "屏幕 \(index + 1)")
                        .tag(screen.id)
                }
            }
            .labelsHidden()
            .help("选择要编辑的屏幕")

            if let screen = selectedScreen {
                Picker("屏幕比例", selection: Binding(get: { screen.shape }, set: { shape in
                    draft.updateScreen(screen.id) {
                        if shape == .custom && $0.customAspect == nil { $0.customAspect = Double($0.aspect) }
                        $0.shape = shape
                    }
                })) {
                    ForEach(ScreenShape.allCases) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
                .labelsHidden()
                .help("更改屏幕比例")

                if screen.shape == .custom {
                    HStack(spacing: 7) {
                        Text("宽高比")
                            .font(.subheadline)
                        TextField("宽高比", value: Binding(get: {
                            screen.customAspect ?? Double(screen.aspect)
                        }, set: { aspect in
                            draft.updateScreen(screen.id) { $0.customAspect = aspect }
                        }), format: .number.precision(.fractionLength(0...3)))
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 56)
                        Text(": 1").foregroundStyle(.secondary)
                    }
                    Text("支持 0.25–5，可输入小数")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("画布宽度", value: Double(screen.width).formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline)
                Slider(value: Binding(get: { screen.width }, set: { width in
                    draft.updateScreen(screen.id) { $0.width = width }
                }), in: screen.widthRange) { Text("屏幕宽度") }
                    .labelsHidden()

                Divider()
                Button("设为主屏", systemImage: "star") {
                    draft.primaryID = screen.id
                }
                .disabled(screen.id == draft.primaryID)
                Button("移除屏幕", systemImage: "minus.circle", role: .destructive) {
                    draft.removeScreen(screen.id)
                    selectedID = draft.primaryID
                }
                .disabled(draft.screens.count <= 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 13))
    }
}

private struct DraggableScreen: View {
    let screen: CustomScreen
    let number: Int
    let canvas: CGSize
    let selected: Bool
    let primary: Bool
    let select: () -> Void
    let move: (CGPoint) -> Void
    @GestureState private var translation: CGSize = .zero

    private var point: CGPoint {
        translated(by: translation)
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Text("屏幕 \(number)")
                    .font(.caption.weight(.semibold))
                if primary && screen.height * canvas.width > 37 {
                    Label("主屏", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.cyan)
                }
            }
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.linearGradient(colors: [selected ? Color.indigo : Palette.stage, Palette.night],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Palette.cyan : .white.opacity(0.27), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .frame(width: screen.width * canvas.width, height: screen.height * canvas.width)
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("layout-editor-canvas"))
                .updating($translation) { value, state, _ in state = value.translation }
                .onChanged { _ in if !selected { select() } }
                .onEnded { value in move(translated(by: value.translation)) }
        )
        .position(x: canvas.width / 2 + point.x * canvas.width,
                  y: canvas.height / 2 + point.y * canvas.width)
        .accessibilityLabel(primary ? "屏幕 \(number)，主屏" : "屏幕 \(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("向左移动")) { nudge(x: -0.02, y: 0) }
        .accessibilityAction(named: Text("向右移动")) { nudge(x: 0.02, y: 0) }
        .accessibilityAction(named: Text("向上移动")) { nudge(x: 0, y: -0.02) }
        .accessibilityAction(named: Text("向下移动")) { nudge(x: 0, y: 0.02) }
    }

    private func translated(by distance: CGSize) -> CGPoint {
        let unit = max(canvas.width, 1)
        return screen.position(x: screen.x + distance.width / unit, y: screen.y + distance.height / unit)
    }

    private func nudge(x: CGFloat, y: CGFloat) {
        select()
        move(screen.position(x: screen.x + x, y: screen.y + y))
    }
}

private struct EditorGrid: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 32
            let lines = Path { path in
                for index in 1..<32 {
                    let x = CGFloat(index) * unit
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for index in 1..<18 {
                    let y = CGFloat(index) * unit
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(lines, with: .color(Palette.cyan.opacity(0.13)), lineWidth: 0.55)
        }
        .background(Palette.night)
        .accessibilityHidden(true)
    }
}
