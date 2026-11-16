// SPDX-License-Identifier: GPL-3.0-or-later
// FNIRSI DPS-150 protocol: building and parsing frames. Reference — docs/PROTOCOL.md.
//   [HDR][CMD][REG][LEN][DATA x LEN][CHK],  CHK = (REG + LEN + sum(DATA)) & 0xFF
import Foundation

public let headerRX: UInt8 = 0xF0   // device -> host
public let headerTX: UInt8 = 0xF1   // host -> device

public enum Cmd {
    public static let get: UInt8 = 0xA1
    public static let baud: UInt8 = 0xB0
    public static let set: UInt8 = 0xB1
    public static let session: UInt8 = 0xC1
}

public enum Reg {
    public static let inputVoltage: UInt8 = 192    // f32
    public static let voltageSet: UInt8 = 193      // f32
    public static let currentSet: UInt8 = 194      // f32
    public static let measurement: UInt8 = 195     // 3x f32 (V, I, P)
    public static let temperature: UInt8 = 196     // f32
    public static let groupBase: UInt8 = 197       // C5..D0: M1 V, M1 I, ... M6 I
    public static let ovp: UInt8 = 209
    public static let ocp: UInt8 = 210
    public static let opp: UInt8 = 211
    public static let otp: UInt8 = 212
    public static let lvp: UInt8 = 213
    public static let brightness: UInt8 = 214      // u8
    public static let volume: UInt8 = 215          // u8
    public static let meteringEnable: UInt8 = 216  // u8
    public static let capacity: UInt8 = 217        // f32, Ah
    public static let energy: UInt8 = 218          // f32, Wh
    public static let outputEnable: UInt8 = 219    // u8, 1 = RUN
    public static let protection: UInt8 = 220      // u8
    public static let mode: UInt8 = 221            // u8, 0 = CC, 1 = CV
    public static let modelName: UInt8 = 222
    public static let hardwareVersion: UInt8 = 223
    public static let firmwareVersion: UInt8 = 224
    public static let maxVoltage: UInt8 = 226      // f32
    public static let maxCurrent: UInt8 = 227      // f32
    public static let all: UInt8 = 255
}

let protectionStates = ["", "OVP", "OCP", "OPP", "OTP", "LVP", "REP"]

// ---- building frames -----------------------------------------------------

public func checksum(_ reg: UInt8, _ payload: [UInt8]) -> UInt8 {
    payload.reduce(reg &+ UInt8(truncatingIfNeeded: payload.count), &+)
}

public func buildFrame(_ cmd: UInt8, _ reg: UInt8, _ payload: [UInt8] = [0],
                       header: UInt8 = headerTX) -> [UInt8] {
    [header, cmd, reg, UInt8(payload.count)] + payload + [checksum(reg, payload)]
}

func f32Bytes(_ v: Double) -> [UInt8] {
    withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { Array($0) }
}

/// The caller guarantees p.count >= off + 4.
func f32(_ p: [UInt8], _ off: Int = 0) -> Double {
    let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[off + $1]) << (8 * UInt32($1)) }
    return Double(Float(bitPattern: bits))
}

public func frameSet(_ reg: UInt8, float v: Double) -> [UInt8] { buildFrame(Cmd.set, reg, f32Bytes(v)) }
public func frameSet(_ reg: UInt8, byte: UInt8) -> [UInt8] { buildFrame(Cmd.set, reg, [byte]) }
public func frameGet(_ reg: UInt8) -> [UInt8] { buildFrame(Cmd.get, reg) }
public func frameSession(_ open: Bool) -> [UInt8] { buildFrame(Cmd.session, 0, [open ? 1 : 0]) }
/// Always 115200: index 5 in [9600, 19200, 38400, 57600, 115200].
public func frameBaud() -> [UInt8] { buildFrame(Cmd.baud, 0, [5]) }

// ---- parsing the stream --------------------------------------------------

public struct Frame: Equatable {
    public let cmd: UInt8
    public let reg: UInt8
    public let payload: [UInt8]
}

/// Incremental parser with resynchronization. header = headerRX for the stream
/// from the device, headerTX — for the emulator.
public final class FrameParser {
    private let header: UInt8
    private var buf: [UInt8] = []
    public private(set) var badChecksums = 0

    public init(header: UInt8 = headerRX) { self.header = header }

