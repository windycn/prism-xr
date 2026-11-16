import Foundation
import CoreGraphics

struct CursorScreen {
    let displayID: UInt32
    let bounds: CGRect
    let sceneBounds: CGRect
}

struct CursorTransfer {
    let displayID: UInt32
    let point: CGPoint
}

enum SpatialCursorRouter {
    static func fenceOutput(point: CGPoint, output: CGRect, screens: [CursorScreen], lastSafe: CGPoint?) -> CGPoint? {
        guard !output.isEmpty, output.contains(point),
              !screens.contains(where: { $0.bounds.contains(point) }) else { return nil }
        if let lastSafe, screens.contains(where: { $0.bounds.insetBy(dx: 3, dy: 3).contains(lastSafe) }) { return lastSafe }
        guard let nearest = screens.min(by: {
            hypot($0.bounds.midX - point.x, $0.bounds.midY - point.y) < hypot($1.bounds.midX - point.x, $1.bounds.midY - point.y)
        }) else { return nil }
        return CGPoint(x: min(nearest.bounds.maxX - 5, max(nearest.bounds.minX + 5, point.x)),
                       y: min(nearest.bounds.maxY - 5, max(nearest.bounds.minY + 5, point.y)))
    }

    static func transfer(previous: CGPoint, current: CGPoint, screens: [CursorScreen]) -> CursorTransfer? {
        guard let source = screens.first(where: { $0.bounds.contains(previous) }) else { return nil }
        let rect = source.bounds
        let dx = current.x - previous.x, dy = current.y - previous.y
        var direction = CGPoint.zero
        var crossing = current
        if !rect.contains(current) {
            var exits: [(CGFloat, CGPoint)] = []
            if dx < 0 { exits.append(((rect.minX - previous.x) / dx, CGPoint(x: -1, y: 0))) }
            if dx > 0 { exits.append(((rect.maxX - previous.x) / dx, CGPoint(x: 1, y: 0))) }
            if dy < 0 { exits.append(((rect.minY - previous.y) / dy, CGPoint(x: 0, y: -1))) }
            if dy > 0 { exits.append(((rect.maxY - previous.y) / dy, CGPoint(x: 0, y: 1))) }
            guard let exit = exits.filter({ $0.0 >= 0 && $0.0 <= 1 }).min(by: { $0.0 < $1.0 }) else { return nil }
            direction = exit.1
            crossing = CGPoint(x: previous.x + dx * exit.0, y: previous.y + dy * exit.0)
        } else if current.x <= rect.minX + 2 && dx < 0 { direction.x = -1 }
        else if current.x >= rect.maxX - 3 && dx > 0 { direction.x = 1 }
        else if current.y <= rect.minY + 2 && dy < 0 { direction.y = -1 }
        else if current.y >= rect.maxY - 3 && dy > 0 { direction.y = 1 }
        else { return nil }
        let scenePoint = CGPoint(x: source.sceneBounds.minX + (crossing.x - rect.minX) / rect.width * source.sceneBounds.width,
                                 y: source.sceneBounds.minY + (crossing.y - rect.minY) / rect.height * source.sceneBounds.height)
        let candidates = screens.compactMap { candidate -> (CursorScreen, CGFloat)? in
            guard candidate.displayID != source.displayID else { return nil }
            let delta = CGPoint(x: candidate.sceneBounds.midX - source.sceneBounds.midX,
                                y: candidate.sceneBounds.midY - source.sceneBounds.midY)
            let forward = delta.x * direction.x + delta.y * direction.y
            guard forward > 0.01 else { return nil }
            let side = direction.x != 0
                ? max(0, candidate.sceneBounds.minY - scenePoint.y, scenePoint.y - candidate.sceneBounds.maxY)
                : max(0, candidate.sceneBounds.minX - scenePoint.x, scenePoint.x - candidate.sceneBounds.maxX)
            return (candidate, forward + side * 3)
        }
        guard let destination = candidates.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        // If macOS has already crossed into the correct neighbor, keep its
        // natural pointer movement. Correct transitions into a wrong neighbor.
        if destination.bounds.contains(current) { return nil }
        let xFraction = min(1, max(0, (scenePoint.x - destination.sceneBounds.minX) / destination.sceneBounds.width))
        let yFraction = min(1, max(0, (scenePoint.y - destination.sceneBounds.minY) / destination.sceneBounds.height))
        let target = destination.bounds
        return CursorTransfer(displayID: destination.displayID, point: CGPoint(
            x: direction.x > 0 ? target.minX + 5 : direction.x < 0 ? target.maxX - 5 : target.minX + xFraction * target.width,
            y: direction.y > 0 ? target.minY + 5 : direction.y < 0 ? target.maxY - 5 : target.minY + yFraction * target.height))
    }
}
