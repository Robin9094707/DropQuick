import Foundation
import CoreBluetooth

/// Scans only for Quick Share Fast Initiation. A BLE beacon is a hint, not a
/// routable file-transfer target: endpoints are still resolved using Bonjour.
final class BluetoothDiscovery:NSObject,CBCentralManagerDelegate {
    var onStatus:((String)->Void)?
    var onSharingHint:(()->Void)?
    private var central:CBCentralManager?
    private var requested=false
    private var lastHint=Date.distantPast
    private let service=CBUUID(string:"FE2C")
    func start() {
        requested=true
        if central == nil {
            onStatus?("Bluetooth-Berechtigung wird geprüft…")
            central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:true])
        } else {update()}
    }
    func stop() {requested=false;central?.stopScan();onStatus?("Bluetooth-Suche pausiert")}
    func centralManagerDidUpdateState(_ central:CBCentralManager) {update()}
    private func update() {
        guard let central=central else {return}
        switch central.state {
        case .poweredOn:
            guard requested else {return}
            central.scanForPeripherals(withServices:[service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
            onStatus?("Bluetooth-Suche aktiv")
        case .unauthorized: onStatus?("Bluetooth nicht erlaubt – in den iOS-Einstellungen freigeben")
        case .poweredOff: onStatus?("Bluetooth ist ausgeschaltet")
        case .unsupported: onStatus?("Bluetooth-Suche hier nicht verfügbar")
        case .resetting: onStatus?("Bluetooth wird neu gestartet…")
        case .unknown: onStatus?("Bluetooth wird vorbereitet…")
        @unknown default: onStatus?("Bluetooth-Status unbekannt")
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard requested,
              let records=advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data],
              let data=records[service], Self.isQuickShareHint(data),
              Date().timeIntervalSince(lastHint)>20 else {return}
        lastHint=Date()
        onSharingHint?()
    }
    static func isQuickShareHint(_ data:Data)->Bool {
        // Chromium Fast Initiation model ID, distinct from Fast Pair accessories.
        data.count>=5 && Array(data.prefix(3)) == [0xfc,0x12,0x8e] && (data[3] >> 5)==0
    }
}
