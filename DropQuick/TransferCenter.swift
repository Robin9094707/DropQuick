import SwiftUI
import Network
import UniformTypeIdentifiers

struct IncomingOffer:Identifiable {
    var id:String {metadata.id}
    let metadata:TransferMetadata
    let peer:RemoteDeviceInfo
}
final class TransferCenter:NSObject,ObservableObject,MainAppDelegate,ShareExtensionDelegate {
    @Published var devices:[RemoteDeviceInfo]=[]
    @Published var files:[URL]=[]
    @Published var history=HistoryStore.read()
    @Published var offer:IncomingOffer?
    @Published var visibleUntil:Date?
    @Published var status="Bereit zum Teilen"
    @Published var progress:Double=0
    @Published var busy=false
    @Published var pin:String?
    @Published var error:String?
    @Published var qrURL:String?
    @Published var networkAvailable=false
    @Published var discoveryStatus="Netzwerksuche noch nicht gestartet"
    @Published var bluetoothStatus="Bluetooth noch nicht gestartet"
    @Published var visibilityStatus="Nicht sichtbar"
    @Published var visibilityRequested=false
    @Published var lastBluetoothHint:Date?
    private let bluetooth=BluetoothDiscovery()
    private var requestedUntil:Date?
    private var suspended=false
    @Published var incomingProgressValue:Double=0
    @Published var portalURL:String?
    private var started=false
    private var timer:Timer?
    private var transferTimeout:Timer?
    private var activeDevice:String?
    private var activeRecord:UUID?
    private var incomingRecords:[String:UUID]=[:]
    private let monitor=NWPathMonitor()
    let portal=BrowserPortal()
    var manager:NearbyConnectionManager {NearbyConnectionManager.shared}

