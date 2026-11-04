import CoreBluetooth
import Foundation
import Observation
import os

public enum ConnectionPhase: Equatable, Sendable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case ready
}

public enum TreadmillError: LocalizedError {
    case timeout(String)
    case refused(op: UInt8, result: UInt8)
    case missingCharacteristic(String)
    case disconnected
    case notReady
    case stillAsleep

    public var errorDescription: String? {
        switch self {
        case .timeout(let what): "Treadmill didn't answer (\(what))."
        case .refused(let op, let result): "Treadmill refused command 0x\(String(op, radix: 16)) (code \(result))."
        case .missingCharacteristic(let id): "This doesn't look like a WalkingPad Z1 (missing \(id))."
        case .disconnected: "Treadmill disconnected."
        case .notReady: "Not connected to the treadmill."
        case .stillAsleep: "The treadmill stays in standby. Try again, or use the remote."
        }
    }
}

private let log = Logger(subsystem: "local.treadmill", category: "ble")

/// Bluetooth client for the KingSmith WalkingPad Z1.
///
/// Connection sequence: scan by name → connect → subscribe to the supplement
/// notify channel → send the unlock frame → wait for `71 80` → subscribe to the
/// FTMS characteristics → read settings. After that, belt commands go through
/// the FTMS control point; settings go through vendor property writes.
///
/// Everything runs on the main actor; CoreBluetooth delivers on the main queue.
@MainActor
@Observable
public final class Treadmill: NSObject {

    // MARK: Observable state

    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var deviceName: String?
    public private(set) var lastError: String?

    public private(set) var speedKmh: Double = 0
    public private(set) var targetSpeedKmh: Double?
    public private(set) var distanceM = 0
    public private(set) var elapsedS = 0
    public private(set) var steps = 0
    public private(set) var calories: Double = 0
    public private(set) var isRunning = false
    /// Paused (counters kept) as opposed to stopped (session ended).
    public private(set) var isPaused = false
    /// True once the pad has sent its own calorie count; otherwise `calories` is estimated from `weightKg`.
    public private(set) var padReportsCalories = false
    public private(set) var speedRange: ClosedRange<Double> = 1.6 ... 6.4
    public private(set) var properties: [UInt8: UInt16] = [:]
    public private(set) var busy = false

    /// Used for the calorie estimate.
    public var weightKg: Double = 75

    public var mode: TreadmillMode? {
        properties[Z1Protocol.Property.deviceMode].flatMap(Z1Protocol.mode(from:))
    }
    public var usesMiles: Bool { isOn(.miles) }

    // MARK: BLE plumbing

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var chars: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var lastWrite: [CBUUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var hasControl = false
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var scanTimeout: Task<Void, Never>?
    @ObservationIgnored private var pendingSpeed: Double?
    @ObservationIgnored private var speedSender: Task<Void, Never>?
    @ObservationIgnored private var lastFrameAt: ContinuousClock.Instant?
    @ObservationIgnored private var failedSetups = 0

    // CBUUID is immutable, so sharing it is safe.
    private enum Signal: @unchecked Sendable {
        case connected
        case servicesDiscovered
        case characteristicsDiscovered(CBUUID)
        case notifying(CBUUID)
        case value(CBUUID, [UInt8])
    }

    private struct Waiter {
        let id = UUID()
        let match: (Signal) -> Bool
        let continuation: CheckedContinuation<Signal, Error>
    }

    private static let uuid = (
        ftms: CBUUID(string: Z1Protocol.ftmsService),
        supplement: CBUUID(string: Z1Protocol.supplementService),
        supNotify: CBUUID(string: Z1Protocol.supplementNotifyChar),
        supWrite: CBUUID(string: Z1Protocol.supplementWriteChar),
        data: CBUUID(string: Z1Protocol.treadmillDataChar),
        status: CBUUID(string: Z1Protocol.machineStatusChar),
        control: CBUUID(string: Z1Protocol.controlPointChar),
        speedRange: CBUUID(string: Z1Protocol.speedRangeChar)
    )

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Connection

    /// Scan for the treadmill and connect. Called automatically when Bluetooth turns on.
    public func connect() {
        guard central.state == .poweredOn, phase == .idle else { return }
        if userDisconnected { failedSetups = 0 }
        userDisconnected = false
        phase = .scanning
        log.info("scanning")
        central.scanForPeripherals(withServices: nil)
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            self.central.stopScan()
            self.phase = .idle
            self.lastError = "No treadmill found. Is it switched on and not connected to the KS Fit app?"
        }
    }

