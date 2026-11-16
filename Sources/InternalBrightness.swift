import AppKit
import Darwin
import Observation

// The helper retains the original value and restores it when the UI exits,
// the control pipe closes, or the selected output disappears.
enum BrightnessKeeper {
    typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Setter = @convention(c) (UInt32, Float) -> Int32

    static func run() {
        guard CommandLine.arguments.count == 5,
              let output = UInt32(CommandLine.arguments[4]),
              let display = UInt32(CommandLine.arguments[2]),
              let parent = Int32(CommandLine.arguments[3]),
              let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let getPointer = dlsym(handle, "DisplayServicesGetBrightness"),
              let setPointer = dlsym(handle, "DisplayServicesSetBrightness") else { report("error"); return }
        defer { dlclose(handle) }
        let get = unsafeBitCast(getPointer, to: Getter.self)
        let set = unsafeBitCast(setPointer, to: Setter.self)
        var original: Float = 0
        guard CGDisplayIsBuiltin(display) != 0, get(display, &original) == 0,
              original.isFinite, original >= 0, original <= 1 else { report("error"); return }
        let queue = kqueue()
        guard queue >= 0 else { report("error"); return }
        defer { close(queue) }
        var changes = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE),
                   fflags: UInt32(NOTE_EXIT), data: 0, udata: nil),
            kevent(ident: UInt(STDIN_FILENO), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_ENABLE),
                   fflags: 0, data: 0, udata: nil)
        ]
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) >= 0,
              getppid() == parent, CGDisplayIsOnline(output) != 0, set(display, 0) == 0 else { report("error"); return }
        report("dimmed", value: original)
        var event = kevent()
        while true {
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            let result = kevent(queue, nil, 0, &event, 1, &timeout)
            if result > 0 || (result < 0 && errno != EINTR) || CGDisplayIsOnline(output) == 0 || getppid() != parent { break }
        }
        let restored = set(display, original) == 0
        report(restored ? "restored" : "restore-error", value: original)
    }

    private static func report(_ status: String, value: Float? = nil) {
        var object: [String: Any] = ["status": status]
        if let value { object["original"] = value }
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }


}

@MainActor
@Observable
final class InternalBrightness {
    private(set) var isDimmed = false
    private(set) var isChanging = false
    private(set) var error: String?
    private var helper: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var received = ""

    func dim(output outputDisplay: CGDirectDisplayID) {
        guard helper == nil else { return }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success,
              let display = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let executable = Bundle.main.executableURL else {
            error = "未找到可调节亮度的 Mac 内屏。"
            return
        }
        error = nil
        isChanging = true
        received = ""
        let helper = Process()
        let input = Pipe()
        let output = Pipe()
        helper.executableURL = executable
        helper.arguments = ["--brightness-keeper", String(display), String(getpid()), String(outputDisplay)]
        helper.standardInput = input
        helper.standardOutput = output
        helper.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        helper.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.output?.fileHandleForReading.readabilityHandler = nil
                self?.helper = nil
                self?.input = nil
                self?.output = nil
                self?.isDimmed = false
                self?.isChanging = false
            }
        }
        self.helper = helper
        self.input = input
        self.output = output
        do {
            try helper.run()
        } catch {
            self.helper = nil
            self.input = nil
            self.output = nil
            isChanging = false
            self.error = error.localizedDescription
        }
    }

    func restore() {
        guard helper != nil else { return }
        isChanging = true
        try? input?.fileHandleForWriting.write(contentsOf: Data("restore\n".utf8))
        try? input?.fileHandleForWriting.close()
        input = nil
    }

    private func consume(_ data: Data) {
        received += String(decoding: data, as: UTF8.self)
        while let newline = received.firstIndex(of: "\n") {
            let line = String(received[..<newline])
            received.removeSubrange(...newline)
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String else { continue }
            switch status {
            case "dimmed": isDimmed = true; isChanging = false
            case "restored": isDimmed = false; isChanging = false
            case "restore-error": error = "自动恢复亮度失败，请使用键盘调节内屏亮度。"
            default: error = "系统未允许调节内屏亮度。"; isChanging = false
            }
        }
    }
}
