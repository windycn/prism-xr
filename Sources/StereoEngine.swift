import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO

struct StereoPair: Sendable {
    let left: CGImage
    let right: CGImage
}

actor StereoEngine {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var model: MLModel?

    func readImage(_ url: URL) throws -> CGImage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280
              ] as CFDictionary) else { throw StereoError.invalidImage }
        return image
    }

    func convert(_ image: CGImage, disparity: Double) throws -> StereoPair {
        let model = try loadModel()
        let source = CIImage(cgImage: image)
        let input = try pixelBuffer(width: 518, height: 392)
        render(source, into: input)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let prediction = try model.prediction(from: features)
        guard let depth = prediction.featureValue(for: "depth")?.imageBufferValue else {
            throw StereoError.missingDepth
        }
        let map = try normalizedDepth(depth)

        let scale = min(1, 960 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        let rgb = try pixelBuffer(width: width, height: height)
        render(source, into: rgb)
        let left = try project(rgb, map: map, offset: disparity * Double(width) / 960)
        let right = try project(rgb, map: map, offset: -disparity * Double(width) / 960)
        return StereoPair(left: left, right: right)
    }

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16P6", withExtension: "mlmodelc") else {
            throw StereoError.missingModel
        }
        let loaded = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
        model = loaded
        return loaded
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw StereoError.rendering }
        return buffer
    }

    private func render(_ source: CIImage, into buffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let opaque = source.transformed(by: CGAffineTransform(scaleX: width / source.extent.width,
                                                               y: height / source.extent.height))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(opaque, to: buffer, bounds: bounds, colorSpace: colorSpace)
    }

    private struct DepthMap {
        let width: Int
        let height: Int
        let values: [Float]
    }

    private func normalizedDepth(_ buffer: CVPixelBuffer) throws -> DepthMap {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw StereoError.missingDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw StereoError.missingDepth }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        var low = Float.infinity
        var high = -Float.infinity
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let value = Float(Float16(bitPattern: row[x]))
                guard value.isFinite else { throw StereoError.missingDepth }
                values[y * width + x] = value
                low = min(low, value)
                high = max(high, value)
            }
        }
        let range = high - low
        if range > 0.00001 {
            for index in values.indices {
                values[index] = (values[index] - low) / range
            }
        } else {
            values = [Float](repeating: 0.5, count: values.count)
        }
        return DepthMap(width: width, height: height, values: values)
    }

    private func project(_ source: CVPixelBuffer, map: DepthMap, offset: Double) throws -> CGImage {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw StereoError.rendering
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(source) else { throw StereoError.rendering }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let stride = CVPixelBufferGetBytesPerRow(source)
        var pixels = [UInt32](repeating: 0, count: width * height)
        let depthX = (0..<width).map { $0 * map.width / width }
        var z = [Float](repeating: -1, count: width)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            let mapRow = y * map.height / height * map.width
            let start = y * width
            for x in 0..<width { z[x] = -1 }
            for x in 0..<width {
                let depth = map.values[mapRow + depthX[x]]
                let target = x + Int((Double(depth - 0.5) * offset).rounded())
                guard target >= 0, target < width, depth >= z[target] else { continue }
                z[target] = depth
                pixels[start + target] = row[x]
            }

            // At an occlusion, extend the background edge into the gap.
            var x = 0
            while x < width {
                if z[x] >= 0 { x += 1; continue }
                let first = x
                while x < width, z[x] < 0 { x += 1 }
                let left = first - 1
                let right = x
                let donor: Int
                if left < 0 {
                    donor = min(right, width - 1)
                } else if right == width {
                    donor = left
                } else {
                    donor = z[left] <= z[right] ? left : right
                }
                for column in first..<right {
                    pixels[start + column] = pixels[start + donor]
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let bitmapInfo: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw StereoError.rendering
        }
        return image
    }
}

enum StereoError: LocalizedError {
    case invalidImage, missingModel, missingDepth, rendering

    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取这张图片。"
        case .missingModel: "应用内缺少 Core ML 深度模型。"
        case .missingDepth: "模型没有返回可用的深度图。"
        case .rendering: "无法创建左右眼画面。"
        }
    }
}
