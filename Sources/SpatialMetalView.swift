import AppKit
import MetalKit
import QuartzCore
import SwiftUI

struct WorkspaceGPUOutput: View {
    let layouts: LayoutLibrary
    let desktop: SpatialDesktop
    let tracker: RayneoTracker
    @AppStorage("lockWorkspaceHorizon") private var lockHorizon = true

    var body: some View {
        SpatialMetalSurface(layout: layouts.selection, preferences: layouts.preferences,
                            frames: desktop.frameStore, input: desktop.supportsOutputTracking && tracker.isRunning ? tracker.input : nil,
                            lockHorizon: lockHorizon)
            .background(.black)
            .ignoresSafeArea()
    }
}

struct SpatialMetalSurface: NSViewRepresentable {
    let layout: WorkspaceLayout
    let preferences: LayoutPreferences
    let frames: SpatialFrameStore
    let input: RayneoInput?
    let lockHorizon: Bool

    func makeCoordinator() -> SpatialMetalRenderer { SpatialMetalRenderer(frames: frames) }
    func makeNSView(context: Context) -> DesktopMetalView {
        context.coordinator.configure(layout: layout, preferences: preferences, input: input, lockHorizon: lockHorizon)
        return DesktopMetalView(renderer: context.coordinator)
    }
    func updateNSView(_ view: DesktopMetalView, context: Context) {
        context.coordinator.configure(layout: layout, preferences: preferences, input: input, lockHorizon: lockHorizon)
    }
    static func dismantleNSView(_ view: DesktopMetalView, coordinator: SpatialMetalRenderer) { view.stopRendering() }
}

@MainActor
final class DesktopMetalView: NSView {
    private let renderer: SpatialMetalRenderer
    private var driver: SpatialDisplayDriver?

    init(renderer: SpatialMetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return layer
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopRendering()
        resizeDrawable()
        if window != nil, let layer = layer as? CAMetalLayer {
            let driver = SpatialDisplayDriver(layer: layer, renderer: renderer)
            self.driver = driver
            driver.start()
        }
    }
    override func layout() { super.layout(); resizeDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeDrawable() }
    private func resizeDrawable() {
        guard let layer = layer as? CAMetalLayer else { return }
        let size = convertToBacking(bounds).size
        layer.contentsScale = window?.backingScaleFactor ?? 1
        layer.drawableSize = CGSize(width: max(1, size.width), height: max(1, size.height))
    }
    func stopRendering() { driver?.cancel(); driver = nil }
}

// Rendering has its own display-synchronized run loop. Neither a SwiftUI
// update nor a dragged settings control can stall the head-pose presentation.
private final class SpatialDisplayDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private let layer: CAMetalLayer
    private let renderer: SpatialMetalRenderer
    private let lock = NSLock()
    private var cancelled = false

    init(layer: CAMetalLayer, renderer: SpatialMetalRenderer) { self.layer = layer; self.renderer = renderer }
    func cancel() { lock.withLock { cancelled = true } }
    func start() {
        Thread.detachNewThread { [self] in
            Thread.current.name = "Prism XR display"
            Thread.current.qualityOfService = .userInteractive
            autoreleasepool {
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.delegate = self
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.preferredFrameLatency = 1
                link.add(to: .current, forMode: .common)
                link.isPaused = false
                while !lock.withLock({ cancelled }) {
                    autoreleasepool {
                        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                    }
                }
                link.invalidate()
            }
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard !lock.withLock({ cancelled }) else { return }
        let texture = update.drawable.texture
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderer.render(pass: pass, drawable: update.drawable, size: CGSize(width: texture.width, height: texture.height))
    }
}

private struct SpatialVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private final class SpatialMetalTexture: @unchecked Sendable {
    let frame: SpatialCapturedFrame
    let wrapper: CVMetalTexture
    let texture: any MTLTexture
    init(frame: SpatialCapturedFrame, wrapper: CVMetalTexture, texture: any MTLTexture) {
        self.frame = frame; self.wrapper = wrapper; self.texture = texture
    }
}

