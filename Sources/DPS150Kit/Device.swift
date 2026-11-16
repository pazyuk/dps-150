// SPDX-License-Identifier: GPL-3.0-or-later
// DPS-150 client: a reader thread plus a serial write queue with a 50 ms pause
// between frames (as the vendor software does).
// onFrame / onError are NOT called on the main thread.
import Foundation
import os

public struct SerialError: LocalizedError {
    public let errorDescription: String?
}

/// Standard macOS localization: the key is the Russian string, the translation
/// lives in Resources/en.lproj/Localizable.strings (build_app.sh puts it into the bundle).
public func L(_ key: String, _ args: CVarArg...) -> String {
    let f = NSLocalizedString(key, comment: "")
    return args.isEmpty ? f : String(format: f, arguments: args)
}

public func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

private func errnoText() -> String { String(cString: strerror(errno)) }

/// /dev/cu.* (not tty.*: those block on open), usbmodem first.
// ponytail: the device is guessed by the "usbmodem" name, without checking VID:PID 2E3C:5740.
// If other usbmodem devices get in the way, add an IOKit lookup.
public func findPorts() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    return names.filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }
        .sorted { ($0.contains("usbmodem") ? "0" : "1") + $0 < ($1.contains("usbmodem") ? "0" : "1") + $1 }
}

public final class Device {
    public static let writeGap = 0.05

    private let fd: Int32
    private var isOpen = true
    private let onFrame: (Frame) -> Void
    private let onError: (String) -> Void
    private let txq = DispatchQueue(label: "dps150.tx")
    private let reader = DispatchGroup()
    private let st = OSAllocatedUnfairLock(initialState: (stopped: false, lastRx: monotonic()))

    /// Time of the last received byte (monotonic); before the first one — the open time.
    public var lastRx: Double { st.withLock { $0.lastRx } }
    private var stopped: Bool { st.withLock { $0.stopped } }

    public convenience init(port: String, onFrame: @escaping (Frame) -> Void,
                            onError: @escaping (String) -> Void) throws {
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError(errorDescription: errnoText()) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // read() returns 0 on the 100 ms timeout — so that the thread can finish
        withUnsafeMutableBytes(of: &t.c_cc) { $0[Int(VMIN)] = 0; $0[Int(VTIME)] = 1 }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            let msg = errnoText()
            Darwin.close(fd)
            throw SerialError(errorDescription: msg)
        }
        tcflush(fd, TCIOFLUSH)
        self.init(fd: fd, onFrame: onFrame, onError: onError)
    }

    /// An already open descriptor (the emulator socket). Device takes ownership and closes it.
    public init(fd: Int32, onFrame: @escaping (Frame) -> Void, onError: @escaping (String) -> Void) {
        // For a socket this is what VTIME is for a tty: read() releases the thread every 100 ms (EAGAIN).
        // On a tty the call fails harmlessly with ENOTSOCK.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
        self.onFrame = onFrame
        self.onError = onError

        DispatchQueue.global().async(group: reader) { [self] in readLoop() }
        send(frameSession(true))
        send(frameBaud())
        for reg in [Reg.modelName, Reg.hardwareVersion, Reg.firmwareVersion] { send(frameGet(reg)) }
        refresh()
    }

    /// Waits until everything queued has been sent (including "output off"),
    /// then closes the session and the port.
    // ponytail: no write timeout; if the device hangs and stops reading, close()
    // may hang. When the cable is pulled, write returns an error right away.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        txq.sync {
            guard !stopped else { return }
            let f = frameSession(false)
            _ = write(fd, f, f.count)
            tcdrain(fd)
        }
        st.withLock { $0.stopped = true }
        _ = reader.wait(timeout: .now() + 1)
        Darwin.close(fd)
    }

    private func fail(_ msg: String) {
        let first = st.withLock { s -> Bool in
            defer { s.stopped = true }
            return !s.stopped
        }
        if first { onError(msg) }
    }

    private func readLoop() {
        let parser = FrameParser()
        var buf = [UInt8](repeating: 0, count: 256)
        while !stopped {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                fail(L("Ошибка чтения: %@", errnoText()))   // cable pulled out and the like
                return
            }
            if n == 0 { continue }
            st.withLock { $0.lastRx = monotonic() }
            parser.feed(Array(buf[..<n])).forEach(onFrame)
        }
    }

    // ---- commands ------------------------------------------------------------

    public func send(_ frame: [UInt8]) {
        txq.async { [self] in
            guard !stopped else { return }
            if write(fd, frame, frame.count) != frame.count {
                fail(L("Ошибка записи: %@", errnoText()))
                return
            }
            Thread.sleep(forTimeInterval: Self.writeGap)
        }
    }

    public func refresh() { send(frameGet(Reg.all)) }

    /// Writes a register and immediately requests a dump, as the vendor software does.
    public func set(_ reg: UInt8, _ value: Double) { send(frameSet(reg, float: value)); refresh() }
    public func set(_ reg: UInt8, byte: UInt8) { send(frameSet(reg, byte: byte)); refresh() }

    public func setVoltage(_ v: Double) { set(Reg.voltageSet, v) }
    public func setCurrent(_ a: Double) { set(Reg.currentSet, a) }
    public func setOutput(_ on: Bool) { set(Reg.outputEnable, byte: on ? 1 : 0) }
    public func setMetering(_ on: Bool) { set(Reg.meteringEnable, byte: on ? 1 : 0) }

    /// n = 1...6
    public func setPreset(_ n: Int, v: Double, a: Double) {
        let reg = Reg.groupBase + UInt8((n - 1) * 2)
        send(frameSet(reg, float: v))
        send(frameSet(reg + 1, float: a))
        refresh()
    }
}
