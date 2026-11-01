import UIKit
import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

final class ShareViewController:UIViewController {
    private let state=ImportState()
    override func viewDidLoad() {
        super.viewDidLoad()
        let host=UIHostingController(rootView:ImportView(state:state,done:{ [weak self] in
            self?.extensionContext?.completeRequest(returningItems:nil)
        }))
        addChild(host);view.addSubview(host.view);host.view.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo:view.topAnchor),host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor),host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        host.didMove(toParent:self)
        Task {await importAttachments()}
    }
    private func importAttachments() async {
        let providers=(extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap{$0.attachments ?? []}
        var paths:[String]=[]
        var failures=0
        for provider in providers.prefix(50) {
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    let type=provider.registeredTypeIdentifiers.first(where:{UTType($0)?.conforms(to:.data)==true}) ?? UTType.data.identifier
                    let url:URL=try await withCheckedThrowingContinuation {continuation in
                        provider.loadFileRepresentation(forTypeIdentifier:type) {url,error in
                            do {
                                guard let url=url else {throw error ?? CocoaError(.fileReadUnknown)}
                                // Copy inside the callback, before the provider's temporary URL expires.
                                continuation.resume(returning:try StoragePaths.importFile(url))
                            } catch {continuation.resume(throwing:error)}
                        }
                    }
                    paths.append(url.path)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let value=try await provider.loadItem(forTypeIdentifier:UTType.url.identifier)
                    if let url=value as? URL {
                        let dest=try storeText(url.absoluteString,name:"Link.txt");paths.append(dest.path)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value=try await provider.loadItem(forTypeIdentifier:UTType.plainText.identifier)
                    if let text=value as? String {paths.append(try storeText(text,name:"Nachricht.txt").path)}
                }
            } catch {failures+=1}
        }
        do {
            guard !paths.isEmpty else {throw CocoaError(.fileReadUnknown)}
            let manifest=StoragePaths.staging.appendingPathComponent(UUID().uuidString+".json")
            try JSONEncoder().encode(paths).write(to:manifest,options:.atomic)
            state.urls=paths.map{URL(fileURLWithPath:$0)}
            state.message="\(paths.count) Dateien bereit. Wähle ein Quick-Share-Gerät."+(failures>0 ? " \(failures) Anhänge konnten nicht importiert werden.":"")
            state.beginDiscovery()
        } catch {state.message="Import fehlgeschlagen: \(error.localizedDescription)"}
        state.finished=true
    }
    override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated)
        state.stop()
    }
    private func storeText(_ text:String,name:String)throws->URL {
        let dir=StoragePaths.outbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let dest=dir.appendingPathComponent(name)
        try Data(text.utf8).write(to:dest,options:.atomic)
        return dest
    }
}
private final class ImportState:NSObject,ObservableObject,ShareExtensionDelegate {
    @Published var message="Dateien werden vorbereitet…"
    @Published var finished=false
    @Published var devices:[RemoteDeviceInfo]=[]
    @Published var busy=false
    @Published var progress:Double=0
    @Published var pin:String?
    @Published var qr:String?
    var urls:[URL]=[]
    private var discovering=false
    private var target:String?
    private var recordID:UUID?
    private var timeout:Timer?
    private var manager:NearbyConnectionManager {NearbyConnectionManager.shared}
    func beginDiscovery() {
        guard !discovering else {return}
        discovering=true;manager.addShareExtensionDelegate(self);manager.startDeviceDiscovery()
    }
    func stop() {
        if busy, let target=target {manager.cancelOutgoingTransfer(id:target)}
        if discovering {manager.stopDeviceDiscovery();manager.removeShareExtensionDelegate(self);discovering=false}
        timeout?.invalidate();manager.clearQrCodeKey()
    }
    func makeQR() {qr="https://quickshare.google/qrcode#key="+manager.generateQrCodeKey()}
    func send(_ device:RemoteDeviceInfo) {
        guard !busy, let id=device.id else {return}
        busy=true;target=id;pin=nil;progress=0
        message="Verbinde mit \(device.name)…"
        let record=TransferRecord(direction:"Gesendet",peer:device.name,names:urls.map(\.lastPathComponent),paths:urls.map(\.path),state:"Wird übertragen")
        recordID=record.id
        var records=HistoryStore.read();records.insert(record,at:0);try? HistoryStore.save(records)
        timeout=Timer.scheduledTimer(withTimeInterval:120,repeats:false){ [weak self] _ in
            guard let self=self, self.busy else {return}
            if let id=self.target {self.manager.cancelOutgoingTransfer(id:id)}
            self.connectionFailed(with:NearbyError.canceled(reason:.timedOut))
        }
        manager.startOutgoingTransfer(deviceID:id,delegate:self,urls:urls)
    }
    private func finish(_ status:String) {
        timeout?.invalidate();busy=false;target=nil
        var records=HistoryStore.read()
        if let i=records.firstIndex(where:{$0.id==recordID}) {records[i].state=status;try? HistoryStore.save(records)}
        recordID=nil
    }
    func addDevice(device:RemoteDeviceInfo) {devices.removeAll{$0.id==device.id};devices.append(device)}
    func removeDevice(id:String) {devices.removeAll{$0.id==id}}
    func startTransferWithQrCode(device:RemoteDeviceInfo) {send(device)}
    func connectionWasEstablished(pinCode:String) {pin=pinCode;message="PIN vergleichen und am Empfänger bestätigen"}
    func connectionFailed(with error:Error) {DispatchQueue.main.async {self.message="Fehlgeschlagen: \(error)";self.finish("Fehlgeschlagen")}}
    func transferAccepted() {message="Wird übertragen…"}
    func transferProgress(progress:Double) {self.progress=progress}
    func transferFinished() {message="Übertragen. Du kannst die Erweiterung jetzt schließen.";progress=1;finish("Übertragen")}
}
private struct ImportView:View {
    @ObservedObject var state:ImportState
    let done:()->Void
    var body:some View {
        NavigationStack {
            ScrollView {VStack(spacing:22) {
                Image(systemName:"arrow.up.right.circle.fill").font(.system(size:60)).foregroundStyle(.green)
                Text("DropQuick").font(.largeTitle.bold())
                Text(state.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let pin=state.pin {Text(pin).font(.system(size:38,weight:.medium,design:.monospaced))}
                if state.busy {ProgressView(value:state.progress)}
                if state.finished && !state.busy {
                    ForEach(state.devices,id:\.id) {device in
                        Button {state.send(device)} label: {Label(device.name,systemImage:device.type == .computer ? "laptopcomputer":"smartphone").frame(maxWidth:.infinity)}.buttonStyle(.glassProminent)
                    }
                    if state.devices.isEmpty {Text("Android: Quick Share → Empfangen → Alle für 10 Minuten. Beide Geräte im gleichen WLAN.").font(.subheadline).foregroundStyle(.secondary)}
                    Button {state.makeQR()} label:{Label("Android per QR verbinden",systemImage:"qrcode")}.buttonStyle(.glass)
                    if let value=state.qr, let image=qrImage(value) {Image(uiImage:image).interpolation(.none).resizable().scaledToFit().frame(width:200,height:200).padding(12).background(.white,in:RoundedRectangle(cornerRadius:16))}
                    Text("Für AirDrop nutze den AirDrop-Eintrag im iOS-Teilen-Menü. Die Browserfreigabe und den Verlauf findest du in der Haupt-App.").font(.caption).foregroundStyle(.secondary)
                } else if !state.finished {ProgressView()}
            }.padding(28)}
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Fertig") {state.stop();done()}}}
        }
    }
    private func qrImage(_ value:String)->UIImage? {
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(value.utf8)
        guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)), let cg=CIContext().createCGImage(output,from:output.extent) else {return nil}
        return UIImage(cgImage:cg)
    }
}