final class SpatialMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: (any MTLDevice)?
    private let frames: SpatialFrameStore
    private let configurationLock = NSLock()
    private var queue: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var sampler: (any MTLSamplerState)?
    private var cache: CVMetalTextureCache?
    private var textures: [Int: SpatialMetalTexture] = [:]
    private let inFlight = DispatchSemaphore(value: 3)
    private var layout = WorkspaceLayout.preset(.single)
    private var preferences = LayoutPreferences()
    private var input: RayneoInput?
    private var lockHorizon = true
    private var scenePanels: [ScreenLayout.Panel] = ScreenLayout.single.panels
    private var textureGeneration = UUID()

    init(frames: SpatialFrameStore) {
        self.frames = frames
        device = MTLCreateSystemDefaultDevice()
        super.init()
        guard let device else { frames.failed("无法创建设备的 Metal 渲染器"); return }
        queue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "spatialVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spatialFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let sampling = MTLSamplerDescriptor()
            sampling.minFilter = .linear; sampling.magFilter = .linear
            sampling.sAddressMode = .clampToEdge; sampling.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: sampling)
        } catch { frames.failed(error.localizedDescription) }
    }

    func configure(layout: WorkspaceLayout, preferences: LayoutPreferences, input: RayneoInput?, lockHorizon: Bool) {
        configurationLock.withLock {
            self.layout = layout; self.preferences = preferences; self.input = input; self.lockHorizon = lockHorizon
            self.scenePanels = layout.panels(using: preferences)
        }
    }
    @MainActor func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    @MainActor func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        render(pass: pass, drawable: drawable, size: view.drawableSize)
    }

    func render(pass: MTLRenderPassDescriptor, drawable: any CAMetalDrawable, size: CGSize) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard let pipeline, let queue, let sampler, inFlight.wait(timeout: .now()) == .success else { return }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal(); return
        }
        let snapshot = input?.snapshot()
        let pose = snapshot?.running == true && snapshot?.calibrated == true ? snapshot!.pose : HeadPose()
        let transport = frames.snapshot()
        let latest = transport.frames
        let generation = transport.generation
        if generation != textureGeneration {
            textureGeneration = generation
            textures.removeAll(keepingCapacity: true)
            if let cache { CVMetalTextureCacheFlush(cache, 0) }
        }
        if textures.count != latest.count || textures.keys.contains(where: { latest[$0] == nil }) {
            textures = textures.filter { latest[$0.key] != nil }
        }
        for (panel, frame) in latest where textures[panel]?.frame.sequence != frame.sequence {
            if let texture = makeTexture(frame) { textures[panel] = texture }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let panels = scenePanels
        let placement = placement(panels: panels, size: size, pose: pose)
        var retained: [SpatialMetalTexture] = []
        for panel in panels {
            guard let texture = textures[panel.id] else { continue }
            var vertices = vertices(panel: panel, size: size, placement: placement, roll: lockHorizon ? 0 : pose.roll,
                                    imageAspect: Double(texture.texture.width) / Double(texture.texture.height))
            encoder.setVertexBytes(&vertices, length: MemoryLayout<SpatialVertex>.stride * vertices.count, index: 0)
            encoder.setFragmentTexture(texture.texture, index: 0)
            let panelAspect = Double(panel.width / panel.height)
            let imageAspect = Double(texture.texture.width) / Double(texture.texture.height)
            var mapping = SIMD4<Float>(Float(max(1, panelAspect / imageAspect)), Float(max(1, imageAspect / panelAspect)), 0, 0)
            encoder.setFragmentBytes(&mapping, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            retained.append(texture)
        }
        encoder.endEncoding()
        drawable.addPresentedHandler { [frames, generation] presented in
            frames.rendered(at: presented.presentedTime, size: size, generation: generation)
        }
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { [retained, frames] buffer in
            withExtendedLifetime(retained) {}
            if buffer.status == .error { frames.failed(buffer.error?.localizedDescription ?? "Metal 渲染失败") }
            semaphore.signal()
        }
        command.commit()
    }

    private func makeTexture(_ frame: SpatialCapturedFrame) -> SpatialMetalTexture? {
        guard let cache else { return nil }
        var wrapper: CVMetalTexture?
        let buffer = frame.buffer
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm_srgb,
                                                       CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper) == kCVReturnSuccess,
              let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            frames.failed("无法直接映射桌面纹理"); return nil
        }
        return SpatialMetalTexture(frame: frame, wrapper: wrapper, texture: texture)
    }

    private struct Placement { let unit: Double; let x: Double; let y: Double }
    private func placement(panels: [ScreenLayout.Panel], size: CGSize, pose: HeadPose) -> Placement {
        let width = max(1, size.width - 24), height = max(1, size.height - 32)
        let halfWidth = panels.map { abs($0.x) + $0.width / 2 }.max() ?? 0.5
        let halfHeight = panels.map { abs($0.y) + $0.height / 2 }.max() ?? 0.5
        let fit = min(width, height * layout.drawingAspect, width / (2 * halfWidth), height / (2 * halfHeight))
        guard preferences.mode == .lookAround else { return Placement(unit: fit, x: 0, y: 0) }
        let primary = panels.first(where: \.primary)
        let unit = !layout.centersOnCanvas && primary != nil
            ? max(fit, min(width / primary!.width, height / primary!.height) * 0.98) * preferences.mode.zoom(field: preferences.field)
            : fit * preferences.mode.zoom(field: preferences.field)
        let origin = layout.centersOnCanvas ? CGPoint.zero : CGPoint(x: primary?.x ?? 0, y: primary?.y ?? 0)
        let yaw = min(40, max(-40, pose.yaw)), pitch = min(26, max(-26, pose.pitch))
        let xTarget = (yaw >= 0 ? panels.map(\.x).max() : panels.map(\.x).min()) ?? origin.x
        let yTarget = (pitch >= 0 ? panels.map(\.y).max() : panels.map(\.y).min()) ?? origin.y
        return Placement(unit: unit, x: origin.x + (xTarget - origin.x) * abs(yaw) / 40,
                         y: origin.y + (yTarget - origin.y) * abs(pitch) / 26)
    }
    private func vertices(panel: ScreenLayout.Panel, size: CGSize, placement: Placement, roll: Double, imageAspect: Double) -> [SpatialVertex] {
        let centerX = (panel.x - placement.x) * placement.unit
        let centerY = (panel.y - placement.y) * placement.unit
        let halfWidth = panel.width * placement.unit / 2
        let halfHeight = panel.height * placement.unit / 2
        let angle = preferences.mode == .lookAround ? -roll * .pi / 180 : 0
        let cosine = cos(angle), sine = sin(angle)
        func vertex(_ x: Double, _ y: Double, _ u: Float, _ v: Float) -> SpatialVertex {
            let rx = x * cosine - y * sine, ry = x * sine + y * cosine
            return SpatialVertex(position: SIMD2(Float(rx * 2 / size.width), Float(-ry * 2 / size.height)), uv: SIMD2(u, v))
        }
        let a = vertex(centerX - halfWidth, centerY - halfHeight, 0, 0)
        let b = vertex(centerX + halfWidth, centerY - halfHeight, 1, 0)
        let c = vertex(centerX - halfWidth, centerY + halfHeight, 0, 1)
        let d = vertex(centerX + halfWidth, centerY + halfHeight, 1, 1)
        return [a, b, c, b, d, c]
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float2 uv; };
    struct Raster { float4 position [[position]]; float2 uv; };
    vertex Raster spatialVertex(uint id [[vertex_id]], constant Vertex *vertices [[buffer(0)]]) {
        Raster out; out.position = float4(vertices[id].position, 0, 1); out.uv = vertices[id].uv; return out;
    }
    fragment float4 spatialFragment(Raster in [[stage_in]], texture2d<float> image [[texture(0)]], sampler sampling [[sampler(0)]], constant float4 &mapping [[buffer(0)]]) {
        if (in.uv.x < 0.0015 || in.uv.x > 0.9985 || in.uv.y < 0.0025 || in.uv.y > 0.9975) {
            return float4(0.16, 0.22, 0.32, 1);
        }
        float2 uv = (in.uv - 0.5) * mapping.xy + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) { return float4(0.025, 0.03, 0.045, 1); }
        return image.sample(sampling, uv);
    }
    """
}
