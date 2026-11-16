// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import DPS150Kit

final class KitTests: XCTestCase {
    func testKnownFrames() {
        XCTAssertEqual(frameSet(Reg.brightness, byte: 12), [0xF1, 0xB1, 0xD6, 0x01, 0x0C, 0xE3])
        XCTAssertEqual(frameSet(Reg.volume, byte: 9), [0xF1, 0xB1, 0xD7, 0x01, 0x09, 0xE1])
        XCTAssertEqual(frameSession(true), [0xF1, 0xC1, 0x00, 0x01, 0x01, 0x02])
        XCTAssertEqual(frameSession(false), [0xF1, 0xC1, 0x00, 0x01, 0x00, 0x01])
        XCTAssertEqual(frameBaud(), [0xF1, 0xB0, 0x00, 0x01, 0x05, 0x06])
    }

    func testParseModelNameAndResync() {
        let raw: [UInt8] = [0xF0, 0xA1, 0xDE, 0x07] + Array("DPS-150".utf8) + [0x8F]
        let p = FrameParser()
        var frames = p.feed([0x00, 0x13, 0xF0] + raw[..<5])   // garbage + an incomplete frame
        frames += p.feed(Array(raw[5...]))
        XCTAssertEqual(frames.count, 1)
        var s = DeviceState()
        XCTAssertNotNil(apply(frames[0], to: &s))
        XCTAssertEqual(s.model, "DPS-150")
    }

    func testMeasurementRoundtripAndBadChecksum() {
        var raw = buildFrame(Cmd.get, Reg.measurement, f32Bytes(4.2) + f32Bytes(0.5) + f32Bytes(2.1),
                             header: headerRX)
        var s = DeviceState()
        XCTAssertEqual(apply(FrameParser().feed(raw)[0], to: &s), .measurement)
        XCTAssertEqual(s.outVoltage!, 4.2, accuracy: 1e-6)
        XCTAssertEqual(s.outCurrent!, 0.5, accuracy: 1e-6)
        raw[raw.count - 1] ^= 0xFF
        let p = FrameParser()
        XCTAssertEqual(p.feed(raw), [])
        XCTAssertEqual(p.badChecksums, 1)
    }

    func testClientAgainstEmulator() throws {
        let fake = FakeDPS150()
        let lock = NSLock()
        var state = DeviceState()
        func s() -> DeviceState { lock.withLock { state } }
        let d = Device(fd: fake.clientFD,
                           onFrame: { f in lock.withLock { _ = apply(f, to: &state) } },
                           onError: { XCTFail($0) })
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(s().model, "DPS-150")
        XCTAssertEqual(s().presets.count, 6)
        d.setVoltage(4.2); d.setCurrent(0.3); d.setOutput(true)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(s().outputOn)
        XCTAssertEqual(s().setVoltage!, 4.2, accuracy: 1e-4)
        XCTAssertEqual(s().outCurrent!, 0.3, accuracy: 1e-3)
        XCTAssertEqual(s().mode, "CC")
        d.setPreset(2, v: 7.5, a: 0.25)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(s().presets[1].v, 7.5, accuracy: 1e-4)
        d.setOutput(false)
        d.close()   // must flush the queue before closing
        XCTAssertFalse(fake.outputOn)
        fake.close()
    }

    /// Runs ChargeController against the emulator on the main thread, as the app does.
    /// `tamper` lets a test feed the controller a distorted state.
    private func runCharge(speedup: Double, timeout: Double, maxMah: Double? = nil,
                           tamper: @escaping (inout DeviceState, Double) -> Void = { _, _ in })
        throws -> (msg: String, ok: Bool, outputOn: Bool) {
        let fake = FakeDPS150(speedup: speedup)
        let charger = ChargeController()
        var state = DeviceState()
        var result: (String, Bool)?
        let done = expectation(description: "finished")
        charger.onFinished = { result = ($0, $1); done.fulfill() }
        let t0 = monotonic()
        let d = Device(fd: fake.clientFD, onFrame: { f in
            DispatchQueue.main.async {
                guard let kind = apply(f, to: &state) else { return }
                var s = state
                tamper(&s, monotonic() - t0)
                charger.onUpdate(s, kind)
            }
        }, onError: { XCTFail($0) })
        charger.start(dev: d, meteringOn: false, v: 4.2, i: 0.4, cutoff: 0.08, maxMin: 240, maxMah: maxMah)
        wait(for: [done], timeout: timeout)
        d.close()
        let on = fake.outputOn
        fake.close()
        return (result!.0, result!.1, on)
    }

    func testFullChargeCycleStopsOnTaper() throws {
        let r = try runCharge(speedup: 1500, timeout: 60)
        XCTAssertTrue(r.ok, r.msg)
        XCTAssertTrue(r.msg.hasPrefix("Заряжено"), r.msg)
        XCTAssertFalse(r.outputOn, "после заряда выход должен быть выключен")
    }

    func testCapacityLimitStop() throws {
        let r = try runCharge(speedup: 1500, timeout: 30, maxMah: 100)
        XCTAssertTrue(r.ok, r.msg)
        XCTAssertTrue(r.msg.contains("стоп по ёмкости"), r.msg)
        XCTAssertFalse(r.outputOn)
    }

    func testOvervoltageEmergencyStop() throws {
        let r = try runCharge(speedup: 1, timeout: 10) { s, el in
            if el > 3 { s.outVoltage = 4.4 }
        }
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.msg.contains("аварийный стоп"), r.msg)
        XCTAssertFalse(r.outputOn)
    }

    func testProtectionEmergencyStop() throws {
        let r = try runCharge(speedup: 1, timeout: 10) { s, el in
            if el > 3 { s.protection = "OVP" }
        }
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.msg.contains("защита OVP"), r.msg)
        XCTAssertFalse(r.outputOn)
    }
}
