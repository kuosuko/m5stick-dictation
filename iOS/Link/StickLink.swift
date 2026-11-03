import CoreBluetooth
import Foundation
import Observation
import os

/// The phone's side of the BLE link. Remembers one stick and keeps a pending
/// connection to it, so iOS relaunches/wakes the app when the stick speaks.
@MainActor
@Observable
final class StickLink: NSObject {
    enum Status: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case connected
    }

    /// The pairing sheet's state, from first sighting to connected.
    enum Pairing: Equatable {
        case found(name: String)
        case connecting(name: String)
        case connected(name: String)

        var name: String {
            switch self {
            case .found(let name), .connecting(let name), .connected(let name): name
            }
        }
    }

    private(set) var status: Status = .searching
    private(set) var pairing: Pairing?
    /// 0–100 from the Stick's Battery Service; nil until it reports.
    private(set) var batteryLevel: Int?
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    /// The most recent packet levels, oldest first, for the live meter.
    private(set) var levels: [Double] = []
    var hasPairedStick: Bool { pairedID != nil }
    /// How close the stick seems while finding it, 0 (barely heard) to 1
    /// (touching); nil when nothing has been heard for a few seconds.
    private(set) var signal: Double?
    /// The last raw reading in dBm, for showing as a number.
    private(set) var rssi: Int?
    /// The stick is chirping on our request.
    private(set) var isSounding = false
    /// What the connected stick lets you adjust; nil until it reports.
    private(set) var settings: StickSettings?
    /// The stick said it was going to deep sleep; it reconnects when pressed.
    private(set) var isAsleep = false

    @ObservationIgnored var onRecording: ((Recording) -> Void)?
    @ObservationIgnored var onRecordingChanged: ((Bool) -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var candidate: CBPeripheral?
    /// Sticks the user closed the sheet for; not offered again this launch.
    @ObservationIgnored private var declined: Set<UUID> = []
    @ObservationIgnored private var rx: CBCharacteristic?
    @ObservationIgnored private var assembler = RecordingAssembler()
    @ObservationIgnored private var finding = false
    @ObservationIgnored private var rssiTimer: Timer?
    /// Reports that arrive while a slider is moving are older than what it shows.
    @ObservationIgnored private var lastSettingsWrite = Date.distantPast
    @ObservationIgnored private var lastHeard = Date.distantPast
    @ObservationIgnored private let logger = Logger(subsystem: "DuoDictate", category: "ble")

    private static let pairedKey = "pairedStickID"
    static let meterBars = 24
    private static let restoreID = "stick-central"

    private var pairedID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.pairedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.pairedKey) }
    }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
        )
    }

    // MARK: Pairing

    func pair() {
        guard let candidate, case .found(let name) = pairing else { return }
        central.stopScan()
        pairedID = candidate.identifier
        pairing = .connecting(name: name)
        connect(candidate)
        self.candidate = nil
    }

    func dismissPairing() {
        if case .found = pairing, let candidate { declined.insert(candidate.identifier) }
        candidate = nil
        pairing = nil
    }

    func forget() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        batteryLevel = nil
        settings = nil
        isAsleep = false
        pairedID = nil
        status = .searching
        scan()
    }

    func reply(_ type: StickProtocol.PhoneMessage, session: UInt8, text: String = "") {
        guard let peripheral, let rx else { return }
        peripheral.writeValue(StickProtocol.phone(type, session: session, text: text), for: rx, type: .withResponse)
    }

    // MARK: Finding

    /// Samples the link's signal strength a few times a second: over the
    /// connection when there is one, else from the stick's advertisements.
    func startFinding() {
        guard !finding else { return }
        finding = true
        signal = nil
        rssi = nil
        lastHeard = .distantPast
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSignal() }
        }
        listenForAdvertisements()
    }

    func stopFinding() {
        guard finding else { return }
        finding = false
        rssiTimer?.invalidate()
        rssiTimer = nil
        signal = nil
        rssi = nil
        if isSounding { setSound(false) }
        if pairedID != nil, central.isScanning { central.stopScan() }
    }

    /// Takes effect on the stick at once; it saves them and reports back.
    func apply(_ new: StickSettings) {
        guard let peripheral, let rx, status == .connected else { return }
        settings = new
        lastSettingsWrite = .now
        peripheral.writeValue(StickProtocol.settings(new), for: rx, type: .withResponse)
    }

    func setSound(_ on: Bool) {
        guard let peripheral, let rx, status == .connected else { return }
        isSounding = on
        peripheral.writeValue(StickProtocol.find(on: on), for: rx, type: .withResponse)
    }

    private func sampleSignal() {
        if status == .connected, let peripheral {
            peripheral.readRSSI()
        } else {
            listenForAdvertisements()
        }
        // Nothing for a while: the stick is off, or out of earshot.
        if signal != nil, Date.now.timeIntervalSince(lastHeard) > 3 {
            signal = nil
            rssi = nil
        }
    }

    /// A disconnected stick still advertises; duplicates are wanted here,
    /// since every one carries a fresh RSSI.
    private func listenForAdvertisements() {
        guard finding, status != .connected, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [StickProtocol.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Roughly -45 dBm against the phone, -95 dBm about to drop out; an
    /// exponential average keeps the reading from jumping on every sample.
    private func heard(rssi: NSNumber) {
        let value = rssi.doubleValue
        guard finding, value < 0, value > -127 else { return }
        let proximity = min(max((value + 95) / 50, 0), 1)
        lastHeard = .now
        self.rssi = Int(value)
        signal = signal.map { $0 + (proximity - $0) * 0.3 } ?? proximity
    }

    // MARK: Connection

    private func resume() {
        if let id = pairedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            scan()
        }
    }

    private func scan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        status = .searching
        central.scanForPeripherals(withServices: [StickProtocol.serviceUUID])
    }

    /// No timeout on purpose: iOS keeps the request alive and connects
    /// whenever the stick comes back in range, even with the app suspended.
    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        status = .connecting
        central.connect(target)
    }

    private func receive(_ value: Data) {
        if value.first == StickProtocol.StickMessage.sleeping.rawValue {
            isAsleep = true
            return
        }
        if let report = StickSettings(report: value) {
            if Date.now.timeIntervalSince(lastSettingsWrite) > 0.5 { settings = report }
            // The stick's screen follows the app's language.
            if let language = report.language, language != .app {
                var corrected = report
                corrected.language = .app
                apply(corrected)
            }
            return
        }
        switch assembler.receive(value) {
        case .started:
            isRecording = true
            recordingStartedAt = .now
            levels = []
            onRecordingChanged?(true)
        case .level(let level):
            levels = Array((levels + [level]).suffix(Self.meterBars))
        case .finished(var recording):
            isRecording = false
            recording.startedAt = recordingStartedAt
            onRecording?(recording)
        case .cancelled:
            isRecording = false
            onRecordingChanged?(false)
        case nil:
            break
        }
    }
}