    public func disconnect() {
        userDisconnected = true
        scanTimeout?.cancel()
        if phase == .scanning { central.stopScan(); phase = .idle }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func found(_ p: CBPeripheral, name: String) {
        scanTimeout?.cancel()
        central.stopScan()
        peripheral = p
        deviceName = name
        p.delegate = self
        phase = .connecting
        log.info("connecting to \(name, privacy: .public)")
        Task { await setUp(p, name: name) }
    }

    private func setUp(_ p: CBPeripheral, name: String) async {
        do {
            try await wait("connect", timeout: .seconds(15)) {
                if case .connected = $0 { true } else { false }
            } trigger: { self.central.connect(p) }

            try await wait("service discovery") {
                if case .servicesDiscovered = $0 { true } else { false }
            } trigger: { p.discoverServices([Self.uuid.ftms, Self.uuid.supplement]) }

            for service in p.services ?? [] {
                try await wait("characteristic discovery") {
                    if case .characteristicsDiscovered(service.uuid) = $0 { true } else { false }
                } trigger: { p.discoverCharacteristics(nil, for: service) }
                for c in service.characteristics ?? [] { chars[c.uuid] = c }
            }

            // 1. The supplement channel must be listening before any vendor write.
            try await subscribe(Self.uuid.supNotify)

            // 2. Unlock. Until this lands the pad ignores FTMS and stays silent.
            guard let unlock = Z1Protocol.unlock(deviceName: name) else { throw TreadmillError.notReady }
            _ = try await vendor(unlock, timeout: .seconds(10))
            log.info("unlocked")

            // 3. FTMS telemetry, machine status, control-point indications.
            try await subscribe(Self.uuid.data)
            try await subscribe(Self.uuid.status)
            try await subscribe(Self.uuid.control)

            // 4. Same init the official app performs; the pad works without it, so best-effort.
            _ = try? await vendor(Z1Protocol.sysInfo(unixTime: UInt32(Date().timeIntervalSince1970)))
            if let reply = try? await vendor(Z1Protocol.readAllProperties) {
                properties = Z1Protocol.propertyRecords(reply.data)
            }
            if let raw = try? await read(Self.uuid.speedRange), let range = Z1Protocol.speedRange(raw) {
                speedRange = range
            }
            phase = .ready
            failedSetups = 0
            log.info("ready, properties: \(String(describing: self.properties), privacy: .public)")
        } catch {
            log.error("setup failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            failedSetups += 1
            if failedSetups >= 3 { userDisconnected = true }  // stop retrying; user can press Connect
            central.cancelPeripheralConnection(p)
        }
    }

    private func handleDisconnect(_ error: Error?) {
        log.info("disconnected \(error?.localizedDescription ?? "", privacy: .public)")
        failAll(TreadmillError.disconnected)
        peripheral = nil
        chars = [:]
        hasControl = false
        isRunning = false
        isPaused = false
        speedKmh = 0
        targetSpeedKmh = nil
        lastFrameAt = nil
        phase = central.state == .poweredOn ? .idle : .bluetoothOff
        if !userDisconnected {
            // Pad switched off, out of range, or a hiccup: keep looking for it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.connect()
            }
        }
    }

    // MARK: Belt commands

    /// Start or resume the belt. With a speed, go straight to it once the belt is moving.
    public func start(at kmh: Double? = nil) {
        if isRunning {
            if let kmh { setSpeed(kmh) }
            return  // the pad refuses START on a moving belt
        }
        run("start") { [self] in
            if mode == .standby { try await wake() }
            try await control([Z1Protocol.Op.startOrResume], tunnel: Z1Protocol.tunnel(0x07))
            targetSpeedKmh = nil
            if let kmh {
                let value = clampSpeed(kmh)
                targetSpeedKmh = value
                let params = Z1Protocol.speedParams(value)
                try await control([Z1Protocol.Op.setSpeed] + params, tunnel: Z1Protocol.tunnel(0x02, params))
            }
        }
    }

    public func pause() {
        run("pause") { [self] in
            try await control([Z1Protocol.Op.stopOrPause, Z1Protocol.Op.pause],
                              tunnel: Z1Protocol.tunnel(0x08, [0x02]))
        }
    }

    /// Stops the belt and ends the session (the pad resets its counters).
    public func stop() {
        run("stop") { [self] in
            try await control([Z1Protocol.Op.stopOrPause, Z1Protocol.Op.stop],
                              tunnel: Z1Protocol.tunnel(0x08, [0x01]))
        }
    }

    /// Request a belt speed. Rapid calls are coalesced: only the latest target is sent.
    public func setSpeed(_ kmh: Double) {
        let value = clampSpeed(kmh)
        targetSpeedKmh = value
        pendingSpeed = value
        guard speedSender == nil else { return }
        speedSender = Task { [weak self] in
            while let self, let next = self.pendingSpeed {
                self.pendingSpeed = nil
                await self.perform("speed") {
                    let params = Z1Protocol.speedParams(next)
                    try await self.control([Z1Protocol.Op.setSpeed] + params,
                                           tunnel: Z1Protocol.tunnel(0x02, params))
                }
            }
            self?.speedSender = nil
        }
    }

    /// The pad takes speeds in 0.01 km/h, so mph values like 1.5 land exactly.
    private func clampSpeed(_ kmh: Double) -> Double {
        (min(max(kmh, speedRange.lowerBound), speedRange.upperBound) * 100).rounded() / 100
    }

    // MARK: Settings

    /// Standby is the Z1's sleep mode. (The Z1 refuses the "auto" mode other WalkingPads have.)
    public func setStandby(_ on: Bool) {
        run("standby") { [self] in
            if on, isRunning || isPaused {
                try await control([Z1Protocol.Op.stopOrPause, Z1Protocol.Op.stop],
                                  tunnel: Z1Protocol.tunnel(0x08, [0x01]))
            }
            if on {
                try await writeMode(.standby)
            } else {
                try await wake()
                if mode == .standby { throw TreadmillError.stillAsleep }
            }
        }
    }

    /// The Z1 refuses "manual" as a property write (code 9). An FTMS reset wakes it
    /// without moving the belt, but also revokes control, so the next command re-requests it.
    private func wake() async throws {
        try await requestControlIfNeeded()
        let result = try await controlPoint([Z1Protocol.Op.reset])
        hasControl = false
        log.info("wake via reset -> result \(result)")
        try await refreshProperties()
    }

    private func refreshProperties() async throws {
        let reply = try await vendor(Z1Protocol.readAllProperties)
        properties.merge(Z1Protocol.propertyRecords(reply.data)) { $1 }
    }

    /// On/off settings stored on the pad.
    public enum Setting: CaseIterable, Sendable {
        case miles, beep, light, childLock, autoStop

        var property: UInt8 {
            switch self {
            case .miles: Z1Protocol.Property.units
            case .beep, .light: Z1Protocol.Property.switches
            case .childLock: Z1Protocol.Property.childLock
            case .autoStop: Z1Protocol.Property.autoStop
            }
        }

        var mask: UInt16 {
            switch self {
            case .miles: Z1Protocol.milesBit
            case .beep: Z1Protocol.beepBit
            case .light: Z1Protocol.lightBit
            case .childLock: 1
            case .autoStop: Z1Protocol.autoStopBit
            }
        }
    }

    public func isOn(_ setting: Setting) -> Bool {
        (properties[setting.property] ?? 0) & setting.mask != 0
    }

    public func set(_ setting: Setting, _ on: Bool) {
        run("\(setting)") { [self] in
            let current = properties[setting.property] ?? 0
            try await writeProperty(setting.property, on ? current | setting.mask : current & ~setting.mask)
        }
    }

    private func writeMode(_ mode: TreadmillMode) async throws {
        let current = properties[Z1Protocol.Property.deviceMode] ?? 0
        try await writeProperty(Z1Protocol.Property.deviceMode, Z1Protocol.setting(mode: mode, in: current))
    }

    private func writeProperty(_ id: UInt8, _ value: UInt16) async throws {
        guard properties[id] != value else { return }  // the pad answers "unchanged" with an error code
        let reply = try await vendor(Z1Protocol.writeProperty(id: id, value: value))
        guard reply.data.count < 2 || reply.data[1] == 0 else {
            throw TreadmillError.refused(op: 0x72, result: reply.data[1])
        }
        properties[id] = value
    }

    // MARK: Command plumbing

    /// Run a command in the background, one at a time, reporting failures in `lastError`.
    private func run(_ label: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { await perform(label, body) }
    }

    /// Serialize commands: each waits for the previous one to finish.
    private func perform(_ label: String, _ body: @escaping @MainActor () async throws -> Void) async {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            guard self.phase == .ready else { self.lastError = TreadmillError.notReady.localizedDescription; return }
            self.busy = true
            defer { self.busy = false }
            do {
                try await body()
                self.lastError = nil
            } catch {
                log.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.lastError = error.localizedDescription
            }
        }
        commandTail = task
        await task.value
    }

