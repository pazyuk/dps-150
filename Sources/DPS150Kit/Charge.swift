// SPDX-License-Identifier: GPL-3.0-or-later
// CC/CV charging with automatic cutoff. The supply itself holds CC/CV; we watch
// the telemetry and switch the output off once the CV current stays below the
// cutoff for 10 s in a row (or on timeout / protection / overvoltage). For NiMH,
// which has no CC/CV cutoff, also on the accumulated capacity (maxMah).
// Not thread-safe: all calls come from one thread (the main one in the app).
// Do not weaken the emergency stops.
import Foundation

public func fmtDur(_ sec: Double) -> String {
    let s = Int(max(0, sec))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

public final class ChargeController {
    public var onStatus: (String) -> Void = { _ in }
    public var onFinished: (_ message: String, _ success: Bool) -> Void = { _, _ in }
    public private(set) var active = false

    private var dev: Device?
    private var targetV = 0.0
    private var cutoff = 0.0
    private var maxS = 0.0
    private var maxMah: Double?
    private var t0 = 0.0
    private var belowSince: Double?
    private var noCurrentSince: Double?
    private var ah0: Double?
    private var lastAh = 0.0
    private var peakI = 0.0

    public init() {}

    /// maxMah — normal stop on accumulated capacity (nil — not used).
    public func start(dev: Device, meteringOn: Bool, v: Double, i: Double,
                      cutoff: Double, maxMin: Double, maxMah: Double? = nil) {
        self.dev = dev
        self.maxMah = maxMah
        targetV = v
        self.cutoff = cutoff
        maxS = maxMin * 60
        belowSince = nil
        noCurrentSince = nil
        ah0 = nil
        lastAh = 0
        peakI = 0
        active = true
        t0 = monotonic()
        dev.setOutput(false)
        dev.setVoltage(v)
        dev.setCurrent(i)
        if !meteringOn { dev.setMetering(true) }
        dev.setOutput(true)
        onStatus(L("Заряд: %.2f В / %.3f А, стоп при < %.0f мА", v, i, cutoff * 1000))
    }

    public func stop(_ msg: String, ok: Bool) {
        guard active else { return }
        active = false
        dev?.setOutput(false)
        dev = nil
        onFinished(msg, ok)
    }

    public var chargedMah: Double {
        ah0.map { max(0, (lastAh - $0) * 1000) } ?? 0
    }

    /// Call after every applied frame.
    public func onUpdate(_ s: DeviceState, _ kind: UpdateKind) {
        guard active else { return }
        let now = monotonic()
        let el = now - t0
        if kind == .capacity || kind == .dump, let ah = s.capacityAh {
            lastAh = ah
            if ah0 == nil { ah0 = ah }   // count from the first value: a counter reset does not matter
        }
        guard kind == .measurement || kind == .dump,
              let v = s.outVoltage, let i = s.outCurrent else { return }
        if el < 2.0 { return }   // let the output settle
        if let prot = s.protection, !prot.isEmpty {
            return stop(L("Сработала защита %@, заряд остановлен", prot), ok: false)
        }
        if !s.outputOn && el > 4.0 {
            return stop(L("Выход выключили вручную — заряд прерван"), ok: false)
        }
        peakI = max(peakI, i)
        if v > targetV + 0.15 {
            return stop(L("Напряжение %.2f В выше цели — аварийный стоп", v), ok: false)
        }
        if el > maxS {
            return stop(L("Таймаут %@, заряд остановлен", fmtDur(maxS)), ok: false)
        }
        if let maxMah, chargedMah >= maxMah {
            return stop(L("Заряжено: %.0f мА·ч за %@ (стоп по ёмкости)", chargedMah, fmtDur(el)), ok: true)
        }
        // No current at all: the cell is not connected or is already charged.
        if i < 0.005 {
            let since = noCurrentSince ?? now
            noCurrentSince = since
            if now - since > 8 && peakI < 0.01 {
                return stop(L("Ток не пошёл: банка не подключена или уже заряжена"), ok: false)
            }
        } else {
            noCurrentSince = nil
        }
        let cv = s.mode == "CV"
        if cv && i < cutoff && peakI >= 0.01 {
            let since = belowSince ?? now
            belowSince = since
            let left = 10 - (now - since)
            if left <= 0 {
                return stop(L("Заряжено: %.0f мА·ч за %@", chargedMah, fmtDur(el)), ok: true)
            }
            onStatus(L("CV, ток %.0f мА < порога — стоп через %.0f с", i * 1000, left))
        } else {
            belowSince = nil
            let phase = cv ? L("CV (ток падает)") : L("CC (постоянный ток)")
            onStatus(L("%@ · %@ · %.0f мА·ч", phase, fmtDur(el), chargedMah))
        }
    }
}
