import Foundation
import simd

struct HeadPose: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
}

// Body-to-reference quaternion. Gravity corrects tilt without inventing an
// absolute magnetic heading; stationary bias tracking compensates thermal drift.
struct OrientationFusion: Sendable {
    private(set) var attitude = simd_quatd(real: 1, imag: .zero)
    private(set) var basis = simd_quatd(real: 1, imag: .zero)
    private(set) var bias = SIMD3<Double>.zero
    private var referenceUp = SIMD3<Double>(0, 1, 0)
    private var previousAcceleration = SIMD3<Double>.zero
    private var stillTime = 0.0
    private var stationaryYaw: Double?
    private var velocity = SIMD3<Double>.zero
    private var sampleTime = 0.0
    private var reference = simd_quatd(real: 1, imag: .zero)
    var isStationary: Bool { stationaryYaw != nil }

    mutating func calibrate(acceleration: SIMD3<Double>, gyroBias: SIMD3<Double>) -> Bool {
        guard simd_length(acceleration) > 1 else { return false }
        let up = simd_normalize(acceleration)
        let candidate = SIMD3<Double>(1, 0, 0)
        let projected = candidate - up * simd_dot(candidate, up)
        guard simd_length(projected) > 0.1 else { return false }
        let forward = simd_normalize(projected)
        let right = simd_normalize(simd_cross(forward, up))
        basis = simd_quatd(simd_double3x3(columns: (right, up, -forward)))
        referenceUp = up
        attitude = simd_quatd(real: 1, imag: .zero)
        reference = simd_quatd(real: 1, imag: .zero)
        bias = gyroBias
        previousAcceleration = acceleration
        velocity = .zero
        stillTime = 0
        stationaryYaw = nil
        return true
    }

    mutating func update(gyro: SIMD3<Double>, acceleration: SIMD3<Double>, dt: Double, timestamp: Double) {
        // A missing packet does not recenter or integrate a long stale velocity.
        guard dt > 0, dt <= 0.025 else { velocity = .zero; sampleTime = timestamp; stillTime = 0; return }
        let magnitude = simd_length(acceleration)
        let gravityReliable = abs(magnitude - 9.81) < 0.75
        let quietAcceleration = simd_length(acceleration - previousAcceleration) < 0.35
        previousAcceleration = acceleration
        let residual = gyro - bias
        let stillThreshold = stationaryYaw == nil ? 0.35 : 0.45
        if gravityReliable && quietAcceleration && simd_length(residual) < stillThreshold {
            stillTime += dt
            if stillTime > 1 {
                bias += residual * (1 - exp(-dt / 4))
            }
            if stillTime > 0.6, stationaryYaw == nil {
                stationaryYaw = angles(at: timestamp, prediction: false).yaw
            }
        } else {
            stillTime = 0
            if let heldYaw = stationaryYaw {
                let actual = angles(at: timestamp, prediction: false).yaw
                reference = simd_quatd(angle: (actual - heldYaw) * .pi / 180, axis: SIMD3(0, 1, 0)) * reference
                stationaryYaw = nil
            }
        }
        velocity = stationaryYaw == nil ? (gyro - bias) * (.pi / 180) : .zero
        var corrected = velocity
        if gravityReliable {
            let measuredUp = acceleration / magnitude
            let predictedUp = attitude.inverse.act(referenceUp)
            // Reject acceleration whose direction is inconsistent with gravity.
            if simd_dot(measuredUp, predictedUp) > cos(25 * .pi / 180) {
                corrected += simd_cross(measuredUp, predictedUp) * 1.2
            }
        }
        let speed = simd_length(corrected)
        if speed > 1e-10 {
            attitude = simd_normalize(attitude * simd_quatd(angle: speed * dt, axis: corrected / speed))
        }
        sampleTime = timestamp
    }

    mutating func recenter() {
        // Keep gravity level; only yaw is recentered immediately.
        let relative = basis.inverse * attitude * basis
        let forward = relative.act(SIMD3<Double>(0, 0, -1))
        let yaw = atan2(forward.x, -forward.z)
        reference = simd_quatd(angle: yaw, axis: SIMD3<Double>(0, 1, 0))
        if stationaryYaw != nil { stationaryYaw = 0 }
    }

    func pose(at now: Double, prediction: Bool = true) -> HeadPose {
        var pose = angles(at: now, prediction: prediction)
        if let stationaryYaw { pose.yaw = stationaryYaw }
        return pose
    }

    private func angles(at now: Double, prediction: Bool) -> HeadPose {
        let horizon = prediction ? min(0.012, max(0, now - sampleTime + 0.004)) : 0
        let speed = simd_length(velocity)
        let predicted = speed > 1e-10
            ? attitude * simd_quatd(angle: speed * horizon, axis: velocity / speed) : attitude
        let relative = reference * basis.inverse * predicted * basis
        let forward = relative.act(SIMD3<Double>(0, 0, -1))
        let up = relative.act(SIMD3<Double>(0, 1, 0))
        return HeadPose(yaw: atan2(forward.x, -forward.z) * 180 / .pi,
                        pitch: -asin(min(1, max(-1, forward.y))) * 180 / .pi,
                        roll: atan2(up.x, up.y) * 180 / .pi)
    }
}