    /// FTMS control-point command with the recoveries the pad needs:
    /// re-request control on code 5, retry once on code 4, then fall back to the vendor tunnel.
    private func control(_ bytes: [UInt8], tunnel: [UInt8]) async throws {
        try await requestControlIfNeeded()
        var result: UInt8
        do {
            result = try await controlPoint(bytes)
        } catch TreadmillError.timeout {
            // Silently ignored usually means we lost control: ask again, retry once.
            log.info("control timeout, re-requesting control")
            hasControl = false
            do {
                try await requestControlIfNeeded()
                result = try await controlPoint(bytes)
            } catch TreadmillError.timeout {
                result = Z1Protocol.Result.failed  // last resort: vendor tunnel below
            }
        }
        if result == Z1Protocol.Result.notPermitted {
            hasControl = false
            _ = try await controlPoint([Z1Protocol.Op.requestControl])
            hasControl = true
            result = try await controlPoint(bytes)
        }
        if result == Z1Protocol.Result.failed {
            try await Task.sleep(for: .seconds(1.5))
            result = (try? await controlPoint(bytes)) ?? Z1Protocol.Result.failed
        }
        if result == Z1Protocol.Result.failed {
            let reply = try await vendor(tunnel)
            let status = reply.data.count >= 2 ? reply.data[1] : 0xFF
            guard status == 0 || status == 0x81 else { throw TreadmillError.refused(op: bytes[0], result: status) }
            return
        }
        guard result == Z1Protocol.Result.success else { throw TreadmillError.refused(op: bytes[0], result: result) }
    }