extension StickLink: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: resume()
        case .unauthorized: status = .unauthorized
        default: status = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        if let match = restored.first(where: { $0.identifier == pairedID }) {
            peripheral = match
            match.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if finding, peripheral.identifier == pairedID {
            heard(rssi: RSSI)
            return
        }
        guard pairedID == nil, pairing == nil, !declined.contains(peripheral.identifier) else { return }
        candidate = peripheral
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        pairing = .found(name: advertised ?? peripheral.name ?? StickProtocol.localName)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.debug("connected")
        if finding, central.isScanning { central.stopScan() }
        peripheral.discoverServices([StickProtocol.serviceUUID, StickProtocol.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("connect failed: \(error?.localizedDescription ?? "-")")
        if peripheral.identifier == pairedID { connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rx = nil
        isRecording = false
        isSounding = false
        batteryLevel = nil
        settings = nil
        if peripheral.identifier == pairedID { connect(peripheral) }
        listenForAdvertisements()
    }
}

extension StickLink: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case StickProtocol.serviceUUID:
                peripheral.discoverCharacteristics([StickProtocol.txUUID, StickProtocol.rxUUID], for: service)
            case StickProtocol.batteryServiceUUID:
                peripheral.discoverCharacteristics([StickProtocol.batteryLevelUUID], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case StickProtocol.txUUID: peripheral.setNotifyValue(true, for: characteristic)
            case StickProtocol.rxUUID: rx = characteristic
            case StickProtocol.batteryLevelUUID:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == StickProtocol.txUUID, characteristic.isNotifying else { return }
        status = .connected
        isAsleep = false
        if case .connecting(let name) = pairing { pairing = .connected(name: name) }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        heard(rssi: RSSI)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case StickProtocol.txUUID: receive(value)
        case StickProtocol.batteryLevelUUID: batteryLevel = value.first.map { min(Int($0), 100) }
        default: break
        }
    }
}