    public func feed(_ data: [UInt8]) -> [Frame] {
        buf += data
        var frames: [Frame] = []
        var i = 0
        while true {
            guard let start = buf[i...].firstIndex(of: header) else { i = buf.count; break }
            i = start
            guard buf.count - i >= 5 else { break }
            let cmd = buf[i + 1], reg = buf[i + 2], len = Int(buf[i + 3])
            // The device only sends F0 A1 ..., and the longest frame is the 139-byte dump.
            // Anything else is a stray header byte inside the data: skip it.
            if (header == headerRX && cmd != Cmd.get) || len > 160 { i += 1; continue }
            guard buf.count - i >= len + 5 else { break }
            let payload = Array(buf[i + 4 ..< i + 4 + len])
            if buf[i + 4 + len] != checksum(reg, payload) {
                badChecksums += 1
                i += 1
                continue
            }
            frames.append(Frame(cmd: cmd, reg: reg, payload: payload))
            i += len + 5
        }
        buf.removeFirst(i)
        return frames
    }
}

// ---- device state --------------------------------------------------------

public struct DeviceState {
    public var inputVoltage: Double?
    public var setVoltage: Double?
    public var setCurrent: Double?
    public var outVoltage: Double?
    public var outCurrent: Double?
    public var outPower: Double?
    public var temperature: Double?
    public var presets: [(v: Double, i: Double)] = []   // M1..M6, empty until the first dump
    public var ovp: Double?
    public var ocp: Double?
    public var opp: Double?
    public var otp: Double?
    public var lvp: Double?
    public var brightness: Int?
    public var volume: Int?
    public var meteringOn = false
    public var capacityAh: Double?
    public var energyWh: Double?
    public var outputOn = false
    public var protection: String?   // "" = OK
    public var mode: String?         // "CC" / "CV"
    public var model: String?
    public var hwVersion: String?
    public var fwVersion: String?
    public var maxVoltage: Double?
    public var maxCurrent: Double?
    public init() {}
}

/// What exactly the frame updated — the plot and ChargeController depend on it.
public enum UpdateKind { case measurement, capacity, dump, other }

private let floatRegs: [UInt8: WritableKeyPath<DeviceState, Double?>] = [
    Reg.inputVoltage: \.inputVoltage, Reg.voltageSet: \.setVoltage, Reg.currentSet: \.setCurrent,
    Reg.temperature: \.temperature, Reg.capacity: \.capacityAh, Reg.energy: \.energyWh,
    Reg.maxVoltage: \.maxVoltage, Reg.maxCurrent: \.maxCurrent,
    Reg.ovp: \.ovp, Reg.ocp: \.ocp, Reg.opp: \.opp, Reg.otp: \.otp, Reg.lvp: \.lvp,
]

private func protectionName(_ c: UInt8) -> String {
    c < protectionStates.count ? protectionStates[Int(c)] : "?\(c)"
}

/// Applies a frame to the state. nil — the frame is unknown or too short.
public func apply(_ f: Frame, to s: inout DeviceState) -> UpdateKind? {
    let p = f.payload
    if let kp = floatRegs[f.reg] {
        guard p.count >= 4 else { return nil }
        s[keyPath: kp] = f32(p)
        return f.reg == Reg.capacity ? .capacity : .other
    }
    switch f.reg {
    case Reg.measurement where p.count >= 12:
        s.outVoltage = f32(p, 0); s.outCurrent = f32(p, 4); s.outPower = f32(p, 8)
        return .measurement
    case Reg.all where p.count >= 119:
        applyDump(p, &s)
        return .dump
    case Reg.outputEnable where !p.isEmpty: s.outputOn = p[0] == 1
    case Reg.protection where !p.isEmpty: s.protection = protectionName(p[0])
    case Reg.mode where !p.isEmpty: s.mode = p[0] == 0 ? "CC" : "CV"
    case Reg.modelName: s.model = String(decoding: p, as: UTF8.self)
    case Reg.hardwareVersion: s.hwVersion = String(decoding: p, as: UTF8.self)
    case Reg.firmwareVersion: s.fwVersion = String(decoding: p, as: UTF8.self)
    default: return nil
    }
    return .other
}

private func applyDump(_ p: [UInt8], _ s: inout DeviceState) {
    s.inputVoltage = f32(p, 0)
    s.setVoltage = f32(p, 4)
    s.setCurrent = f32(p, 8)
    s.outVoltage = f32(p, 12)
    s.outCurrent = f32(p, 16)
    s.outPower = f32(p, 20)
    s.temperature = f32(p, 24)
    s.presets = (0..<6).map { (f32(p, 28 + $0 * 8), f32(p, 32 + $0 * 8)) }
    s.ovp = f32(p, 76)
    s.ocp = f32(p, 80)
    s.opp = f32(p, 84)
    s.otp = f32(p, 88)
    s.lvp = f32(p, 92)
    s.brightness = Int(p[96])
    s.volume = Int(p[97])
    s.meteringOn = p[98] == 1
    s.capacityAh = f32(p, 99)
    s.energyWh = f32(p, 103)
    s.outputOn = p[107] == 1
    s.protection = protectionName(p[108])
    s.mode = p[109] == 0 ? "CC" : "CV"
    s.maxVoltage = f32(p, 111)
    s.maxCurrent = f32(p, 115)
}
