import Testing
@testable import WalkingPadKit

@Suite struct VendorFrames {
    @Test func checksumIsSumOfPriorBytes() {
        #expect(Z1Protocol.frame(0x72, 0x00, [0x00]) == [0x72, 0x00, 0x01, 0x00, 0x73])
        #expect(Z1Protocol.frame(0x77, 0x01, [0x07]) == [0x77, 0x01, 0x01, 0x07, 0x80])
    }

    @Test func unlockFrameForZ1MatchesHardwareCapture() {
        // Verified on a real KS-HD-Z1D: last 4 chars "-Z1D" as LE32, plus one.
        #expect(Z1Protocol.unlock(deviceName: "KS-HD-Z1D")
            == [0x71, 0x00, 0x05, 0x01, 0x2E, 0x5A, 0x31, 0x44, 0x74])
    }

    @Test func unlockTokenCarriesAcrossBytes() {
        // "\u{FF}\u{FF}" etc. aren't valid names; use bytes that overflow the low byte.
        let frame = Z1Protocol.unlock(deviceName: "AB\u{7F}\u{7F}\u{7F}\u{7F}")!
        #expect(Array(frame[4...7]) == [0x80, 0x7F, 0x7F, 0x7F])
    }

    @Test func unlockRejectsShortNames() {
        #expect(Z1Protocol.unlock(deviceName: "KS") == nil)
    }

    @Test func parseRoundTripsAndRejectsBadChecksum() {
        let f = Z1Protocol.frame(0x72, 0x81, [0x0A, 0x00])
        #expect(Z1Protocol.parse(f) == Z1Protocol.Frame(cmd0: 0x72, cmd1: 0x81, data: [0x0A, 0x00]))
        var bad = f
        bad[bad.count - 1] &+= 1
        #expect(Z1Protocol.parse(bad) == nil)
        #expect(Z1Protocol.parse([0x71, 0x80]) == nil)
    }

    @Test func propertyWriteIsLittleEndian() {
        #expect(Z1Protocol.writeProperty(id: 10, value: 0x0240)
            == Z1Protocol.frame(0x72, 0x01, [0x0A, 0x40, 0x02]))
    }

    @Test func propertyRecordsSkipErrors() {
        let records: [UInt8] = [1, 0, 0x03, 0x00, 4, 1, 0x05, 0x00, 10, 0, 0x40, 0x02]
        #expect(Z1Protocol.propertyRecords(records) == [1: 0x0003, 10: 0x0240])
    }

    @Test func propertyPushRecordsAreThreeBytes() {
        #expect(Z1Protocol.propertyPushRecords([6, 1, 0, 8, 0x0A, 0]) == [6: 1, 8: 0x000A])
    }
}

@Suite struct Telemetry {
    @Test func parsesZ1Frame() {
        // flags 0x2404: speed (bit0 clear) + distance + elapsed + steps
        let raw: [UInt8] = [0x04, 0x24,
                            0x2C, 0x01,        // 3.00 km/h
                            0xE8, 0x03, 0x00,  // 1000 m
                            0x58, 0x02,        // 600 s
                            0x39, 0x05]        // 1337 steps
        let t = Z1Protocol.telemetry(raw)
        #expect(t.speedKmh == 3.0)
        #expect(t.distanceM == 1000)
        #expect(t.elapsedS == 600)
        #expect(t.steps == 1337)
    }

    @Test func parsesRealZ1FrameWithEnergy() {
        // Captured from a KS-HD-Z1D: flags 0x2484 (distance, energy, elapsed, steps)
        // plus one trailing byte the spec doesn't define.
        let raw: [UInt8] = [0x84, 0x24, 0xE6, 0x00, 0x14, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                            0x00, 0x23, 0x00, 0x25, 0x00, 0x00]
        let t = Z1Protocol.telemetry(raw)
        #expect(t.speedKmh == 2.3)
        #expect(t.distanceM == 20)
        #expect(t.kcal == 1)
        #expect(t.elapsedS == 35)
        #expect(t.steps == 37)
    }

    @Test func skipsUnusedFields() {
        // avg speed (bit1) + incline (bit3) present before distance; no steps
        let raw: [UInt8] = [0x0E, 0x00,
                            0x64, 0x00,              // 1.00 km/h
                            0xFF, 0xFF,              // avg speed (ignored)
                            0x10, 0x00, 0x00,        // 16 m
                            0x00, 0x00, 0x00, 0x00]  // incline + ramp
        let t = Z1Protocol.telemetry(raw)
        #expect(t.speedKmh == 1.0)
        #expect(t.distanceM == 16)
        #expect(t.steps == nil)
    }

    @Test func truncatedFrameDoesNotCrash() {
        let t = Z1Protocol.telemetry([0x04, 0x24, 0x2C])
        #expect(t.speedKmh == nil)
        #expect(t.distanceM == nil)
    }

    @Test func speedRange() {
        #expect(Z1Protocol.speedRange([0xA0, 0x00, 0x80, 0x02, 0x0A, 0x00]) == 1.6...6.4)
        #expect(Z1Protocol.speedRange([0x01]) == nil)
    }
}

@Suite struct Settings {
    @Test func modeBitsPreserveOtherBits() {
        #expect(Z1Protocol.mode(from: 0x0240) == .standby)
        #expect(Z1Protocol.mode(from: 0x0200) == .manual)
        #expect(Z1Protocol.mode(from: 0x0220) == .auto)
        #expect(Z1Protocol.setting(mode: .standby, in: 0x0200) == 0x0240)
        #expect(Z1Protocol.setting(mode: .manual, in: 0x0240) == 0x0200)
    }

    @Test func speedCommandEncodesHundredths() {
        #expect(Z1Protocol.speedParams(2.5) == [0xFA, 0x00])
        #expect(Z1Protocol.speedParams(6.4) == [0x80, 0x02])
    }

    @Test func caloriesFollowACSMWalkingEquation() {
        // 6 km/h = 100 m/min -> VO2 = 13.5 ml/kg/min -> 13.5 * 80 / 200 = 5.4 kcal/min
        #expect(abs(Metrics.kcalPerMinute(speedKmh: 6, weightKg: 80) - 5.4) < 1e-9)
        #expect(Metrics.kcalPerMinute(speedKmh: 0, weightKg: 80) == 0)
    }
}
