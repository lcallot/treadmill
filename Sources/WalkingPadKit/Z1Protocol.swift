import Foundation

/// Belt operating mode, stored in bits 5–7 of property 10.
public enum TreadmillMode: UInt16, CaseIterable, Sendable {
    case manual = 0
    case auto = 1
    case standby = 2
}

/// Pure byte-level encoding/decoding for the KingSmith WalkingPad Z1.
///
/// The Z1 speaks standard Bluetooth FTMS, but ignores every command and sends
/// no notifications until an "unlock" frame is written to the KingSmith
/// supplement service. See docs/protocol.md.
public enum Z1Protocol {

    // MARK: GATT UUIDs

    public static let ftmsService = "1826"
    public static let speedRangeChar = "2AD4"
    public static let treadmillDataChar = "2ACD"
    public static let machineStatusChar = "2ADA"
    public static let controlPointChar = "2AD9"

    public static let supplementService = "24E2521C-F63B-48ED-85BE-C5330A00FDF7"
    public static let supplementNotifyChar = "24E2521C-F63B-48ED-85BE-C5330B00FDF7"
    public static let supplementWriteChar = "24E2521C-F63B-48ED-85BE-C5330D00FDF7"

    /// The pad drops vendor frames and control-point writes sent faster than this.
    public static let minWriteInterval: Duration = .milliseconds(400)

    public static func isTreadmillName(_ name: String) -> Bool {
        name.hasPrefix("KS-HD-") || name.hasPrefix("KS-Z1")
    }

    // MARK: FTMS control point

    public enum Op {
        public static let requestControl: UInt8 = 0x00
        public static let reset: UInt8 = 0x01
        public static let setSpeed: UInt8 = 0x02
        public static let startOrResume: UInt8 = 0x07
        public static let stopOrPause: UInt8 = 0x08
        public static let stop: UInt8 = 0x01   // parameter of stopOrPause
        public static let pause: UInt8 = 0x02  // parameter of stopOrPause
    }

    /// FTMS control-point results carried in the `80 <op> <result>` indication.
    public enum Result {
        public static let success: UInt8 = 1
        public static let failed: UInt8 = 4
        public static let notPermitted: UInt8 = 5
    }

    public static func speedParams(_ kmh: Double) -> [UInt8] {
        le16(UInt16((kmh * 100).rounded()))
    }

    // MARK: Vendor (supplement) frames: [cmd0, cmd1, len, data…, checksum]

    public struct Frame: Equatable, Sendable {
        public var cmd0: UInt8
        public var cmd1: UInt8
        public var data: [UInt8]
    }

    public static func frame(_ cmd0: UInt8, _ cmd1: UInt8, _ data: [UInt8] = []) -> [UInt8] {
        var bytes = [cmd0, cmd1, UInt8(data.count)] + data
        bytes.append(checksum(bytes))
        return bytes
    }

    public static func parse(_ raw: [UInt8]) -> Frame? {
        guard raw.count >= 4 else { return nil }
        let length = Int(raw[2])
        guard raw.count >= 4 + length else { return nil }
        guard checksum(raw[0 ..< 3 + length]) == raw[3 + length] else { return nil }
        return Frame(cmd0: raw[0], cmd1: raw[1], data: Array(raw[3 ..< 3 + length]))
    }

