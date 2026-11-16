// SPDX-License-Identifier: GPL-3.0-or-later
// App state: device connection, plot, CSV, charging.
// Everything lives on the main thread; frames from Device are forwarded via main.async.
import AppKit
import DPS150Kit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

let appName = "DPS-150 Control"
let demoPort = "__demo__"

/// Battery chemistry on the charger screen: profiles, currents, thresholds and warnings depend on it.
struct Chemistry {
    let name: String
    /// Target-voltage profiles (v == nil — "Custom"). Empty — NiMH: the voltage limit
    /// is derived from the cell count, and the charge ends on accumulated capacity.
    let profiles: [(name: String, v: Double?)]
    let rates: [(name: String, c: Double)]
    let defRate: Int       // index into rates
    let cutC: Double       // end-of-charge threshold in CV, as a fraction of capacity
    let maxV: Double       // for the "Custom" profile: above this we ask again
    let maxMin: Double     // default timeout
    let note: String
    var experimental = false   // never tested on a real battery — show a notice
}

let nimhCellV = 1.6        // per-cell voltage limit for NiMH (at 0.1C a cell never reaches it)
let nimhOvercharge = 1.5   // standard NiMH charge: 0.1C × 15 h = 150 % of capacity

private let liRates: [(name: String, c: Double)] =
    [("0.2C (бережно)", 0.2), ("0.5C (стандарт)", 0.5), ("0.7C", 0.7), ("1C (быстро)", 1.0)]

let chemistries: [Chemistry] = [
    Chemistry(name: "Li-ion",
              profiles: [("Li-ion 4.20 В (полный заряд)", 4.20), ("Li-ion 4.10 В (щадящий)", 4.10),
                         ("Li-ion 3.80 В (хранение)", 3.80), ("Свой", nil)],
              rates: liRates, defRate: 1, cutC: 0.1, maxV: 4.2, maxMin: 240,
              note: "⚠ Одна Li-ion банка, не выше 4.2 В. Сборки из нескольких банок — только с платой балансировки. LiFePO4 заряжайте на своей вкладке."),
    Chemistry(name: "LiFePO4",
              profiles: [("LiFePO4 3.60 В", 3.60), ("LiFePO4 3.45 В (щадящий)", 3.45), ("Свой", nil)],
              rates: liRates, defRate: 1, cutC: 0.1, maxV: 3.65, maxMin: 240,
              note: "⚠ Одна LiFePO4 (IFR) банка, не выше 3.65 В. Сборки из нескольких банок — только с платой балансировки."),
    Chemistry(name: "NiMH", profiles: [],
              rates: [("0.1C (стандарт)", 0.1)], defRate: 0, cutC: 0.02, maxV: 0, maxMin: 990,
              note: "⚠ NiMH не заряжают по CC/CV. Здесь — стандартный медленный заряд током 0.1C: стоп по набранной ёмкости (150 %) и по таймеру. Ставьте на заряд разряженные банки — счёт идёт от нуля. Быстрый заряд с −ΔV не поддерживается.", experimental: true),
    Chemistry(name: "Свинцовые",
              profiles: [("6 В — 7.20 В", 7.20), ("12 В — 14.40 В", 14.40), ("12 В гелевый — 14.10 В", 14.10),
                         ("Свой", nil)],
              rates: [("0.1C (стандарт)", 0.1), ("0.2C", 0.2), ("0.3C (быстро)", 0.3)],
              defRate: 0, cutC: 0.03, maxV: 14.7, maxMin: 1440,
              note: "⚠ Свинцовые 6 и 12 В (AGM, гелевые, с жидким электролитом). Заряжайте в проветриваемом месте. Входное напряжение прибора должно быть выше конечного. После отсечки выход выключается, поддерживающего заряда нет.", experimental: true),
]

struct Sample: Identifiable {
    let t: Double
    let v: Double
    let i: Double
    let p: Double
    var id: Double { t }
}

/// danger: the default button (Return) is "No".
func confirm(_ text: String, danger: Bool = false) -> Bool {
    let a = NSAlert()
    a.messageText = appName
    a.informativeText = text
    a.addButton(withTitle: danger ? L("Нет") : L("Да"))
    a.addButton(withTitle: danger ? L("Да") : L("Нет"))
    return (a.runModal() == .alertFirstButtonReturn) != danger
}

