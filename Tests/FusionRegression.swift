import Foundation
import simd

@main enum FusionRegression {
    static func main() {
        var drift = OrientationFusion()
        let g = SIMD3<Double>(0, 0, 9.81)
        precondition(drift.calibrate(acceleration: g, gyroBias: .zero))
        let dt = 1.0 / 472
        var t = 0.0
        for _ in 0..<56640 {
            t += dt
            drift.update(gyro: SIMD3(0.08, -0.06, 0), acceleration: g, dt: dt, timestamp: t)
        }
        let level = drift.pose(at: t, prediction: false)
        precondition(abs(level.roll) < 0.1 && abs(level.pitch) < 0.1, "tilt drift \(level)")
        var turning = OrientationFusion()
        precondition(turning.calibrate(acceleration: g, gyroBias: .zero))
        t = 0
        for _ in 0..<472 { t += dt; turning.update(gyro: SIMD3(0, 0, 30), acceleration: g, dt: dt, timestamp: t) }
        let yaw = turning.pose(at: t, prediction: false).yaw
        precondition(abs(yaw + 30) < 0.1, "wrong yaw sign/magnitude \(yaw)")
        turning.update(gyro: .zero, acceleration: g, dt: 0.2, timestamp: t + 0.2)
        let afterGap = turning.pose(at: t + 0.2, prediction: false).yaw
        precondition(abs(yaw - afterGap) < 1e-8, "gap recentered")
        turning.recenter()
        let centered = turning.pose(at: t + 0.2, prediction: false).yaw
        precondition(abs(centered) < 1e-7, "recenter \(centered)")
        var moving = OrientationFusion()
        precondition(moving.calibrate(acceleration: g, gyroBias: .zero))
        var truth = simd_quatd(real: 1, imag: .zero); t = 0
        for _ in 0..<472 {
            t += dt
            truth = truth * simd_quatd(angle: 20 * .pi / 180 * dt, axis: SIMD3(1, 0, 0))
            moving.update(gyro: SIMD3(20, 0, 0), acceleration: truth.inverse.act(g), dt: dt, timestamp: t)
        }
        let roll = moving.pose(at: t, prediction: false).roll
        precondition(abs(abs(roll) - 20) < 0.2, "gravity fights real roll \(roll)")
        var stationary = OrientationFusion()
        precondition(stationary.calibrate(acceleration: g, gyroBias: .zero))
        t = 0
        var firstYaw = 0.0
        for index in 0..<56640 {
            t += dt
            stationary.update(gyro: SIMD3(0, 0, 0.12), acceleration: g, dt: dt, timestamp: t)
            if index == 14160 { firstYaw = stationary.pose(at: t, prediction: false).yaw }
        }
        let held = stationary.pose(at: t, prediction: false).yaw
        precondition(abs(held - firstYaw) < 0.001, "stationary yaw drift")
        for _ in 0..<472 {
            t += dt
            stationary.update(gyro: SIMD3(0, 0, 10.12), acceleration: g, dt: dt, timestamp: t)
        }
        let resumed = stationary.pose(at: t, prediction: false).yaw
        precondition(abs(resumed - held + 10) < 0.15, "stationary exit jump \(resumed - held)")
        var slow = OrientationFusion()
        precondition(slow.calibrate(acceleration:g,gyroBias:.zero))
        t = 0
        for _ in 0..<472 { t += dt; slow.update(gyro:.zero,acceleration:g,dt:dt,timestamp:t) }
        for _ in 0..<944 { t += dt; slow.update(gyro:SIMD3(0,0,0.5),acceleration:g,dt:dt,timestamp:t) }
        let slowYaw = slow.pose(at:t,prediction:false).yaw
        precondition(abs(slowYaw + 1) < 0.02, "slow turn swallowed by stationary hold")
        print("PASS stationary hold releases for a deliberate 0.5 degree/second turn")
        print("PASS stationary heading: no accumulated drift from 30 to 120 seconds; motion resumes smoothly")
        print("PASS synthetic 120-second tilt drift: roll=\(level.roll), pitch=\(level.pitch)")
        print("PASS true yaw=\(yaw), true roll=\(roll), gap retained, recenter=\(centered)")
    }
}
