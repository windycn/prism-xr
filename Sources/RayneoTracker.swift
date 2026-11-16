import Foundation
import IOKit.hid
import Observation
import simd

// Only one owner stabilizes the image: software tracking always uses follow;
// selecting an on-device mode suspends software and blocks automatic restarts.
enum RayneoViewingMode: UInt8, CaseIterable, Identifiable, Sendable {
    case steady = 2, pinned = 1, follow = 0
    var id: Self { self }
    var label: String {
        switch self { case .steady: "防抖"; case .pinned: "固定"; case .follow: "随行" }
    }
    var symbol: String {
        switch self { case .steady: "hand.raised"; case .pinned: "pin"; case .follow: "person.crop.square" }
    }
}

struct TrackingSnapshot: Sendable {
    var running = false
    var calibrated = false
    var connected = false
    var deviceOwnsTracking = false
    var modePending = false
    var requestedMode: RayneoViewingMode?
    var modeStatus = "软件空间桌面与机身模式互斥"
    var status = "连接眼镜后可启用软件头部追踪"
    var error: String?
    var reportRate = 0.0
    var reportCount = 0
    var temperature = 0.0
    var board: UInt8?
    var pose = HeadPose()
    var stationary = false
}

@MainActor
@Observable
final class RayneoTracker {
    private(set) var connected = false
    private(set) var isRunning = false
    private(set) var isCalibrated = false
    private(set) var isStationary = false
    private(set) var pose = HeadPose()
    private(set) var reportRate = 0.0
    private(set) var reportCount = 0
    private(set) var temperature = 0.0
    private(set) var board: UInt8?
    private(set) var modeChangePending = false
    private(set) var requestedMode: RayneoViewingMode?
    private(set) var usesDeviceTracking = false
    private(set) var modeStatus = "软件空间桌面与机身模式互斥"
    private(set) var status = "连接眼镜后可启用软件头部追踪"
    private(set) var error: String?
    @ObservationIgnored private(set) var input = RayneoInput()
    @ObservationIgnored private var timer: Timer?

    isolated deinit { timer?.invalidate(); input.cancel() }

    func start() {
        guard !isRunning, !modeChangePending else { return }
        usesDeviceTracking = false
        begin(mode: nil)
    }

    func startAutomatically() {
        guard !usesDeviceTracking else { return }
        start()
    }

    func switchMode(_ mode: RayneoViewingMode) {
        usesDeviceTracking = true
        begin(mode: mode)
    }

