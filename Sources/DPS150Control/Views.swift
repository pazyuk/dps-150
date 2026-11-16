// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Charts
import DPS150Kit
import SwiftUI
import UserNotifications

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

let cV = Color(hex: 0xf5c542)     // voltage
let cI = Color(hex: 0x38c6f4)     // current
let cP = Color(hex: 0xe86bd8)     // power
let cOK = Color(hex: 0x3ecf6e)
let cBad = Color(hex: 0xff5a5a)
let cDim = Color(hex: 0x8a8f98)
let cOff = Color(hex: 0x2a2d33)
let cPanel = Color(hex: 0x15171b)

func fmt(_ v: Double?, _ dec: Int, _ unit: String = "") -> String {
    v.map { String(format: "%.\(dec)f", $0) + (unit.isEmpty ? "" : " " + L(unit)) } ?? "—"
}

// ---- app -----------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)   // needed when launched without a bundle (swift run)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleIdentifier != nil {   // see notify()
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        Updater.shared.check(manual: false)
    }

    /// Show the end-of-charge banner even when the window is frontmost.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let m = AppModel.shared
        if m.charging && !confirm(L("Идёт заряд. Выключить выход и выйти?")) { return .terminateCancel }
        m.stopRecording()
        m.disconnect()
        return .terminateNow
    }
}

@main struct DPS150App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window(appName, id: "main") {
            ContentView(m: .shared)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1160, minHeight: 800)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { Updater.shared.check(manual: true) }
                    .disabled(!Updater.shared.enabled)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Экспорт графика в CSV…") { AppModel.shared.exportCSV() }.keyboardShortcut("s")
            }
        }
        Settings {
            SettingsView(m: .shared)
                .preferredColorScheme(.dark)
                .frame(width: 700, height: 420)
        }
    }
}

// ---- small widgets -------------------------------------------------------

/// Numeric field with a stepper; the value is always clamped to range.
struct NumField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    let step: Double
    let unit: String
    var onCommit: () -> Void = {}

    var body: some View {
        let clamped = Binding(get: { value },
                              set: { value = min(max($0, range.lowerBound), range.upperBound) })
        HStack(spacing: 4) {
            TextField("", value: clamped, format: .number.precision(.fractionLength(decimals)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 70)
                .onSubmit(onCommit)
            Text(LocalizedStringKey(unit)).foregroundStyle(cDim)
            Stepper("", value: clamped, in: range, step: step).labelsHidden()
        }
    }
}

