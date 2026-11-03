import CoreBluetooth
import Foundation
import AppKit
import IOKit.ps
import Observation
import os

/// Plays the M5StickS3's part: advertises the stick service, streams
/// push-to-talk audio as ADPCM notifications, and shows what the phone reports.
@MainActor
@Observable
final class StickPeripheral: NSObject {
    enum Screen: Equatable {
        case off
        case waiting
        case ready
        case recording(since: Date)
        case transcribing
        case done(String)
        case failed(String)
        case finding
    }

    private(set) var screen: Screen = .off
    private(set) var isConnected = false
    private(set) var lastPacketSize = 0

    @ObservationIgnored private var manager: CBPeripheralManager!
    @ObservationIgnored private let tx = CBMutableCharacteristic(
        type: StickProtocol.txUUID, properties: [.notify], value: nil, permissions: [.readable]
    )
    @ObservationIgnored private let rx = CBMutableCharacteristic(
        type: StickProtocol.rxUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable]
    )
    @ObservationIgnored private let battery = CBMutableCharacteristic(
        type: StickProtocol.batteryLevelUUID, properties: [.read, .notify], value: nil, permissions: [.readable]
    )
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var findTimer: Timer?
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let logger = Logger(subsystem: "StickSim", category: "ble")

    @ObservationIgnored private var central: CBCentral?
    @ObservationIgnored private var outbox: [Data] = []
    @ObservationIgnored private var pending: [Int16] = []
    @ObservationIgnored private var encoder = IMAADPCM.State()
    @ObservationIgnored private var session: UInt8 = 0
    @ObservationIgnored private var seq: UInt16 = 0
    @ObservationIgnored private var recordingStart: Date?
    /// Kept for the phone's settings page; the simulator has no screen or speaker to apply them to.
    @ObservationIgnored private var settings = StickSettings()

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
        mic.onSamples = { [weak self] samples in self?.append(samples) }
    }

    var isRecording: Bool {
        if case .recording = screen { return true }
        return false
    }

    // MARK: Push-to-talk

    func pressButton() async {
        guard isConnected, !isRecording else { return }
        // Pressing the stick is how you tell it "found you".
        if case .finding = screen {
            setFinding(false)
            return
        }
        guard await mic.requestAccess() else {
            screen = .failed("麥克風權限未開")
            return
        }
        session &+= 1
        seq = 0
        encoder = IMAADPCM.State()
        pending = []
        send(StickProtocol.start(session: session))
        do {
            try mic.start()
            recordingStart = .now
            screen = .recording(since: .now)
        } catch {
            send(StickProtocol.cancel(session: session))
            screen = .failed("麥克風無法啟動")
        }
    }

    func releaseButton() {
        guard isRecording else { return }
        mic.stop()
        let duration = Date.now.timeIntervalSince(recordingStart ?? .now)
        guard duration >= 0.3 else {
            send(StickProtocol.cancel(session: session))
            screen = .ready
            return
        }
        flush(all: true)
        send(StickProtocol.end(session: session, packetCount: seq))
        screen = .transcribing
    }

    // MARK: Audio → packets

    private var samplesPerPacket: Int {
        let size = central?.maximumUpdateValueLength ?? 20
        return max(size - StickProtocol.audioHeaderSize, 2) * 2
    }

    private func append(_ samples: [Int16]) {
        guard isRecording else { return }
        pending.append(contentsOf: samples)
        flush(all: false)
    }

    private func flush(all: Bool) {
        let chunk = samplesPerPacket
        while pending.count >= chunk || (all && !pending.isEmpty) {
            let count = min(chunk, pending.count)
            let block = IMAADPCM.encode(pending[0..<count], state: &encoder)
            pending.removeFirst(count)
            send(StickProtocol.audio(session: session, seq: seq, block: block))
            seq &+= 1
        }
    }

    private func send(_ packet: Data) {
        outbox.append(packet)
        lastPacketSize = packet.count
        pump()
    }

    /// Notifications are queued by CoreBluetooth; when its queue is full,
    /// `updateValue` returns false and we resume from `isReady`.
    private func pump() {
        while let next = outbox.first {
            guard manager.updateValue(next, for: tx, onSubscribedCentrals: nil) else { return }
            outbox.removeFirst()
        }
    }

    private func handle(_ value: Data) {
        guard value.count >= 2, let type = StickProtocol.PhoneMessage(rawValue: value[value.startIndex]) else { return }
        if type == .find {
            setFinding(value.count >= 3 && value[value.startIndex + 2] != 0)
            return
        }
        if type == .settings {
            settings.apply(pairs: value.dropFirst(2))
            send(StickProtocol.settingsReport(settings))
            return
        }
        guard value[value.startIndex + 1] == session else { return }
        let text = String(decoding: value.dropFirst(2), as: UTF8.self)
        switch type {
        case .transcribing: screen = .transcribing
        case .done: screen = .done(text)
        case .error: screen = .failed(text)
        case .find, .settings: break
        }
    }

    /// Chirps once a second until told to stop; the real stick does the same
    /// on its speaker.
    private func setFinding(_ on: Bool) {
        findTimer?.invalidate()
        findTimer = nil
        guard on else {
            if case .finding = screen { screen = isConnected ? .ready : .waiting }
            return
        }
        guard !isRecording else { return }
        screen = .finding
        NSSound(named: "Ping")?.play()
        findTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in NSSound(named: "Ping")?.play() }
        }
    }

    private func startAdvertising() {
        let service = CBMutableService(type: StickProtocol.serviceUUID, primary: true)
        service.characteristics = [tx, rx]
        let batteryService = CBMutableService(type: StickProtocol.batteryServiceUUID, primary: true)
        batteryService.characteristics = [battery]
        manager.removeAllServices()
        manager.add(service)
        manager.add(batteryService)
    }

    /// The real Stick reads its PMIC; the simulator stands in with this Mac's
    /// battery, or 100% on a Mac without one.
    static func batteryLevel() -> UInt8 {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return 100 }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return UInt8(clamping: current * 100 / max)
        }
        return 100
    }

    private func notifyBattery() {
        manager.updateValue(Data([Self.batteryLevel()]), for: battery, onSubscribedCentrals: nil)
    }
}

extension StickPeripheral: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.debug("state \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            startAdvertising()
            screen = .waiting
        } else {
            screen = .off
            isConnected = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            logger.error("add service failed: \(error.localizedDescription)")
            return
        }
        guard service.uuid == StickProtocol.serviceUUID else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: StickProtocol.localName,
            CBAdvertisementDataServiceUUIDsKey: [StickProtocol.serviceUUID],
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == StickProtocol.batteryLevelUUID {
            notifyBattery()
            batteryTimer?.invalidate()
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.notifyBattery() }
            }
            return
        }
        logger.debug("subscribed, max update \(central.maximumUpdateValueLength)")
        self.central = central
        isConnected = true
        screen = .ready
        send(StickProtocol.settingsReport(settings))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == StickProtocol.batteryLevelUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        request.value = Data([Self.batteryLevel()])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == StickProtocol.batteryLevelUUID {
            batteryTimer?.invalidate()
            return
        }
        if isRecording { mic.stop() }
        setFinding(false)
        self.central = nil
        outbox = []
        isConnected = false
        screen = .waiting
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let value = request.value { handle(value) }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