    private func requestControlIfNeeded() async throws {
        guard !hasControl else { return }
        let r = try await controlPoint([Z1Protocol.Op.requestControl])
        guard r == Z1Protocol.Result.success else { throw TreadmillError.refused(op: 0, result: r) }
        hasControl = true
    }

    /// Write to the control point; returns the result code from its `80 <op> <result>` indication.
    private func controlPoint(_ bytes: [UInt8]) async throws -> UInt8 {
        let c = try characteristic(Self.uuid.control)
        await pace(c.uuid)
        let signal = try await wait("control 0x\(String(bytes[0], radix: 16))", timeout: .seconds(3)) {
            if case .value(Self.uuid.control, let v) = $0, v.count >= 3, v[0] == 0x80, v[1] == bytes[0] { true } else { false }
        } trigger: { self.peripheral?.writeValue(Data(bytes), for: c, type: .withResponse) }
        guard case .value(_, let v) = signal else { return 0 }
        log.info("control \(hex(bytes), privacy: .public) -> result \(v[2])")
        return v[2]
    }

    /// Send a vendor frame and await the reply with the same cmd0 and cmd1 | 0x80.
    private func vendor(_ frame: [UInt8], timeout: Duration = .seconds(3)) async throws -> Z1Protocol.Frame {
        let c = try characteristic(Self.uuid.supWrite)
        let (cmd0, cmd1) = (frame[0], frame[1] | 0x80)
        await pace(c.uuid)
        let signal = try await wait(String(format: "vendor %02x %02x", frame[0], frame[1]), timeout: timeout) {
            if case .value(Self.uuid.supNotify, let v) = $0, let f = Z1Protocol.parse(v),
               f.cmd0 == cmd0, f.cmd1 == cmd1 { true } else { false }
        } trigger: { self.peripheral?.writeValue(Data(frame), for: c, type: .withoutResponse) }
        guard case .value(_, let v) = signal, let reply = Z1Protocol.parse(v) else { throw TreadmillError.notReady }
        log.info("vendor \(hex(frame), privacy: .public) -> \(hex(v), privacy: .public)")
        return reply
    }

    private func subscribe(_ uuid: CBUUID) async throws {
        let c = try characteristic(uuid)
        try await wait("subscribe \(uuid)") {
            if case .notifying(uuid) = $0 { true } else { false }
        } trigger: { self.peripheral?.setNotifyValue(true, for: c) }
    }

    private func read(_ uuid: CBUUID) async throws -> [UInt8] {
        let c = try characteristic(uuid)
        let signal = try await wait("read \(uuid)") {
            if case .value(uuid, _) = $0 { true } else { false }
        } trigger: { self.peripheral?.readValue(for: c) }
        guard case .value(_, let v) = signal else { return [] }
        return v
    }