/// Large setpoint: a field and big ▼▲ buttons (step 0.1, with ⌥ — 0.01, hold to repeat).
struct BigSetpoint: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    let unit: String
    let color: Color
    let onSubmit: () -> Void
    let onBump: () -> Void

    private func bump(_ dir: Double) {
        let d = NSEvent.modifierFlags.contains(.option) ? 0.01 : 0.1
        value = min(max(value + dir * d, range.lowerBound), range.upperBound)
        onBump()
    }

    var body: some View {
        let clamped = Binding(get: { value },
                              set: { value = min(max($0, range.lowerBound), range.upperBound) })
        HStack(spacing: 6) {
            TextField(L(label), value: clamped, format: .number.precision(.fractionLength(decimals)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(cPanel, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(onSubmit)
            Text(LocalizedStringKey(unit)).font(.system(size: 16)).foregroundStyle(cDim).frame(width: 16)
            ForEach([-1.0, 1.0], id: \.self) { dir in
                Button { bump(dir) } label: {
                    Image(systemName: dir < 0 ? "chevron.down" : "chevron.up")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 34, height: 30)
                }
                .buttonRepeatBehavior(.enabled)
                .help("Шаг 0.1, с ⌥ — 0.01")
                .accessibilityLabel(L(label) + (dir < 0 ? " −" : " +"))
            }
        }
    }
}

private let protections: [(label: String, reg: UInt8, kp: KeyPath<DeviceState, Double?>,
                           hi: Double, dec: Int, unit: String)] = [
    ("OVP — перенапряжение выхода", Reg.ovp, \.ovp, 32, 2, "В"),
    ("OCP — перегрузка по току", Reg.ocp, \.ocp, 5.5, 3, "А"),
    ("OPP — перегрузка по мощности", Reg.opp, \.opp, 160, 1, "Вт"),
    ("OTP — перегрев", Reg.otp, \.otp, 100, 0, "°C"),
    ("LVP — низкое входное напряжение", Reg.lvp, \.lvp, 30, 2, "В"),
]

/// Protection thresholds; compact — for the charger screen (just "OVP" etc. instead of the full label).
struct ProtectionsGrid: View {
    @Bindable var m: AppModel
    var compact = false

    var body: some View {
        Grid(alignment: .leading, verticalSpacing: compact ? 6 : 10) {
            ForEach(protections, id: \.reg) { p in
                GridRow {
                    Text(compact ? String(p.label.prefix(3)) : L(p.label)).help(L(p.label))
                    NumField(value: Binding(get: { m.protEdit[p.reg] ?? 0 }, set: { m.protEdit[p.reg] = $0 }),
                             range: 0...p.hi, decimals: p.dec, step: pow(10, -Double(p.dec)), unit: p.unit)
                        .frame(width: compact ? 150 : 170)
                    Button("Записать") { m.writeProtection(p.reg) }.disabled(!m.connected)
                    Text(compact ? fmt(m.state[keyPath: p.kp], p.dec)
                                 : L("сейчас: %@", fmt(m.state[keyPath: p.kp], p.dec, p.unit)))
                        .foregroundStyle(cDim).help("Текущее значение в приборе")
                }
            }
        }
        .padding(6)
    }
}

private func chip(_ text: String, _ bg: Color, _ fg: Color = Color(hex: 0x101010)) -> some View {
    Text(text).fontWeight(.bold).foregroundStyle(fg)
        .frame(maxWidth: .infinity).padding(.vertical, 2)
        .background(bg, in: Capsule())
}

private func readout(_ v: Double?, _ dec: Int, _ unit: String, _ color: Color, size: CGFloat = 44) -> some View {
    HStack(alignment: .lastTextBaseline) {
        Spacer()
        Text(fmt(v, dec)).font(.system(size: size, weight: .semibold, design: .monospaced))
        Text(unit).font(.system(size: size * 0.45))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 14).padding(.vertical, 6)
    .background(cPanel, in: RoundedRectangle(cornerRadius: 10))
}

// ---- main window ---------------------------------------------------------

struct ContentView: View {
    @Bindable var m: AppModel
    @Bindable var updater = Updater.shared

    private var s: DeviceState { m.state }
    private var vMax: Double { s.maxVoltage.flatMap { $0 > 0 ? ($0 * 100).rounded() / 100 : nil } ?? 30 }
    private var iMax: Double { s.maxCurrent.flatMap { $0 > 0 ? ($0 * 1000).rounded() / 1000 : nil } ?? 5.1 }

    var body: some View {
        VStack(spacing: 10) {
            connectionBar
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    meter
                    if m.tab == 0 { supplyControls } else { chargeControls }
                    Spacer()
                }
                .frame(width: 340)
                VStack(spacing: 10) {
                    if m.tab == 1 { chargeSetup }
                    plotPane
                }
            }
            Text(m.status).font(.callout).foregroundStyle(cDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .sheet(isPresented: Binding(get: { updater.available != nil },
                                    set: { if !$0 { updater.available = nil } })) {
            if let rel = updater.available { UpdateSheet(u: updater, rel: rel) }
        }
    }

    private var connectionBar: some View {
        HStack {
            Picker("Порт:", selection: $m.port) {
                ForEach(m.ports, id: \.self) { Text(($0.contains("usbmodem") ? "★ " : "") + $0).tag($0) }
                Text("Эмулятор (демо, без прибора)").tag(demoPort)
            }
            .frame(width: 320)
            .disabled(m.connected)
            Button { m.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить список портов")
                .disabled(m.connected)
            Button(m.connected ? L("Отключить") : L("Подключить")) { m.toggleConnection() }
            Text(m.connLabel).foregroundStyle(m.connColor)
            Spacer()
            Picker("", selection: $m.tab) {
                Text("Блок питания").tag(0)
                Text("Зарядник").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            SettingsLink { Image(systemName: "gearshape") }
                .help("Настройки: защиты и прибор (⌘,)")
        }
    }

    // ---- left column: readings and controls ----------------------------------

    @ViewBuilder private var meter: some View {
            readout(s.outVoltage, 3, "V", cV)
            readout(s.outCurrent, 3, "A", cI)
            readout(s.outPower, 2, "W", cP, size: 30)

            HStack {
                if s.outputOn { chip("ON", cOK) } else { chip("OFF", cOff, cDim) }
                if let mode = s.mode {
                    if s.outputOn { chip(mode, mode == "CC" ? cI : cV) } else { chip(mode, cOff, cDim) }
                } else {
                    chip("—", cOff, cDim)
                }
                switch s.protection {
                case nil: chip("—", cOff, cDim)
                case "": chip(L("защиты OK"), Color(hex: 0x24402e), cOK)
                case let p?: chip("⚠ \(p)", cBad, .white)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Вход:").foregroundStyle(cDim)
                    Text(fmt(s.inputVoltage, 2, "В"))
                    Text("Темп.:").foregroundStyle(cDim)
                    Text(fmt(s.temperature, 1, "°C"))
                }
                GridRow {
                    Text("Ёмкость:").foregroundStyle(cDim)
                    Text(s.capacityAh.map { $0 < 1 ? fmt($0 * 1000, 0, "мА·ч") : fmt($0, 3, "А·ч") } ?? "—")
                    Text("Энергия:").foregroundStyle(cDim)
                    Text(fmt(s.energyWh, 3, "Вт·ч"))
                }
                GridRow {
                    Text("Уставка:").foregroundStyle(cDim)
                    Text(s.setVoltage == nil ? "—" : L("%@ В / %@ А", fmt(s.setVoltage, 2), fmt(s.setCurrent, 3)))
                    Text("Вкл.:").foregroundStyle(cDim)
                    Text(m.outOnSince.map { fmtDur(monotonic() - $0) } ?? "—")
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var supplyControls: some View {
            Button { m.toggleOutput() } label: {
                Text(s.outputOn ? L("ВЫХОД: ВКЛ") : L("ВЫХОД: ВЫКЛ"))
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity).padding(8)
            }
            .buttonStyle(.borderedProminent)
            .tint(s.outputOn ? Color(hex: 0xc0392b) : Color(hex: 0x2e7d4f))
            .keyboardShortcut(.return, modifiers: .command)
            .help("⌘↩ — переключить выход")
            .disabled(!m.connected)

            GroupBox("Уставки") {
                VStack(spacing: 6) {
                    BigSetpoint(label: "Напряжение", value: $m.spV, range: 0...vMax, decimals: 2, unit: "В",
                                color: cV, onSubmit: m.applySetpoints, onBump: m.applySetpointsSoon)
                    BigSetpoint(label: "Ток", value: $m.spI, range: 0...iMax, decimals: 3, unit: "А",
                                color: cI, onSubmit: m.applySetpoints, onBump: m.applySetpointsSoon)
                    Button { m.applySetpoints() } label: { Text("Установить").frame(maxWidth: .infinity) }
                        .disabled(!m.connected)
                }
                .disabled(m.charging)   // while charging, ChargeController owns the setpoints
            }

            GroupBox("Пресеты M1–M6 (клик — применить, правый клик — записать)") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2)) {
                    ForEach(1...6, id: \.self) { n in
                        Button { m.loadPreset(n) } label: {
                            Text(s.presets.count >= n
                                 ? String(format: "M%d  %.2fV %.3fA", n, s.presets[n - 1].v, s.presets[n - 1].i)
                                 : "M\(n)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity)
                        }
                        .contextMenu {
                            Button(L("Записать %.2f В / %.3f А в M%d", m.spV, m.spI, n)) {
                                m.savePreset(n)
                            }
                        }
                    }
                }
                .disabled(!m.connected || m.charging)
            }

            GroupBox("Счётчик Ah / Wh") {
                Button { m.toggleMetering() } label: {
                    Text(s.meteringOn ? L("Остановить счётчик") : L("Включить счётчик")).frame(maxWidth: .infinity)
                }
                .disabled(!m.connected)
            }
    }

    // ---- plot ----------------------------------------------------------------

    private static let windows: [(String, Double)] = [
        ("30 с", 30), ("1 мин", 60), ("5 мин", 300), ("15 мин", 900), ("1 ч", 3600), ("6 ч", 21600), ("Всё", 0),
    ]

    private var xDomain: ClosedRange<Double> {
        guard let first = m.plot.first, let last = m.plot.last else { return 0...1 }
        let lo = m.window > 0 ? last.t - m.window : first.t
        return lo...max(last.t, lo + 1)
    }

    private func chart(_ kp: KeyPath<Sample, Double>, _ color: Color, _ unit: String) -> some View {
        Chart(m.plot) {
            LineMark(x: .value("t", $0.t), y: .value(unit, $0[keyPath: kp]))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel(L(unit))
    }

    private var plotPane: some View {
        VStack {
            HStack {
                Picker("Окно:", selection: $m.window) {
                    ForEach(Self.windows, id: \.1) { Text(LocalizedStringKey($0.0)).tag($0.1) }
                }
                .frame(width: 170)
                Toggle("Мощность", isOn: $m.showPower)
                Toggle("Пауза", isOn: $m.paused)
                Spacer()
                Button("Очистить") { m.clearPlot() }
                Button(m.recording ? L("■ Идёт запись") : L("● Запись CSV")) { m.toggleRecording() }
                    .foregroundStyle(m.recording ? cBad : .primary)
            }
            chart(\.v, cV, "В")
            chart(\.i, cI, "А")
            if m.showPower { chart(\.p, cP, "Вт") }
            Text("время, с").font(.caption).foregroundStyle(cDim)
        }
    }

    // ---- charging ------------------------------------------------------------

    private var chargeSetup: some View {
        HStack(alignment: .top, spacing: 10) {
            GroupBox("Заряд АКБ") {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    Picker("", selection: $m.chChem) {
                        ForEach(chemistries.indices, id: \.self) {
                            Text(LocalizedStringKey(chemistries[$0].name)).tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().gridCellColumns(2)
                    if m.isNiMH {
                        GridRow {
                            Text("Число банок")
                            NumField(value: $m.chCells, range: 1...12, decimals: 0, step: 1, unit: "шт.")
                        }
                    } else {
                        GridRow {
                            Text("Профиль")
                            Picker("", selection: $m.chProfile) {
                                // Iterate over elements, not indices: when the chemistry changes, SwiftUI may
                                // call a stale closure with an index beyond the new list.
                                ForEach(Array(m.chem.profiles.enumerated()), id: \.offset) {
                                    Text(LocalizedStringKey($0.element.name)).tag($0.offset)
                                }
                            }
                            .labelsHidden()
                            .id(m.chChem)
                        }
                    }
                    GridRow {
                        Text(LocalizedStringKey(m.isNiMH ? "Предел напряжения" : "Конечное напряжение"))
                        NumField(value: $m.chV, range: 1...max(3, vMax), decimals: 2, step: 0.01, unit: "В")
                    }
                    GridRow {
                        Text("Ёмкость банки")
                        NumField(value: $m.chCap, range: 50...50000, decimals: 0, step: 100, unit: "мА·ч")
                    }
                    if m.chem.rates.count > 1 {
                        GridRow {
                            Text("Скорость")
                            Picker("", selection: $m.chCrate) {
                                ForEach(m.chem.rates, id: \.c) { Text(LocalizedStringKey($0.name)).tag($0.c) }
                            }
                            .labelsHidden()
                        }
                    }
                    Button("Подобрать ток и порог по ёмкости") { m.autoChargeParams() }.gridCellColumns(2)
                    GridRow {
                        Text("Ток заряда (CC)")
                        NumField(value: $m.chI, range: 0.01...5.1, decimals: 3, step: 0.01, unit: "А")
                    }
                    GridRow {
                        Text("Стоп, когда ток в CV ниже")
                        NumField(value: $m.chCut, range: 0.005...2, decimals: 3, step: 0.005, unit: "А")
                    }
                    GridRow {
                        Text("Таймаут")
                        NumField(value: $m.chMax, range: 5...1440, decimals: 0, step: 5, unit: "мин")
                    }
                    if m.isNiMH {
                        GridRow {
                            Text("Стоп по ёмкости (150 %)")
                            Text(fmt(m.chCap * nimhOvercharge, 0, "мА·ч")).monospacedDigit()
                        }
                    }
                }
                .padding(6)
                .disabled(m.charging)
            }
            GroupBox("Защиты") { ProtectionsGrid(m: m, compact: true) }
        }
    }

    @ViewBuilder private var chargeControls: some View {
        Button { m.toggleCharge() } label: {
            Text(m.charging ? L("■ Остановить заряд") : L("▶ Начать заряд"))
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity).padding(8)
        }
        .buttonStyle(.borderedProminent)
        .tint(m.charging ? Color(hex: 0xc0392b) : Color(hex: 0x2e7d4f))
        .disabled(!m.connected)
        Text(m.chargeStatus).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
        if m.chem.experimental {
            Text("⚠ Экспериментально: эта химия проверена только на эмуляторе, не на реальном аккумуляторе. Не отходите от аккумулятора во время заряда.")
                .font(.callout).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(L("Как это работает: блок сам держит ток (CC), а у конечного напряжения переходит в CV, и ток начинает падать. Когда в CV ток держится ниже порога 10 с, выход выключается и приходит уведомление. Аварийный стоп — при срабатывании защиты, напряжении выше цели на 0.15 В, по таймауту и при потере связи. На время заряда Mac не засыпает.")
             + "\n\n"
             + L(m.chem.note) + " "
             + L("Перед стартом приложение предложит выставить OVP и OCP чуть выше конечного напряжения и тока заряда — это аппаратная страховка, если программа зависнет. При переходе в режим блока питания оно предложит вернуть прежние значения."))
            .font(.caption).foregroundStyle(cDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ---- settings: protections and device ------------------------------------

struct SettingsView: View {
    @Bindable var m: AppModel
    private var s: DeviceState { m.state }

    var body: some View {
        TabView {
            protectTab.tabItem { Text("Защиты") }
            deviceTab.tabItem { Text("Прибор") }
        }
        .padding(12)
    }

    private var protectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Пороги защит (хранятся в приборе)") { ProtectionsGrid(m: m) }
            Text("Справа — текущее значение в приборе. Значения подгружаются при подключении.")
                .foregroundStyle(cDim)
            Spacer()
        }
        .padding(10)
    }

    // ---- device --------------------------------------------------------------

    private func byteStepper(_ title: String, _ kp: KeyPath<DeviceState, Int?>, _ reg: UInt8,
                             _ range: ClosedRange<Int>) -> some View {
        Stepper(L(title) + ": " + (s[keyPath: kp].map(String.init) ?? "—"),
                value: Binding(get: { s[keyPath: kp] ?? range.lowerBound }, set: { m.setByte(reg, $0) }),
                in: range)
    }

    private var deviceTab: some View {
        Form {
            Section("Информация") {
                LabeledContent("Модель", value: s.model ?? "—")
                LabeledContent("Железо", value: s.hwVersion ?? "—")
                LabeledContent("Прошивка", value: s.fwVersion ?? "—")
                LabeledContent("Пределы выхода", value: s.maxVoltage == nil ? "—"
                    : L("до %@ В / %@ А (зависит от входа)", fmt(s.maxVoltage, 2), fmt(s.maxCurrent ?? 5.1, 2)))
            }
            Section("Экран и звук") {
                byteStepper("Яркость", \.brightness, Reg.brightness, 1...10)
                byteStepper("Громкость", \.volume, Reg.volume, 0...10)
            }
            .disabled(!m.connected)
            Section("Приложение") {
                LabeledContent("Версия", value: Updater.shared.current)
                if Updater.shared.enabled {
                    Button("Проверить обновления…") { Updater.shared.check(manual: true) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
