// SPDX-License-Identifier: GPL-3.0-or-later
// DPS-150 emulator on a socketpair — for demo mode and tests (a pty will not do:
// tcsetattr on it is forbidden in the App Store sandbox). A Li-ion cell is
// "connected" to the output, so CC/CV and the end of charge behave roughly
// like in real life (time runs `speedup` times faster).
import Foundation

public final class FakeDPS150 {
    /// Client end for `Device(fd:)`; Device closes it.
    public let clientFD: Int32
    private let master: Int32
    private let q = DispatchQueue(label: "dps150.fake")
    private let timer: DispatchSourceTimer
    private let rx: DispatchSourceRead
    private let parser = FrameParser(header: headerTX)
    private var closed = false

    private let speedup: Double
    private let cap: Double
    private var soc: Double
    private let rInt = 0.12
    private let vin = 20.4
    private let temp = 27.0
    private var vset = 5.0
    private var iset = 1.0
    private var outOn = false
    private var metering = false
    private var ah = 0.0
    private var wh = 0.0
    private var presets: [(Double, Double)] = [(3.3, 1), (5, 1), (9, 1), (12, 1), (4.2, 0.5), (3.6, 0.5)]
    private var prot: [UInt8: Double] = [Reg.ovp: 31, Reg.ocp: 5.2, Reg.opp: 155, Reg.otp: 80, Reg.lvp: 4.5]
    private var brightness: UInt8 = 10
    private var volume: UInt8 = 5
    private var v = 0.0
    private var i = 0.0
    private var mode: UInt8 = 1
    private var last = monotonic()

    public var outputOn: Bool { q.sync { outOn } }

    public init(speedup: Double = 60, cellCapacityAh: Double = 0.8, startSoc: Double = 0.15) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair")
        master = fds[0]
        clientFD = fds[1]
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.speedup = speedup
        cap = cellCapacityAh
        soc = startSoc
        timer = DispatchSource.makeTimerSource(queue: q)
        rx = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)

        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [unowned self] in tick() }
        rx.setEventHandler { [unowned self] in
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(master, &buf, buf.count)
            if n > 0 { parser.feed(Array(buf[..<n])).forEach(handle) }
        }
        timer.resume()
        rx.resume()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        timer.cancel()
        rx.cancel()
        q.sync {}
        Darwin.close(master)
    }

    deinit { close() }

    // ---- cell model ----------------------------------------------------------

    private func ocv() -> Double {
        let s = max(0, min(1, soc))
        return 3.0 + 0.55 * pow(s, 0.35) + 0.65 * pow(s, 2.2)
    }

    private func physics(_ dt: Double) {
        guard outOn else { v = 0; i = 0; mode = 1; return }
        let ocv = ocv()
        let iCV = max(0, (vset - ocv) / rInt)
        if iCV >= iset { i = iset; mode = 0 } else { i = iCV; mode = 1 }
        v = ocv + i * rInt
        let dah = i * dt * speedup / 3600
        soc += dah / cap
        if metering { ah += dah; wh += dah * v }
    }

    // ---- I/O -----------------------------------------------------------------

    private func send(_ reg: UInt8, _ payload: [UInt8]) {
        let f = buildFrame(Cmd.get, reg, payload, header: headerRX)
        _ = write(master, f, f.count)   // buffer full (nobody is reading) — the frame is dropped, and that is fine
    }

    private func fb(_ vals: Double...) -> [UInt8] { vals.flatMap(f32Bytes) }

    private func tick() {
        let now = monotonic()
        physics(now - last)
        last = now
        send(Reg.inputVoltage, fb(vin))
        send(Reg.measurement, fb(v, i, v * i))
        send(Reg.temperature, fb(temp))
        send(Reg.mode, [mode])
        if outOn && metering {
            send(Reg.capacity, fb(ah))
            send(Reg.energy, fb(wh))
        }
    }

    private func dump() -> [UInt8] {
        var b = fb(vin, vset, iset, v, i, v * i, temp)
        for (pv, pa) in presets { b += fb(pv, pa) }
        b += [Reg.ovp, Reg.ocp, Reg.opp, Reg.otp, Reg.lvp].flatMap { fb(prot[$0]!) }
        b += [brightness, volume, metering ? 1 : 0]
        b += fb(ah, wh)
        b += [outOn ? 1 : 0, 0, mode, 0]
        b += fb(vin - 0.2, 5.1, 0, 0, 0, 0, 0)
        return b
    }

    private func handle(_ fr: Frame) {
        let t = fr.reg, p = fr.payload
        if fr.cmd == Cmd.get {
            switch t {
            case Reg.all: send(t, dump())
            case Reg.modelName: send(t, Array("DPS-150".utf8))
            case Reg.hardwareVersion: send(t, Array("V1.0".utf8))
            case Reg.firmwareVersion: send(t, Array("V1.0 (emu)".utf8))
            default: break
            }
            return
        }
        guard fr.cmd == Cmd.set, let b = p.first else { return }
        let f = p.count == 4 ? f32(p) : 0
        switch t {
        case Reg.voltageSet: vset = f
        case Reg.currentSet: iset = f
        case Reg.outputEnable:
            outOn = b == 1
            send(t, [b])
        case Reg.meteringEnable:
            metering = b == 1
            if metering { ah = 0; wh = 0 }
        case Reg.brightness: brightness = b
        case Reg.volume: volume = b
        case Reg.groupBase ..< Reg.groupBase + 12:
            let k = Int(t - Reg.groupBase)
            if k % 2 == 0 { presets[k / 2].0 = f } else { presets[k / 2].1 = f }
        default:
            if prot[t] != nil { prot[t] = f }
        }
    }
}
