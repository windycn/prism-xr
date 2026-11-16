import CoreImage
import Foundation
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class CaptureSession: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private(set) var frame: CGImage?
    private(set) var isCapturing = false
    private(set) var isChoosing = false
    private(set) var error: String?

    private var stream: SCStream?
    private var output: CaptureOutput?
    private var generation = UUID()
    private var pickerRegistered = false

    func chooseSource() {
        guard !isChoosing else { return }
        isChoosing = true
        error = nil
        let picker = SCContentSharingPicker.shared
        if !pickerRegistered {
            picker.add(self)
            pickerRegistered = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.isActive = true
        if let stream {
            picker.present(for: stream)
        } else {
            picker.present()
        }
    }

    func stop() {
        let previous = stream
        reset()
        if let previous {
            Task { try? await previous.stopCapture() }
        }
    }

    private func reset() {
        generation = UUID()
        stream = nil
        output = nil
        isChoosing = false
        isCapturing = false
        frame = nil
        error = nil
        if pickerRegistered {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
            pickerRegistered = false
        }
    }

    private func select(_ filter: SCContentFilter, existingID: ObjectIdentifier?) async {
        isChoosing = false
        error = nil
        let token = generation
        let configuration = makeConfiguration(filter)
        if let existingID {
            guard let existing = stream, ObjectIdentifier(existing) == existingID else { return }
            do {
                try await existing.updateConfiguration(configuration)
                try await existing.updateContentFilter(filter)
            } catch {
                if token == generation { self.error = error.localizedDescription }
            }
            return
        }

        guard stream == nil else { return }
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = CaptureOutput { [weak self] image in
            guard let self, self.generation == token else { return }
            self.frame = image
        }
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            self.output = output
            stream = newStream
            try await newStream.startCapture()
            guard generation == token else {
                try? await newStream.stopCapture()
                return
            }
            isCapturing = true
        } catch {
            if token == generation {
                reset()
                self.error = error.localizedDescription
            }
        }
    }

    private func makeConfiguration(_ filter: SCContentFilter) -> SCStreamConfiguration {
        let size = filter.contentRect.size
        let pixels = CGSize(width: max(size.width * CGFloat(filter.pointPixelScale), 2),
                            height: max(size.height * CGFloat(filter.pointPixelScale), 2))
        let scale = min(1, 1440 / max(pixels.width, pixels.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(pixels.width * scale) / 2 * 2)
        configuration.height = max(2, Int(pixels.height * scale) / 2 * 2)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        return configuration
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in isChoosing = false }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        let selection = PickerSelection(filter: filter, streamID: stream.map(ObjectIdentifier.init))
        Task { @MainActor in
            guard pickerRegistered else { return }
            await select(selection.filter, existingID: selection.streamID)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            guard pickerRegistered else { return }
            isChoosing = false
            self.error = error.localizedDescription
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor in
            guard self.stream.map(ObjectIdentifier.init) == streamID else { return }
            reset()
            self.error = error.localizedDescription
        }
    }
}

// ScreenCaptureKit returns an immutable filter. The callback hands the reference
// to the main actor, which owns all subsequent stream access.
private struct PickerSelection: @unchecked Sendable {
    let filter: SCContentFilter
    let streamID: ObjectIdentifier?
}

final class CaptureOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "PrismXR.captureFrames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let deliver: @MainActor @Sendable (CGImage) -> Void
    private let outstandingFrame = DispatchSemaphore(value: 1)

    init(deliver: @escaping @MainActor @Sendable (CGImage) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let buffer = sampleBuffer.imageBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        if let status = attachments?.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        guard outstandingFrame.wait(timeout: .now()) == .success else { return }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(source, from: source.extent) else {
            outstandingFrame.signal()
            return
        }
        Task { @MainActor [deliver, outstandingFrame] in
            deliver(image)
            outstandingFrame.signal()
        }
    }
}