    private func begin(mode: RayneoViewingMode?) {
        timer?.invalidate()
        input.cancel()
        input = RayneoInput()
        input.start(mode: mode)
        if mode == nil { isRunning = true; isCalibrated = false; status = "切换机身为随行模式，等待设备响应…" }
        else { modeChangePending = true; isRunning = false; modeStatus = "正在请求\(mode!.label)…" }
        pose = HeadPose()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func refresh() {
        let value = input.snapshot()
        connected = value.connected
        isRunning = value.running
        isCalibrated = value.calibrated
        isStationary = value.stationary
        modeChangePending = value.modePending
        requestedMode = value.requestedMode
        if value.deviceOwnsTracking { usesDeviceTracking = true }
        status = value.status
        modeStatus = value.modeStatus
        error = value.error
        reportRate = value.reportRate
        reportCount = value.reportCount
        temperature = value.temperature
        board = value.board
        pose = value.pose
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        input.cancel()
        isRunning = false
        isCalibrated = false
        isStationary = false
        modeChangePending = false
        pose = HeadPose()
        status = "软件头部追踪已停止"
    }

    func recenter() { input.recenter() }

    func recalibrate() {
        guard isRunning else { return }
        input.recalibrate()
        isCalibrated = false
        isStationary = false
        status = "请保持静止约一秒，校准零偏和水平线"
    }
}

// All HID and fusion work is serialized on a dedicated run loop, independent
// of SwiftUI, screen capture and the main-thread event queue.
final class RayneoInput: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "PrismXR.IMU", qos: .userInteractive)
    private let lock = NSLock()
    private var value = TrackingSnapshot()
    private var cancelled = false
    private var recenterRequested = false
    private var recalibrationRequested = false
    private var fusion = OrientationFusion()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var lastTick: UInt32?
    private var clock = 0.0
    private var rateClock = 0.0
    private var rateCount = 0
    private var gyroSum = SIMD3<Double>.zero
    private var accelSum = SIMD3<Double>.zero
    private var calibrationStart = 0.0
    private var calibrationCount = 0
    private var expectedModeAck = false
    private var modeDeadline = 0.0
    private var modeOnly = false
    private var readyForIMU = false
    private var streamStartTime = 0.0
    private var lastSampleTime = 0.0

    deinit { buffer.deallocate() }

    func start(mode: RayneoViewingMode?) {
        lock.withLock {
            value.running = mode == nil
            value.modePending = mode != nil
            value.deviceOwnsTracking = mode != nil
            value.requestedMode = mode ?? .follow
            value.status = "眼镜预热中，请保持静止"
        }
        Self.queue.async { [self] in autoreleasepool { run(mode: mode) } }
    }

    func cancel() { lock.withLock { cancelled = true } }
    func recenter() { lock.withLock { recenterRequested = true } }
    func recalibrate() { lock.withLock { recalibrationRequested = true } }

    func snapshot() -> TrackingSnapshot {
        lock.withLock {
            var snapshot = value
            if snapshot.running && snapshot.calibrated {
                snapshot.pose = fusion.pose(at: ProcessInfo.processInfo.systemUptime)
                snapshot.stationary = fusion.isStationary
            }
            return snapshot
        }
    }

    private func run(mode: RayneoViewingMode?) {
        guard !lock.withLock({ cancelled }) else { return }
        modeOnly = mode != nil
        defer { closeConnection() }
        guard openConnection() else { return }
        expectedModeAck = true
        modeDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        guard send(8, (mode ?? .follow).rawValue) else { return }
        while !lock.withLock({ cancelled }) {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if expectedModeAck && ProcessInfo.processInfo.systemUptime > modeDeadline {
                lock.withLock {
                    value.running = false; value.modePending = false
                    value.error = modeOnly ? "机身模式切换未响应，请重新连接眼镜后重试。" : "未确认机身已切为随行，已停止软件追踪以避免双重固定。"
                    value.status = "设备模式指令未响应"
                }
                break
            }
            let recenter = lock.withLock { let flag = recenterRequested; recenterRequested = false; return flag }
            if recenter { lock.withLock { fusion.recenter() } }
            lock.withLock {
                if recalibrationRequested {
                    recalibrationRequested = false
                    calibrationCount = 0; gyroSum = .zero; accelSum = .zero
                    value.calibrated = false; value.stationary = false
                    value.status = "请保持静止约一秒，校准零偏和水平线"
                }
                if readyForIMU, ProcessInfo.processInfo.systemUptime - max(streamStartTime, lastSampleTime) > 1.5 {
                    value.running = false; value.calibrated = false
                    value.stationary = false
                    value.error = "姿态数据中断，已暂停软件追踪，请重新启用。"
                    value.status = "姿态数据已暂停"; cancelled = true
                }
            }
        }
    }

    private func openConnection() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x3941, kIOHIDProductIDKey: 0xaf50,
            kIOHIDPrimaryUsagePageKey: 0xff00, kIOHIDPrimaryUsageKey: 1
        ] as CFDictionary)
        self.manager = manager
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
            lock.withLock { value.running = false; value.modePending = false; value.status = "眼镜接口暂时不可用" }
            return false
        }
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<RayneoInput>.fromOpaque(context).takeUnretainedValue().consume(bytes, count: count)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let input = Unmanaged<RayneoInput>.fromOpaque(context).takeUnretainedValue()
            input.lock.withLock { input.value.connected = false; input.value.running = false; input.value.status = "眼镜已断开"; input.cancelled = true }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        lock.withLock { value.connected = true }
        return true
    }

    private func closeConnection() {
        if let device {
            if readyForIMU { _ = send(2) }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceClose(device, 0)
        }
        if let manager {
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        device = nil; manager = nil
    }

    @discardableResult private func send(_ opcode: UInt8, _ argument: UInt8 = 0) -> Bool {
        guard let device else { return false }
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x66; report[1] = opcode; report[2] = argument
        let result = report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 64) }
        if result != kIOReturnSuccess {
            lock.withLock {
                value.error = String(format: "HID 指令 0x%02x 返回 0x%08x", opcode, result)
                value.running = false; value.modePending = false; cancelled = true
            }
        }
        return result == kIOReturnSuccess
    }

    private func consume(_ pointer: UnsafeMutablePointer<UInt8>, count: Int) {
        guard count >= 64, pointer[0] == 0x99 else { return }
        if pointer[1] == 0xc8 {
            guard pointer[8] == 8 else { return }
            if expectedModeAck {
                expectedModeAck = false
                if modeOnly {
                    lock.withLock {
                        value.modePending = false
                        value.modeStatus = "机身\(value.requestedMode?.label ?? "")模式 · 软件追踪已关闭"
                        value.status = "由眼镜机身控制视角"
                        cancelled = true
                    }
                } else {
                    readyForIMU = send(1)
                    streamStartTime = ProcessInfo.processInfo.systemUptime
                    lock.withLock { value.modeStatus = "软件空间桌面接管 · 机身随行已响应" }
                }
            } else if readyForIMU {
                // Do not fight the physical mode button or silently restart later.
                lock.withLock {
                    value.running = false; value.calibrated = false; value.deviceOwnsTracking = true
                    value.pose = HeadPose(); value.requestedMode = nil
                    value.modeStatus = "机身模式已切换 · 软件追踪已退出"
                    value.status = "由眼镜机身控制视角"; cancelled = true
                }
            }
            return
        }
        guard readyForIMU, pointer[1] == 0x65 else { return }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(pointer[offset]) | UInt32(pointer[offset + 1]) << 8 | UInt32(pointer[offset + 2]) << 16 | UInt32(pointer[offset + 3]) << 24
        }
        func number(_ offset: Int) -> Double { Double(Float(bitPattern: uint32(offset))) }
        let acceleration = SIMD3(number(4), number(8), number(12))
        let gyro = SIMD3(number(16), number(20), number(24))
        guard acceleration.x.isFinite, acceleration.y.isFinite, acceleration.z.isFinite,
              gyro.x.isFinite, gyro.y.isFinite, gyro.z.isFinite,
              simd_length(acceleration) > 1, simd_length(acceleration) < 50, simd_length(gyro) < 3000 else { return }
        let tick = uint32(40)
        let step = lastTick.map { tick &- $0 }
        lastTick = tick
        guard let step, step > 0 else { return }
        let dt = Double(step) * 0.0001
        guard dt < 1 else { return }
        clock += dt
        rateCount += 1
        lock.withLock {
            lastSampleTime = ProcessInfo.processInfo.systemUptime
            value.board = pointer[2]
            value.temperature = number(28)
            if clock - rateClock >= 0.5 {
                value.reportRate = Double(rateCount) / (clock - rateClock)
                value.reportCount += rateCount
                rateCount = 0; rateClock = clock
            }
            guard clock >= 4 else { return }
            if !value.calibrated {
                if simd_length(gyro) > 4 || abs(simd_length(acceleration) - 9.81) > 1.2 {
                    calibrationCount = 0; gyroSum = .zero; accelSum = .zero
                    value.status = "请保持静止，等待校准"
                    return
                }
                if calibrationCount == 0 { calibrationStart = clock }
                calibrationCount += 1; gyroSum += gyro; accelSum += acceleration
                if clock - calibrationStart >= 0.8, calibrationCount >= 100 {
                    value.calibrated = fusion.calibrate(acceleration: accelSum / Double(calibrationCount), gyroBias: gyroSum / Double(calibrationCount))
                    value.status = value.calibrated ? "重力水平校正已启用" : "请平视前方后重试"
                }
            } else {
                fusion.update(gyro: gyro, acceleration: acceleration, dt: dt, timestamp: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
}
