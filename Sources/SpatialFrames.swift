import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

struct SpatialCapturedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let sequence: UInt64
    let receivedAt: Double
}

struct SpatialRenderMetrics: Sendable {
    var fps = 0.0
    var maxGapMS = 0.0
    var width = 0
    var height = 0
    var error: String?
}

// Latest-frame mailbox: never accumulates a queue of old desktop images.
final class SpatialFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: SpatialCapturedFrame] = [:]
    private var sequence: UInt64 = 0
    private var generation = UUID()
    private var metrics = SpatialRenderMetrics()
    private var metricStart = 0.0
    private var lastDraw = 0.0
    private var draws = 0
    private var maximumGap = 0.0

    func token() -> UUID { lock.withLock { generation } }
    func store(_ buffer: CVPixelBuffer, panel: Int, generation: UUID) {
        lock.withLock {
            guard generation == self.generation else { return }
            sequence &+= 1
            frames[panel] = SpatialCapturedFrame(buffer: buffer, sequence: sequence,
                                                receivedAt: ProcessInfo.processInfo.systemUptime)
        }
    }
    func latest() -> [Int: SpatialCapturedFrame] { lock.withLock { frames } }
    func snapshot() -> (generation: UUID, frames: [Int: SpatialCapturedFrame]) {
        lock.withLock { (generation, frames) }
    }
    func reset() { lock.withLock { generation = UUID(); frames = [:]; metrics = SpatialRenderMetrics(); draws = 0; lastDraw = 0; metricStart = 0; maximumGap = 0 } }
    func readMetrics() -> SpatialRenderMetrics { lock.withLock { metrics } }
    func failed(_ message: String) { lock.withLock { metrics.error = message } }
    func rendered(at now: Double, size: CGSize, generation: UUID) {
        guard now.isFinite, now > 0 else { return }
        lock.withLock {
            guard generation == self.generation else { return }
            if metricStart == 0 { metricStart = now }
            if lastDraw > 0 { maximumGap = max(maximumGap, now - lastDraw) }
            lastDraw = now; draws += 1
            metrics.width = Int(size.width); metrics.height = Int(size.height)
            if now - metricStart >= 1 {
                metrics.fps = Double(draws) / (now - metricStart)
                metrics.maxGapMS = maximumGap * 1000
                metricStart = now; draws = 0; maximumGap = 0
            }
        }
    }
}

final class SpatialCaptureOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "PrismXR.spatialCapture", qos: .userInteractive)
    private let store: SpatialFrameStore
    private let panel: Int
    private let generation: UUID
    private let preview: @MainActor @Sendable (CGImage) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pendingPreview = DispatchSemaphore(value: 1)
    private var lastPreview = 0.0
    private let previewEnabled: Bool

    init(store: SpatialFrameStore, panel: Int, previewEnabled: Bool = true, preview: @escaping @MainActor @Sendable (CGImage) -> Void) {
        self.store = store; self.panel = panel; self.preview = preview
        generation = store.token()
        self.previewEnabled = previewEnabled
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        if let status = attachments?.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        store.store(buffer, panel: panel, generation: generation)
        guard previewEnabled else { return }
        // Only the small settings preview needs a CGImage. The glasses sample
        // the IOSurface directly, even while these preview updates are skipped.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreview >= 0.2, pendingPreview.wait(timeout: .now()) == .success else { return }
        lastPreview = now
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 960 / source.extent.width)
        let thumbnail = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(thumbnail, from: thumbnail.extent) else { pendingPreview.signal(); return }
        Task { @MainActor [preview, pendingPreview] in preview(image); pendingPreview.signal() }
    }
}