    private func characteristic(_ uuid: CBUUID) throws -> CBCharacteristic {
        guard peripheral != nil else { throw TreadmillError.disconnected }
        guard let c = chars[uuid] else { throw TreadmillError.missingCharacteristic(uuid.uuidString) }
        return c
    }

    /// The pad silently drops writes that arrive less than 400 ms apart on the same channel.
    private func pace(_ uuid: CBUUID) async {
        if let last = lastWrite[uuid] {
            let remaining = Z1Protocol.minWriteInterval - (ContinuousClock.now - last)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        lastWrite[uuid] = ContinuousClock.now
    }

    // MARK: Waiting for BLE events

    /// Register a waiter, then fire `trigger`. Registering first means a fast
    /// reply can never slip past us.
    @discardableResult
    private func wait(_ what: String, timeout: Duration = .seconds(10),
                      match: @escaping (Signal) -> Bool,
                      trigger: () -> Void) async throws -> Signal {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(match: match, continuation: continuation)
            let id = waiter.id
            waiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve(id, .failure(TreadmillError.timeout(what)))
            }
            trigger()
        }
    }

    private func resolve(_ id: UUID, _ result: Result<Signal, Error>) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(with: result)
    }

    private func emit(_ signal: Signal) {
        for waiter in waiters where waiter.match(signal) {
            resolve(waiter.id, .success(signal))
        }
    }

    private func failAll(_ error: Error) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    // MARK: Incoming data

    private func received(_ bytes: [UInt8], from uuid: CBUUID) {
        log.debug("<- \(uuid.uuidString, privacy: .public) \(hex(bytes), privacy: .public)")
        switch uuid {
        case Self.uuid.data:
            apply(Z1Protocol.telemetry(bytes))
        case Self.uuid.status:
            switch bytes.first {
            case 0x04: isRunning = true; isPaused = false
            case 0x01, 0x02:  // 02 01 = stopped, 02 02 = paused
                isRunning = false
                isPaused = bytes.count > 1 && bytes[1] == 0x02
                speedKmh = 0
            case 0xFF: hasControl = false
            default: break
            }
        case Self.uuid.supNotify:
            if let f = Z1Protocol.parse(bytes), f.cmd0 == 0x72, f.cmd1 == 0x50 {
                properties.merge(Z1Protocol.propertyPushRecords(f.data)) { $1 }
            }
        default:
            break
        }
        emit(.value(uuid, bytes))
    }

    private func apply(_ t: Z1Protocol.Telemetry) {
        let now = ContinuousClock.now
        if let elapsed = t.elapsedS {
            if elapsed < elapsedS { calories = 0 }  // the pad started a new session
            elapsedS = elapsed
        }
        if let kcal = t.kcal {
            padReportsCalories = true
            calories = Double(kcal)
        }
        if let speed = t.speedKmh {
            if !padReportsCalories, let last = lastFrameAt, speed > 0 {
                let minutes = min((now - last) / .seconds(1), 5) / 60
                calories += Metrics.kcalPerMinute(speedKmh: speed, weightKg: weightKg) * minutes
            }
            speedKmh = speed
            isRunning = speed > 0
            if targetSpeedKmh == nil, speed > 0 { targetSpeedKmh = speed }
        }
        if let d = t.distanceM { distanceM = d }
        if let s = t.steps { steps = s }
        lastFrameAt = now
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - CoreBluetooth delegates (delivered on the main queue)

extension Treadmill: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if phase == .bluetoothOff || phase == .unauthorized { phase = .idle }
            if !userDisconnected { connect() }
        case .unauthorized:
            phase = .unauthorized
        default:
            failAll(TreadmillError.disconnected)
            phase = .bluetoothOff
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard phase == .scanning, let name else { return }
        log.debug("saw \(name, privacy: .public) rssi \(RSSI.intValue)")
        guard Z1Protocol.isTreadmillName(name) else { return }
        found(peripheral, name: name)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription
        handleDisconnect(error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        handleDisconnect(error)
    }
}

extension Treadmill: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failAll(error) } else { emit(.servicesDiscovered) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error { failAll(error) } else { emit(.characteristicsDiscovered(service.uuid)) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error { failAll(error) } else { emit(.notifying(characteristic.uuid)) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        received([UInt8](value), from: characteristic.uuid)
    }
}