    func start() {
        guard !started else {importStaged(); return}
        started=true
        manager.mainAppDelegate=self
        manager.addShareExtensionDelegate(self)
        manager.statusHandler = { [weak self] message in DispatchQueue.main.async {self?.error=message}}
        manager.discoveryStatusHandler = { [weak self] message in self?.discoveryStatus=message }
        manager.visibilityStatusHandler = { [weak self] visible,message in
            guard let self=self else {return}
            self.visibilityStatus=message
            self.visibleUntil=visible ? self.requestedUntil:nil
        }
        bluetooth.onStatus = { [weak self] message in self?.bluetoothStatus=message }
        bluetooth.onSharingHint = { [weak self] in
            guard let self=self else {return}
            self.lastBluetoothHint=Date()
            // A hint only: never list an unnamed BLE peripheral as a send target.
            self.manager.restartDeviceDiscovery()
            if self.visibilityRequested && self.visibleUntil == nil {self.manager.becomeHidden();self.manager.becomeVisible()}
        }
        bluetooth.start()
        manager.startDeviceDiscovery()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {self?.networkAvailable=path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))}
        }
        monitor.start(queue:DispatchQueue(label:"DropQuick.path"))
        portal.onReceived = { [weak self] url in
            DispatchQueue.main.async {
                self?.record(TransferRecord(direction:"Empfangen",peer:"Browser",names:[url.lastPathComponent],paths:[url.path],state:"Abgeschlossen"))
            }
        }
        portal.onDownloaded = { [weak self] url in
            DispatchQueue.main.async {
                self?.record(TransferRecord(direction:"Gesendet",peer:"Browser",names:[url.lastPathComponent],paths:[url.path],state:"Übertragen",detail:"Vom Browser angefordert; Speichern am Empfänger nicht überprüfbar."))
            }
        }
        portal.onStopped = { [weak self] in DispatchQueue.main.async {self?.portalURL=nil}}
        portal.onError = { [weak self] message in DispatchQueue.main.async {self?.error=message}}
        importStaged()
    }
    func activate() {
        if !busy {history=HistoryStore.read()}
        let resume=suspended
        start();importStaged();bluetooth.start()
        if resume {manager.restartDeviceDiscovery()}
        suspended=false
    }
    func retryDiscovery() {
        start();bluetooth.start();manager.restartDeviceDiscovery()
        if visibilityRequested {manager.becomeHidden();manager.becomeVisible()}
    }
    func background() {
        suspended=true;bluetooth.stop()
        hide()
        manager.cancelIncomingTransfers()
        stopPortal()
        if busy {cancel()}
        if let offer=offer {respond(to:offer,accept:false)}
    }
    func showForTenMinutes() {
        visibilityRequested=true;requestedUntil=Date().addingTimeInterval(600)
        bluetooth.start();manager.becomeVisible()
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:600,repeats:false){ [weak self] _ in self?.hide() }
    }
    func hide() {timer?.invalidate();timer=nil;visibleUntil=nil;requestedUntil=nil;visibilityRequested=false;manager.becomeHidden()}
    func makeQR() {qrURL="https://quickshare.google/qrcode#key="+manager.generateQrCodeKey()}
    func clearQR() {qrURL=nil; manager.clearQrCodeKey()}
    func add(urls:[URL]) {
        DispatchQueue.global(qos:.userInitiated).async {
            var imported:[URL]=[]
            var failure:String?
            for url in urls.prefix(100) {
                do {imported.append(try StoragePaths.importFile(url))} catch {failure=error.localizedDescription}
            }
            DispatchQueue.main.async {
                self.files.append(contentsOf:imported)
                if let failure=failure {self.error=failure}
            }
        }
    }
    func addText(_ text:String) {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        do {
            let dir=StoragePaths.outbox.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let url=dir.appendingPathComponent("Nachricht.txt")
            try Data(text.utf8).write(to:url,options:.atomic)
            files.append(url)
        } catch {self.error=error.localizedDescription}
    }
    func importStaged() {
        let manifests=(try? FileManager.default.contentsOfDirectory(at:StoragePaths.staging,includingPropertiesForKeys:nil)) ?? []
        for manifest in manifests where manifest.pathExtension == "json" {
            do {
                let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:manifest))
                for path in paths {
                    let url=URL(fileURLWithPath:path)
                    guard url.standardizedFileURL.path.hasPrefix(StoragePaths.outbox.standardizedFileURL.path+"/"), FileManager.default.fileExists(atPath:path) else {continue}
                    if !files.contains(url) {files.append(url)}
                }
                try FileManager.default.removeItem(at:manifest)
            } catch {self.error=error.localizedDescription}
        }
    }
    func send(to device:RemoteDeviceInfo) {
        guard !busy, !files.isEmpty, let id=device.id else {return}
        busy=true; progress=0; pin=nil; activeDevice=id
        status="Verbinde mit \(device.name)…"
        let record=TransferRecord(direction:"Gesendet",peer:device.name,names:files.map(\.lastPathComponent),paths:files.map(\.path),state:"Wird übertragen")
        activeRecord=record.id; self.record(record)
        transferTimeout?.invalidate()
        transferTimeout=Timer.scheduledTimer(withTimeInterval:60,repeats:false){ [weak self] _ in
            guard let self=self, self.busy else {return}
            self.manager.cancelOutgoingTransfer(id:id)
            self.connectionFailed(with:NearbyError.canceled(reason:.timedOut))
        }
        manager.startOutgoingTransfer(deviceID:id,delegate:self,urls:files)
    }
    func cancel() {
        if let id=activeDevice {manager.cancelOutgoingTransfer(id:id)}
        finishOutgoing(state:"Abgebrochen",detail:nil)
    }
    func record(_ value:TransferRecord) {history.insert(value,at:0); history=Array(history.prefix(500)); saveHistory()}
    func saveHistory() {do {try HistoryStore.save(history)} catch {self.error=error.localizedDescription}}
    private func updateRecord(_ id:UUID?,state:String,detail:String?=nil) {
        if let i=history.firstIndex(where:{$0.id==id}) {history[i].state=state; history[i].detail=detail; saveHistory()}
    }
    private func finishOutgoing(state:String,detail:String?) {
        guard busy else {return}
        transferTimeout?.invalidate(); transferTimeout=nil
        updateRecord(activeRecord,state:state,detail:detail)
        busy=false; activeDevice=nil; activeRecord=nil; status=state; pin=nil
    }
    func respond(to item:IncomingOffer,accept:Bool) {
        manager.submitUserConsent(transferID:item.id,accept:accept)
        offer=nil
        if accept {status="Empfange von \(item.peer.name)…"}
    }
    func obtainUserConsent(for transfer:TransferMetadata,from device:RemoteDeviceInfo) {
        guard offer == nil else {manager.submitUserConsent(transferID:transfer.id,accept:false); return}
        let record=TransferRecord(direction:"Empfangen",peer:device.name,names:transfer.files.map(\.name),paths:[],state:"Bestätigung ausstehend")
        incomingRecords[transfer.id]=record.id; self.record(record)
        incomingProgressValue=0
        offer=IncomingOffer(metadata:transfer,peer:device)
    }
    func receivedFile(url:URL,transferID:String) {
        guard let id=incomingRecords[transferID], let i=history.firstIndex(where:{$0.id==id}) else {return}
        history[i].paths.append(url.path)
        if !history[i].names.contains(url.lastPathComponent) {history[i].names.append(url.lastPathComponent)}
        saveHistory()
    }
    func incomingProgress(id:String,progress:Double) {incomingProgressValue=progress}
    func incomingTransfer(id:String,didFinishWith error:Error?) {
        updateRecord(incomingRecords.removeValue(forKey:id),state:error == nil ? "Abgeschlossen":"Abgebrochen",detail:error.map {String(describing:$0)})
        if offer?.id==id {offer=nil}
        status=error == nil ? "Empfangen abgeschlossen":"Empfang beendet"
    }
    func addDevice(device:RemoteDeviceInfo) {devices.removeAll{$0.id==device.id}; devices.append(device); devices.sort{$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}}
    func removeDevice(id:String) {devices.removeAll{$0.id==id}}
    func startTransferWithQrCode(device:RemoteDeviceInfo) {if !busy && !files.isEmpty {send(to:device)}}
    func connectionWasEstablished(pinCode:String) {pin=pinCode; status="PIN vergleichen und am Empfänger annehmen"}
    func connectionFailed(with error:Error) {
        DispatchQueue.main.async {guard self.busy else {return}; self.error=String(describing:error); self.finishOutgoing(state:"Fehlgeschlagen",detail:String(describing:error))}
    }
    func transferAccepted() {transferTimeout?.invalidate(); transferTimeout=nil; status="Wird gesendet…"}
    func transferProgress(progress:Double) {self.progress=progress}
    func transferFinished() {progress=1; finishOutgoing(state:"Übertragen",detail:"Daten an den Empfänger gesendet.")}
    func startPortal() {
        do {try portal.start(files:files) { [weak self] url in DispatchQueue.main.async {self?.portalURL=url}}} catch {self.error=error.localizedDescription}
    }
    func stopPortal() {portal.stop(); portalURL=nil}
}
