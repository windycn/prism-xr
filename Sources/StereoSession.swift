import AppKit
import Observation

@MainActor
@Observable
final class StereoSession {
    enum Source: String, CaseIterable, Identifiable {
        case pattern = "测试图"
        case image = "本地图片"
        case live = "实时画面"
        var id: Self { self }
    }

    var source: Source = .pattern
    private(set) var pair: StereoPair?
    private(set) var imageName: String?
    private(set) var isProcessing = false
    private(set) var latency: Duration?
    private(set) var error: String?

    private let engine = StereoEngine()
    private var original: CGImage?
    private var generation = UUID()

    func setSource(_ source: Source) {
        guard self.source != source else { return }
        self.source = source
        reset()
    }

    func retryLive() {
        guard source == .live, error != nil else { return }
        reset()
    }

    func reset() {
        generation = UUID()
        pair = nil
        latency = nil
        isProcessing = false
        error = nil
    }

    func importImage(_ url: URL, disparity: Double) {
        reset()
        original = nil
        imageName = nil
        isProcessing = true
        let token = generation
        Task {
            do {
                let image = try await engine.readImage(url)
                guard token == generation else { return }
                imageName = url.lastPathComponent
                original = image
                isProcessing = false
                submit(image, disparity: disparity)
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }

    func refreshImage(disparity: Double) {
        guard let original else { return }
        reset()
        submit(original, disparity: disparity)
    }

    func submit(_ image: CGImage, disparity: Double) {
        guard !isProcessing, error == nil else { return }
        isProcessing = true
        let token = generation
        Task {
            let start = ContinuousClock.now
            do {
                let result = try await engine.convert(image, disparity: disparity)
                guard token == generation else { return }
                pair = result
                latency = start.duration(to: .now)
            } catch {
                guard token == generation else { return }
                self.error = error.localizedDescription
            }
            isProcessing = false
        }
    }
}
