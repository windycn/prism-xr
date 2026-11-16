import Foundation
@main enum TrackerRegression {
    static func main() {
        let input = RayneoInput()
        input.start(mode: nil)
        let start = ProcessInfo.processInfo.systemUptime
        var readings = [HeadPose]()
        while ProcessInfo.processInfo.systemUptime - start < 12 {
            Thread.sleep(forTimeInterval: 0.1)
            let state = input.snapshot()
            if state.calibrated { readings.append(state.pose) }
        }
        let result = input.snapshot()
        print("LIVE connected=\(result.connected) running=\(result.running) calibrated=\(result.calibrated) samples=\(result.reportCount) Hz=\(result.reportRate)")
        print("MODE \(result.modeStatus), status=\(result.status), error=\(result.error ?? "none")")
        print("POSE \(result.pose), calibratedReadings=\(readings.count)")
        input.cancel()
        Thread.sleep(forTimeInterval: 0.1)
    }
}