    /// `71 00 05 01 <token LE32> CC`, token = LE32(last 4 bytes of the BLE name) + 1.
    /// The pad answers `71 80` when accepted.
    public static func unlock(deviceName: String) -> [UInt8]? {
        let tail = Array(deviceName.utf8.suffix(4))
        guard tail.count == 4 else { return nil }
        let token = tail.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } &+ 1
        return frame(0x71, 0x00, [0x01] + le32(token))
    }

    /// Session info the official app sends right after unlocking (reply `71 81`).
    public static func sysInfo(unixTime: UInt32) -> [UInt8] {
        frame(0x71, 0x01, le32(unixTime) + le32(0))
    }

    /// Read every property (reply `72 80`, 4-byte records).
    public static let readAllProperties = frame(0x72, 0x00, [0x00])

    /// Write one property (reply `72 81`, data[1] == 0 means OK).
    public static func writeProperty(id: UInt8, value: UInt16) -> [UInt8] {
        frame(0x72, 0x01, [id] + le16(value))
    }

    /// Belt command over the vendor channel; used when the FTMS control point refuses.
    public static func tunnel(_ op: UInt8, _ params: [UInt8] = []) -> [UInt8] {
        frame(0x77, 0x01, [op] + params)
    }

    /// `72 80` reply: records of `[id, error, lo, hi]`; errored records are skipped.
    public static func propertyRecords(_ data: [UInt8]) -> [UInt8: UInt16] {
        var out: [UInt8: UInt16] = [:]
        for i in stride(from: 0, through: data.count - 4, by: 4) where data[i + 1] == 0 {
            out[data[i]] = UInt16(data[i + 2]) | UInt16(data[i + 3]) << 8
        }
        return out
    }

    /// Unsolicited `72 50` push (e.g. a setting changed with the remote): `[id, lo, hi]` records.
    public static func propertyPushRecords(_ data: [UInt8]) -> [UInt8: UInt16] {
        var out: [UInt8: UInt16] = [:]
        for i in stride(from: 0, through: data.count - 3, by: 3) {
            out[data[i]] = UInt16(data[i + 1]) | UInt16(data[i + 2]) << 8
        }
        return out
    }

    // MARK: Properties

    public enum Property {
        /// Bit 1 set: the pad's display shows miles.
        public static let units: UInt8 = 1
        /// Bit 15: auto-stop enabled; low bits: idle seconds.
        public static let autoStop: UInt8 = 2
        public static let lastError: UInt8 = 5
        public static let childLock: UInt8 = 6
        /// Bit 1: beeper, bit 3: indicator light.
        public static let switches: UInt8 = 8
        /// Bits 5–7: `TreadmillMode`.
        public static let deviceMode: UInt8 = 10
    }

    public static let milesBit: UInt16 = 1 << 1
    public static let autoStopBit: UInt16 = 1 << 15
    public static let beepBit: UInt16 = 1 << 1
    public static let lightBit: UInt16 = 1 << 3
    static let modeMask: UInt16 = 0b111 << 5

    public static func mode(from value: UInt16) -> TreadmillMode? {
        TreadmillMode(rawValue: (value & modeMask) >> 5)
    }

    public static func setting(mode: TreadmillMode, in value: UInt16) -> UInt16 {
        (value & ~modeMask) | (mode.rawValue << 5)
    }

    // MARK: FTMS characteristics

    public struct Telemetry: Equatable, Sendable {
        public var speedKmh: Double?
        public var distanceM: Int?
        public var elapsedS: Int?
        public var steps: Int?
        /// Total energy in kcal, as shown on the pad's display.
        public var kcal: Int?
    }

    /// FTMS Treadmill Data (0x2ACD). Fields follow the flags in order; bit 13 is
    /// KingSmith's step-count extension. Fields we don't show are skipped by size.
    public static func telemetry(_ raw: [UInt8]) -> Telemetry {
        var out = Telemetry()
        var reader = Reader(raw)
        guard let flags = reader.u16() else { return out }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        if !has(0) { out.speedKmh = reader.u16().map { Double($0) / 100 } }
        if has(1) { reader.skip(2) }                       // average speed
        if has(2) { out.distanceM = reader.u24() }         // total distance
        if has(3) { reader.skip(4) }                       // incline + ramp angle
        if has(4) { reader.skip(4) }                       // elevation gain + loss
        if has(5) { reader.skip(1) }                       // instantaneous pace
        if has(6) { reader.skip(1) }                       // average pace
        if has(7) {                                        // energy: total, per hour, per minute
            out.kcal = reader.u16()
            reader.skip(3)
        }
        if has(8) { reader.skip(1) }                       // heart rate
        if has(9) { reader.skip(1) }                       // metabolic equivalent
        if has(10) { out.elapsedS = reader.u16() }         // elapsed time
        if has(11) { reader.skip(2) }                      // remaining time
        if has(12) { reader.skip(4) }                      // force on belt + power
        if has(13) { out.steps = reader.u16() }            // KingSmith step count
        return out
    }

    /// Supported speed range (0x2AD4): min and max as u16 km/h × 100.
    public static func speedRange(_ raw: [UInt8]) -> ClosedRange<Double>? {
        var r = Reader(raw)
        guard let lo = r.u16(), let hi = r.u16(), lo > 0, hi > lo else { return nil }
        return Double(lo) / 100 ... Double(hi) / 100
    }

    // MARK: Helpers

    static func checksum<C: Collection<UInt8>>(_ bytes: C) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard offset + n <= bytes.count else { offset = bytes.count; return nil }
            defer { offset += n }
            return bytes[offset ..< offset + n]
        }
        mutating func skip(_ n: Int) { _ = take(n) }
        mutating func u16() -> Int? {
            take(2).map { Int($0.first!) | Int($0.last!) << 8 }
        }
        mutating func u24() -> Int? {
            take(3).map { s in s.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        }
    }
}

public enum Metrics {
    /// ACSM walking equation (level grade). The pad reports no energy data,
    /// so calories are estimated here; expect roughly ±15%.
    public static func kcalPerMinute(speedKmh: Double, weightKg: Double) -> Double {
        guard speedKmh > 0 else { return 0 }
        let metersPerMinute = speedKmh * 1000 / 60
        let vo2 = 0.1 * metersPerMinute + 3.5  // ml/kg/min
        return vo2 * weightKg / 200
    }
}
