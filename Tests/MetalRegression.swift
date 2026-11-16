import AppKit
import MetalKit
import Observation

@MainActor @Observable final class SpatialDesktop { let frameStore = SpatialFrameStore() }
@MainActor final class DrawCapture: NSObject, MTKViewDelegate {
    let renderer: SpatialMetalRenderer
    var drawable: (any CAMetalDrawable)?
    init(_ renderer: SpatialMetalRenderer) { self.renderer = renderer }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { drawable = view.currentDrawable; renderer.draw(in: view) }
}
@main enum MetalRegression {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = SpatialFrameStore()
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess)
        let pixel = pixelBuffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<180 { for x in 0..<320 {
            let color: [UInt8] = y < 90 ? (x < 160 ? [0,0,255,255] : [0,255,0,255]) : (x < 160 ? [255,0,0,255] : [255,255,255,255])
            for c in 0..<4 { bytes[y * stride + x * 4 + c] = color[c] }
        }}
        CVPixelBufferUnlockBaseAddress(pixel, [])
        store.store(pixel, panel: 0, generation: store.token())
        let renderer = SpatialMetalRenderer(frames: store)
        renderer.configure(layout: .preset(.single), preferences: LayoutPreferences(), input: nil, lockHorizon: true)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = false; view.isPaused = true
        let capture = DrawCapture(renderer); view.delegate = capture
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = view; window.orderFrontRegardless()
        view.draw()
        let deadline = Date(timeIntervalSinceNow: 2)
        while (capture.drawable?.presentedTime ?? 0) == 0 && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard let drawable = capture.drawable, let device = renderer.device else { fatalError("no drawable") }
        let texture = drawable.texture
        let row = ((texture.width * 4 + 255) / 256) * 256
        let buffer = device.makeBuffer(length: row * texture.height, options: .storageModeShared)!
        let command = device.makeCommandQueue()!.makeCommandBuffer()!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        let output = buffer.contents().assumingMemoryBound(to: UInt8.self)
        func color(_ x: Double, _ y: Double) -> [UInt8] {
            let offset = Int(y * Double(texture.height)) * row + Int(x * Double(texture.width)) * 4
            return Array(UnsafeBufferPointer(start: output + offset, count: 4))
        }
        let tl = color(0.3,0.3), tr = color(0.7,0.3), bl = color(0.3,0.7), br = color(0.7,0.7)
        print("GPU actual readback BGRA:",tl,tr,bl,br,"drawable",texture.width,texture.height,"error",store.readMetrics().error ?? "none")
        precondition(tl[2] > 240 && tl[0] < 10 && tl[1] < 10)
        precondition(tr[1] > 240 && tr[0] < 10 && tr[2] < 10)
        precondition(bl[0] > 240 && bl[1] < 10 && bl[2] < 10)
        precondition(br[0] > 240 && br[1] > 240 && br[2] > 240)
        window.close()
        print("PASS GPU IOSurface mapping, shader, color and vertical orientation")
    }
}