func alert(_ text: String) {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = appName
    a.informativeText = text
    a.runModal()
}

// In the built .app — UNUserNotificationCenter (the only way in the App Store sandbox);
// authorization is requested on launch, foreground presentation is in AppDelegate.
// Without a bundle (swift run) UNUserNotificationCenter crashes, so there — osascript.
func notify(_ text: String) {
    if Bundle.main.bundleIdentifier != nil {
        let n = UNMutableNotificationContent()
        n.title = appName
        n.body = text
        n.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv",
                   "-e", "display notification (item 1 of argv) with title \"\(appName)\" sound name \"Glass\"",
                   "-e", "end run", text]
    try? p.run()
}

private func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

private func savePanel(_ title: String, _ name: String) -> URL? {
    let p = NSSavePanel()
    p.title = title
    p.nameFieldStringValue = name
    p.allowedContentTypes = [.commaSeparatedText]
    p.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    return p.runModal() == .OK ? p.url : nil
}

@Observable final class AppModel {
    static let shared = AppModel()
    static let maxPoints = 250_000

    var ports: [String] = []
    var port = ""
    var connected = false
    var connLabel = L("Не подключено")
    var connColor = cDim
    var status = L("Готово")
    var state = DeviceState()
    var outOnSince: Double?

    // input fields
    var spV = 5.0
    var spI = 1.0
    var protEdit: [UInt8: Double] = [:]
    /// UI mode: 0 — power supply, 1 — charger.
    var tab = UserDefaults.standard.integer(forKey: "mode") {
        didSet {
            UserDefaults.standard.set(tab, forKey: "mode")
            // async: didSet comes from a SwiftUI update, a modal alert must not be shown from there
            if tab == 0 { DispatchQueue.main.async { self.offerProtRestore() } }
        }
    }
    /// The protections as they were before charging wrote its own (key — register number).
    /// Kept in UserDefaults so that the reminder survives an app restart.
    private var protBackup = UserDefaults.standard.dictionary(forKey: "protBackup") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(protBackup, forKey: "protBackup") }
    }

    /// In power supply mode the charging OVP/OCP get in the way — remind and offer to restore the previous ones.
    private func offerProtRestore() {
        guard tab == 0, !charging, let dev, !protBackup.isEmpty else { return }
        let protBackup = self.protBackup
        self.protBackup = [:]   // ask once; cleared before the dialog — new dumps keep arriving while it is open
        let text = [(Reg.ovp, state.ovp, "OVP = %.2f В (сейчас %.2f)"), (Reg.ocp, state.ocp, "OCP = %.2f А (сейчас %.2f)")]
            .compactMap { reg, now, f in protBackup[String(reg)].map { L(f, $0, now ?? 0) } }
            .joined(separator: ", ")
        if confirm(L("После заряда на приборе остались зарядные защиты. Вернуть прежние: %@?", text)) {
            for (reg, v) in protBackup { if let r = UInt8(reg) { dev.set(r, v) } }
        }
    }

    // plot
    var plot: [Sample] = []
    var window = 300.0 { didSet { replot() } }
    var paused = false { didSet { replot() } }
    var showPower = true
    var recording = false

    // charging
    var chChem = min(UserDefaults.standard.integer(forKey: "chem"), chemistries.count - 1) {
        didSet {
            UserDefaults.standard.set(chChem, forKey: "chem")
            applyChemistry()
        }
    }
    var chem: Chemistry { chemistries[chChem] }
    var isNiMH: Bool { chem.profiles.isEmpty }
    var chProfile = 0 { didSet { if !isNiMH, let v = chem.profiles[chProfile].v { chV = v } } }
    var chCells = 1.0 { didSet { if isNiMH { chV = chCells * nimhCellV } } }
    var chV = 4.2
    var chCap = 800.0
    var chCrate = 0.5
    var chI = 0.4
    var chCut = 0.08
    var chMax = 240.0
    var charging = false
    var chargeStatus = L("Подключите банку к выходу (соблюдая полярность) и нажмите «Начать».")

    @ObservationIgnored private var dev: Device?
    @ObservationIgnored private var fake: FakeDPS150?
    @ObservationIgnored private var gen = 0          // filters out frames from a previous connection
    @ObservationIgnored private var devSetV: Double?
    @ObservationIgnored private var devSetI: Double?
    @ObservationIgnored private var devProt: [UInt8: Double] = [:]
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var t0 = monotonic()
    @ObservationIgnored private var csv: FileHandle?
    @ObservationIgnored private let charger = ChargeController()
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var pendingApply: DispatchWorkItem?

    private init() {
        charger.onStatus = { [unowned self] in chargeStatus = $0 }
        charger.onFinished = { [unowned self] in chargeFinished($0, $1) }
        applyChemistry()
        refreshPorts()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in poll() }
        if CommandLine.arguments.contains("--demo") {
            port = demoPort
            connect()
        }
    }

    // ---- connection ----------------------------------------------------------

    func refreshPorts() {
        ports = findPorts()
        let candidates = [port, UserDefaults.standard.string(forKey: "port") ?? "",
                          ports.first { $0.contains("usbmodem") } ?? "", ports.first ?? ""]
        port = candidates.first { $0 == demoPort || ports.contains($0) } ?? demoPort
    }

    func toggleConnection() { dev == nil ? connect() : disconnect() }

    func connect() {
        gen += 1
        let g = gen
        let onFrame: (Frame) -> Void = { [weak self] f in
            DispatchQueue.main.async { if self?.gen == g { self?.onFrame(f) } }
        }
        let onError: (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async { if self?.gen == g { self?.onError(msg) } }
        }
        do {
            if port == demoPort {
                let f = FakeDPS150()
                fake = f
                dev = Device(fd: f.clientFD, onFrame: onFrame, onError: onError)
            } else {
                dev = try Device(port: port, onFrame: onFrame, onError: onError)
            }
        } catch {
            alert(L("Не удалось открыть %@:\n%@", port, error.localizedDescription))
            return
        }
        UserDefaults.standard.set(port, forKey: "port")
        state = DeviceState()
        devSetV = nil
        devSetI = nil
        protEdit = [:]
        devProt = [:]
        connected = true
        connLabel = L("Подключение…")
        connColor = cDim
        status = port == demoPort ? L("Эмулятор (демо, без прибора)") : L("Открыт %@", port)
    }

    func disconnect() {
        if charger.active { charger.stop(L("Отключение от прибора — заряд остановлен"), ok: false) }
        gen += 1
        dev?.close()   // flushes the queue (including "output off") and closes the session
        dev = nil
        fake?.close()
        fake = nil
        connected = false
        state = DeviceState()
        outOnSince = nil
        connLabel = L("Не подключено")
        connColor = cDim
    }

    private func poll() {
        guard let dev else { return }
        dev.refresh()   // catch changes made with the knob on the device
        let silent = monotonic() - dev.lastRx
        if silent > 3 {
            connLabel = L("Нет данных от прибора…")
            connColor = cBad
        }
        // The device sends telemetry every 0.5 s. If it is silent, the auto-stop is blind.
        if charger.active && silent > 5 { onError(L("Прибор не отвечает больше 5 с")) }
    }

    private func onError(_ msg: String) {
        status = msg
        let wasCharging = charger.active
        disconnect()
        if wasCharging { notify(L("Связь с прибором потеряна во время заряда!")) }
        alert(L("%@\n\nСоединение закрыто.", msg))
    }

    // ---- updates from the device ---------------------------------------------

    private func onFrame(_ f: Frame) {
        guard let kind = apply(f, to: &state) else { return }
        let s = state
        if kind == .measurement || kind == .dump || f.reg == Reg.modelName || f.reg == Reg.firmwareVersion {
            connLabel = "● \(s.model ?? "DPS-150") \(s.fwVersion ?? "")"
            connColor = cOK
        }
        if kind == .measurement, let v = s.outVoltage, let i = s.outCurrent, let p = s.outPower {
            append(v, i, p)   // live telemetry only, not the dump
        }
        if !s.outputOn {
            outOnSince = nil
        } else if outOnSince == nil {
            outOnSince = monotonic()
        }
        if kind == .dump || f.reg == Reg.voltageSet || f.reg == Reg.currentSet { syncSetpoints() }
        if kind == .dump {
            // the app was restarted in power supply mode — the reminder about charging protections
            if !protBackup.isEmpty { DispatchQueue.main.async { self.offerProtRestore() } }
            // As with setpoints: the field is updated only when the value changed in the device.
            for (reg, v) in [Reg.ovp: s.ovp, Reg.ocp: s.ocp, Reg.opp: s.opp, Reg.otp: s.otp, Reg.lvp: s.lvp] {
                if let v, v != devProt[reg] {
                    protEdit[reg] = v
                    devProt[reg] = v
                }
            }
        }
        charger.onUpdate(s, kind)
    }

    /// Mirrors the device setpoints into the input fields only when they changed on
    /// the device side (with the knob) — unfinished input is not overwritten.
    private func syncSetpoints() {
        guard let sv = state.setVoltage, let si = state.setCurrent else { return }
        if sv != devSetV { spV = sv }
        if si != devSetI { spI = si }
        devSetV = sv
        devSetI = si
    }

    // ---- actions -------------------------------------------------------------

    func applySetpoints() {
        guard let dev else { return }
        let v = (spV * 100).rounded() / 100, i = (spI * 1000).rounded() / 1000
        if state.setVoltage.map({ abs($0 - v) > 0.004 }) ?? true { dev.setVoltage(v) }
        if state.setCurrent.map({ abs($0 - i) > 0.0004 }) ?? true { dev.setCurrent(i) }
        status = L("Уставка: %.2f В, %.3f А", v, i)
    }

    /// For the ▲▼ buttons: write to the device after a pause, not on every auto-repeat step
    /// (each write pulls a full dump after it).
    func applySetpointsSoon() {
        pendingApply?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applySetpoints() }
        pendingApply = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func toggleOutput() {
        guard let dev else { return }
        let on = !state.outputOn
        if !on && charger.active {
            charger.stop(L("Выход выключен вручную — заряд прерван"), ok: false)
            return
        }
        dev.setOutput(on)
    }

    func toggleMetering() { dev?.setMetering(!state.meteringOn) }

    func loadPreset(_ n: Int) {
        guard state.presets.count >= n else { return }
        spV = state.presets[n - 1].v
        spI = state.presets[n - 1].i
        applySetpoints()
    }

    func savePreset(_ n: Int) { dev?.setPreset(n, v: spV, a: spI) }

    func writeProtection(_ reg: UInt8) {
        guard let dev, let v = protEdit[reg] else { return }
        dev.set(reg, v)
        status = L("Защита записана")
    }

    func setByte(_ reg: UInt8, _ v: Int) { dev?.set(reg, byte: UInt8(v)) }

    // ---- charging ------------------------------------------------------------

    /// Chemistry tab change: all charge parameters go to its defaults.
    private func applyChemistry() {
        chProfile = 0          // didSet sets chV
        chCells = chCells      // same for NiMH
        chCrate = chem.rates[chem.defRate].c
        chMax = chem.maxMin
        autoChargeParams()
    }

    func autoChargeParams() {
        let cap = chCap / 1000
        chI = max(0.01, (cap * chCrate * 100).rounded() / 100)
        chCut = max(0.01, (cap * chem.cutC * 1000).rounded() / 1000)
    }

    func toggleCharge() {
        if charger.active {
            charger.stop(L("Остановлено пользователем"), ok: false)
            return
        }
        guard let dev else { return }
        if let prot = state.protection, !prot.isEmpty {
            return alert(L("На приборе активна защита %@ — заряд не начат.", prot)
                + (prot == "LVP" ? " " + L("Входное напряжение %@ В ниже порога LVP %@ В: проверьте питание на Type-C.",
                                           fmt(state.inputVoltage, 2), fmt(state.lvp, 2)) : ""))
        }
        let v = chV
        let normV = isNiMH ? chCells * nimhCellV : chem.profiles[chProfile].v ?? chem.maxV
        if v > normV + 0.05
            && !confirm(L("%.2f В — выше нормы для выбранного профиля (%.2f В). Точно продолжить?", v, normV),
                        danger: true) { return }
        // OVP too high — no safeguard; too low (left over from a previous charge) — it trips at once.
        // OCP — likewise: in CC the device itself holds chI, the 0.2 A margin covers measurement noise.
        var guards: [(reg: UInt8, value: Double, old: Double, text: String)] = []
        if let ovp = state.ovp, ovp > v + 1.0 || ovp < v + 0.2 {
            guards.append((Reg.ovp, v + 0.3, ovp, L("OVP = %.2f В (сейчас %.2f)", v + 0.3, ovp)))
        }
        if let ocp = state.ocp, ocp > chI + 0.5 || ocp < chI + 0.1 {
            guards.append((Reg.ocp, chI + 0.2, ocp, L("OCP = %.2f А (сейчас %.2f)", chI + 0.2, ocp)))
        }
        if !guards.isEmpty,
           confirm(L("Записать защиты как страховку на время заряда: %@?",
                     guards.map(\.text).joined(separator: ", "))) {
            for g in guards {
                // on a repeated charge do not overwrite the original value with a charging one
                if protBackup[String(g.reg)] == nil { protBackup[String(g.reg)] = g.old }
                dev.set(g.reg, g.value)
            }
        }
        // The auto-stop is in software: keep the system from putting the Mac or the app (App Nap) to sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Заряд АКБ")
        charging = true
        charger.start(dev: dev, meteringOn: state.meteringOn, v: v, i: chI, cutoff: chCut, maxMin: chMax,
                      maxMah: isNiMH ? chCap * nimhOvercharge : nil)
        tab = 1
        if window > 0 && window < 3600 { window = 0 }
    }

    private func chargeFinished(_ msg: String, _ ok: Bool) {
        charging = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        chargeStatus = (ok ? "✅ " : "⚠ ") + msg
        notify(msg)
        NSSound.beep()
    }

    // ---- plot and CSV --------------------------------------------------------

    private func append(_ v: Double, _ i: Double, _ p: Double) {
        let t = monotonic() - t0
        samples.append(Sample(t: t, v: v, i: i, p: p))
        if samples.count > Self.maxPoints { samples.removeFirst(samples.count - Self.maxPoints) }
        if let csv {
            let s = state
            let row = String(format: "%@,%.2f,%.4f,%.4f,%.4f,%.2f,%.1f,%@,%d,%.5f,%.5f\n",
                             Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true)), t, v, i, p,
                             s.inputVoltage ?? 0, s.temperature ?? 0, s.mode ?? "", s.outputOn ? 1 : 0,
                             s.capacityAh ?? 0, s.energyWh ?? 0)
            try? csv.write(contentsOf: Data(row.utf8))
        }
        replot()
    }

    // ponytail: decimation with a plain step down to ~600 points — in the "All" window narrow
    // spikes may drop out of the picture (they are in the CSV). If needed — min/max per bucket.
    private func replot() {
        guard !paused else { return }
        guard let last = samples.last else { plot = []; return }
        var a = 0
        if window > 0 {
            var b = samples.count
            let lo = last.t - window
            while a < b {
                let m = (a + b) / 2
                if samples[m].t < lo { a = m + 1 } else { b = m }
            }
        }
        let step = max(1, (samples.count - a) / 600)
        plot = stride(from: a, to: samples.count, by: step).map { samples[$0] }
    }

    func clearPlot() {
        samples = []
        t0 = monotonic()
        plot = []
    }

    func toggleRecording() {
        if recording { return stopRecording() }
        guard let url = savePanel(L("Запись в CSV"), "dps150_\(stamp()).csv") else { return }
        let header = "timestamp,t_s,voltage_v,current_a,power_w,vin_v,temp_c,mode,output_on,capacity_ah,energy_wh\n"
        guard (try? header.write(to: url, atomically: false, encoding: .utf8)) != nil,
              let h = try? FileHandle(forWritingTo: url) else {
            return alert(L("Не удалось создать %@", url.path))
        }
        h.seekToEndOfFile()
        csv = h
        recording = true
        status = L("Запись в %@", url.path)
    }

    func stopRecording() {
        try? csv?.close()
        csv = nil
        recording = false
    }

    func exportCSV() {
        guard !samples.isEmpty, let url = savePanel(L("Экспорт графика"), "dps150_plot_\(stamp()).csv") else { return }
        let text = samples.reduce(into: "t_s,voltage_v,current_a,power_w\n") {
            $0 += String(format: "%.2f,%.4f,%.4f,%.4f\n", $1.t, $1.v, $1.i, $1.p)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = L("Сохранено: %@", url.path)
        } catch {
            alert(L("Не удалось сохранить: %@", error.localizedDescription))
        }
    }
}
