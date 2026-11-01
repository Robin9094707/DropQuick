import SwiftUI
import PhotosUI
import QuickLook
import CoreImage.CIFilterBuiltins

struct RootView:View {
    @EnvironmentObject var center:TransferCenter
    var body:some View {
        TabView {
            Tab("Teilen",systemImage:"arrow.up.right") {ShareHome()}
            Tab("Empfangen",systemImage:"arrow.down.left") {ReceiveView()}
            Tab("Verlauf",systemImage:"clock.arrow.circlepath") {HistoryView()}
            Tab("Einstellungen",systemImage:"slider.horizontal.3") {SettingsView()}
        }
        .sheet(item:$center.offer) {offer in ConsentView(offer:offer).interactiveDismissDisabled()}
        .alert("Hinweis",isPresented:Binding(get:{center.error != nil},set:{if !$0 {center.error=nil}})) {
            Button("OK",role:.cancel) {center.error=nil}
        } message: {Text(center.error ?? "")}
    }
}
struct Canvas<Content:View>:View {
    @ViewBuilder var content:Content
    var body:some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            LinearGradient(colors:[Color.green.opacity(0.12),.clear,Color.orange.opacity(0.08)],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea()
            content
        }
    }
}
struct Tile<Content:View>:View {
    @ViewBuilder var content:Content
    var body:some View {VStack(alignment:.leading,spacing:16){content}.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:28))}
}
struct ShareHome:View {
    @EnvironmentObject var center:TransferCenter
    @State private var picker=false
    @State private var photoItems:[PhotosPickerItem]=[]
    @State private var textSheet=false
    @State private var text=""
    @State private var qr=false
    @State private var airDrop=false
    @State private var preview:URL?
    @State private var importing=false
    var body:some View {
        NavigationStack {
            Canvas {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        HStack {
                            Label("DROPQUICK",systemImage:"sparkle").font(.caption.weight(.bold)).tracking(2)
                            Spacer()
                            Image(systemName:center.networkAvailable ? "wifi":"wifi.slash").foregroundStyle(center.networkAvailable ? .green:.orange)
                        }
                        Text("Einmal wählen.\nEinfach teilen.").font(.system(size:39,weight:.bold,design:.rounded)).tracking(-1)
                        Text("Deine Dateien. Direkt zum anderen Gerät.").foregroundStyle(.secondary)
                        Tile {
                            HStack {Label("Deine Auswahl",systemImage:"square.stack.3d.up").font(.headline);Spacer();Text("\(center.files.count)").monospacedDigit().foregroundStyle(.secondary)}
                            if center.files.isEmpty {Text("Fotos, Videos, Dokumente oder eine kurze Nachricht.").foregroundStyle(.secondary)}
                            ForEach(Array(center.files.enumerated()),id:\.offset) {index,url in
                                HStack(spacing:12) {
                                    Image(systemName:"doc.fill").font(.title3).foregroundStyle(.green)
                                    Button {preview=url} label: {Text(url.lastPathComponent).lineLimit(1).foregroundStyle(.primary)}
                                    Spacer()
                                    Button {center.files.remove(at:index)} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.disabled(center.busy)
                                }
                            }
                            HStack {
                                Button {picker=true} label:{Label("Dateien",systemImage:"folder")}.buttonStyle(.glass)
                                PhotosPicker(selection:$photoItems,maxSelectionCount:50,matching:.any(of:[.images,.videos])) {Image(systemName:"photo.on.rectangle")}.buttonStyle(.glass).accessibilityLabel("Fotos und Videos auswählen")
                                Button {textSheet=true} label:{Image(systemName:"text.alignleft")}.buttonStyle(.glass).accessibilityLabel("Nachricht schreiben")
                            }.disabled(center.busy || importing)
                            if importing {ProgressView("Dateien werden kopiert…")}
                        }
                        if center.busy {
                            Tile {
                                Label(center.status,systemImage:"arrow.up.circle.fill").font(.headline)
                                if let pin=center.pin {Text(pin).font(.system(size:36,weight:.semibold,design:.monospaced));Text("Beide Geräte müssen dieselbe PIN anzeigen.").font(.caption).foregroundStyle(.secondary)}
                                ProgressView(value:center.progress)
                                Button("Abbrechen",role:.destructive) {center.cancel()}.buttonStyle(.glass)
                            }
                        }
                        HStack {Text("Quick Share").font(.title2.bold());Spacer();ProgressView().controlSize(.small)}
                        if center.devices.isEmpty {
                            Tile {
                                Image(systemName:"dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.green)
                                Text("Bereit, wenn du es bist.").font(.headline)
                                Text("Am Android-Gerät Quick Share → Empfangen öffnen und „Alle für 10 Minuten“ wählen. Beide Geräte müssen im gleichen WLAN sein.").font(.subheadline).foregroundStyle(.secondary)
                                Button {center.makeQR();qr=true} label:{Label("Android per QR verbinden",systemImage:"qrcode")}.buttonStyle(.glass)
                            }
                        } else {
                            ForEach(center.devices,id:\.id) {device in
                                Button {center.send(to:device)} label: {
                                    HStack(spacing:16) {
                                        Image(systemName:device.type == .computer ? "laptopcomputer":"smartphone").font(.title).foregroundStyle(.green).frame(width:45)
                                        VStack(alignment:.leading) {Text(device.name).font(.headline).foregroundStyle(.primary);Text("Quick Share · Lokales Netzwerk").font(.caption).foregroundStyle(.secondary)}
                                        Spacer();Image(systemName:"arrow.up.right").foregroundStyle(.primary)
                                    }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:24))
                                }.disabled(center.files.isEmpty || center.busy)
                            }
                            Button {center.makeQR();qr=true} label:{Label("QR-Verbindung",systemImage:"qrcode")}.buttonStyle(.glass)
                        }
                        Tile {
                            Label("Weitere Wege",systemImage:"arrow.triangle.branch").font(.headline)
                            Button {airDrop=true} label:{Label("AirDrop & iOS-Teilen-Menü",systemImage:"airplayaudio")}.buttonStyle(.glass).disabled(center.files.isEmpty)
                            NavigationLink {BrowserView()} label:{Label("Mit Windows im Browser teilen",systemImage:"laptopcomputer")}
                            Text("Browserfreigabe benötigt keine App am PC. Die native Windows-Umgebungsfreigabe wird noch nicht unterstützt.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(22).padding(.bottom,24)
                }
            }
            .navigationTitle("Teilen").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented:$picker,allowedContentTypes:[.item],allowsMultipleSelection:true) {result in
                switch result {case .success(let urls):center.add(urls:urls);case .failure(let error):center.error=error.localizedDescription}
            }
            .onChange(of:photoItems) {_,items in
                importing=true
                Task {
                    for item in items {
                        do {if let imported=try await item.loadTransferable(type:ImportedMedia.self) {center.files.append(imported.url)}} catch {center.error=error.localizedDescription}
                    }
                    importing=false;photoItems=[]
                }
            }
            .quickLookPreview($preview)
            .sheet(isPresented:$airDrop) {ActivityView(items:center.files)}
            .sheet(isPresented:$qr,onDismiss:{center.clearQR()}) {QRPanel(title:"Mit Android verbinden",subtitle:"Scanne diesen Code mit der Android-Kamera. Quick Share öffnet sich. WLAN und Sichtbarkeit für alle müssen aktiv sein.",value:center.qrURL ?? "")}
            .sheet(isPresented:$textSheet) {
                NavigationStack {TextEditor(text:$text).padding().navigationTitle("Nachricht").toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button("Abbrechen") {textSheet=false}}
                    ToolbarItem(placement:.confirmationAction) {Button("Hinzufügen") {center.addText(text);text="";textSheet=false}.disabled(text.isEmpty)}
                }}.presentationDetents([.medium,.large])
            }
        }
    }
}
struct ImportedMedia:Transferable {
    let url:URL
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(contentType:.data) {value in SentTransferredFile(value.url)} importing: {received in
            ImportedMedia(url:try StoragePaths.importFile(received.file))
        }
    }
}
struct ReceiveView:View {
    @EnvironmentObject var center:TransferCenter
    var body:some View {
        NavigationStack {Canvas {ScrollView {VStack(spacing:24) {
            Image(systemName:center.visibleUntil == nil ? "shield.lefthalf.filled":"dot.radiowaves.left.and.right").font(.system(size:84)).foregroundStyle(.green).padding(.top,36).symbolEffect(.pulse,isActive:center.visibleUntil != nil)
            Text(center.visibleUntil == nil ? "Du entscheidest,\nwer dich sieht.":"Jetzt sichtbar.").font(.system(size:36,weight:.bold,design:.rounded)).multilineTextAlignment(.center)
            Text(DeviceIdentity.name).foregroundStyle(.secondary)
            Tile {
                if let until=center.visibleUntil {
                    HStack {Text("Für alle im WLAN").font(.headline);Spacer();Text(until,style:.timer).monospacedDigit()}
                    Button("Sichtbarkeit beenden",role:.destructive) {center.hide()}.buttonStyle(.glass)
                } else {
                    Text("Empfangen mit Quick Share").font(.headline)
                    Text("DropQuick bleibt geöffnet. Der Absender öffnet am Android-Gerät Quick Share. Du bestätigst jede Anfrage und vergleichst die PIN.").foregroundStyle(.secondary)
                    Button {center.showForTenMinutes()} label:{Label("10 Minuten sichtbar",systemImage:"eye")}.buttonStyle(.glassProminent)
                }
                Text("Die Sichtbarkeit endet automatisch, auch wenn du die App verlässt.").font(.caption).foregroundStyle(.secondary)
            }
            Tile {
                Label(center.status,systemImage:"arrow.down.circle").font(.headline)
                if center.incomingProgressValue>0 {ProgressView(value:center.incomingProgressValue)}
                Text("Empfangene Dateien findest du im Verlauf. Dort kannst du sie ansehen, speichern und weitergeben.").foregroundStyle(.secondary)
            }
            NavigationLink {BrowserView()} label:{Label("Vom Windows-Browser empfangen",systemImage:"laptopcomputer")}.buttonStyle(.glass)
        }.padding(22)}}.navigationTitle("Empfangen").navigationBarTitleDisplayMode(.inline)}
    }
}
struct ConsentView:View {
    @EnvironmentObject var center:TransferCenter
    let offer:IncomingOffer
    var body:some View {
        VStack(spacing:24) {
            Image(systemName:"arrow.down.circle.fill").font(.system(size:64)).foregroundStyle(.green)
            Text("\(offer.peer.name) möchte teilen").font(.title.bold()).multilineTextAlignment(.center)
            Text(offer.metadata.pinCode ?? "—").font(.system(size:48,weight:.medium,design:.monospaced))
            Text("Vergleiche die PIN auf beiden Geräten. Nimm nur erwartete Dateien an.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            ScrollView {ForEach(Array(offer.metadata.files.enumerated()),id:\.offset) {_,file in
                LabeledContent(file.name,value:ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file))
            };if let text=offer.metadata.textDescription {Text(text)}}.frame(maxHeight:180)
            Button("Annehmen") {center.respond(to:offer,accept:true)}.buttonStyle(.glassProminent).controlSize(.large)
            Button("Ablehnen",role:.destructive) {center.respond(to:offer,accept:false)}.buttonStyle(.glass)
        }.padding(30).presentationDetents([.large])
    }
}
struct HistoryView:View {
    @EnvironmentObject var center:TransferCenter
    @State private var filter="Alle"
    @State private var preview:URL?
    var records:[TransferRecord] {center.history.filter{filter == "Alle" || $0.direction == filter}}
    var body:some View {
        NavigationStack {List {
            Picker("Richtung",selection:$filter) {ForEach(["Alle","Gesendet","Empfangen"],id:\.self) {Text($0)}}.pickerStyle(.segmented).listRowBackground(Color.clear)
            if records.isEmpty {ContentUnavailableView("Noch ganz frisch",systemImage:"tray",description:Text("Deine Übertragungen erscheinen hier."))}
            ForEach(records) {record in
                VStack(alignment:.leading,spacing:10) {
                    HStack {Label(record.peer,systemImage:record.direction == "Gesendet" ? "arrow.up.right":"arrow.down.left").font(.headline);Spacer();Text(record.date,style:.time).font(.caption).foregroundStyle(.secondary)}
                    Text(record.state).font(.caption.weight(.semibold)).foregroundStyle(record.state == "Fehlgeschlagen" ? .orange:.secondary)
                    ForEach(Array(record.names.enumerated()),id:\.offset) {_,name in Text(name).lineLimit(2)}
                    if let detail=record.detail {Text(detail).font(.caption).foregroundStyle(.secondary)}
                    ForEach(record.paths,id:\.self) {path in
                        let url=URL(fileURLWithPath:path)
                        if FileManager.default.fileExists(atPath:path) {
                            HStack {
                                Button {preview=url} label:{Label("Ansehen",systemImage:"eye")}
                                Spacer()
                                ShareLink(item:url) {Label("Teilen",systemImage:"square.and.arrow.up")}
                            }.font(.subheadline).buttonStyle(.borderless)
                        }
                    }
                }.padding(.vertical,8)
            }.onDelete {indices in
                let ids=indices.map{records[$0].id}
                center.history.removeAll{ids.contains($0.id)};center.saveHistory()
            }
        }.navigationTitle("Verlauf").quickLookPreview($preview)}
    }
}
struct BrowserView:View {
    @EnvironmentObject var center:TransferCenter
    var body:some View {
        Canvas {ScrollView {VStack(alignment:.leading,spacing:22) {
            Text("Jeder Browser.\nKeine Installation.").font(.largeTitle.bold())
            Text("Windows und Android öffnen einen lokalen Link im Browser. Beide Geräte müssen im selben WLAN sein.").foregroundStyle(.secondary)
            Tile {
                Label("Lokale Browserfreigabe",systemImage:"network").font(.headline)
                Text("Diese Verbindung nutzt unverschlüsseltes HTTP. Nur im vertrauten WLAN verwenden. Jeder mit dem Link kann die ausgewählten Dateien laden und Dateien bis 50 MB hochladen. Nach zehn Minuten endet die Freigabe.").font(.subheadline)
                if let url=center.portalURL {
                    QRCode(value:url).frame(width:220,height:220).frame(maxWidth:.infinity)
                    Text(url).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item:url) {Label("Link teilen",systemImage:"square.and.arrow.up")}.buttonStyle(.glass)
                    Button("Freigabe beenden",role:.destructive) {center.stopPortal()}.buttonStyle(.glass)
                } else {
                    Text("\(center.files.count) Dateien zum Herunterladen ausgewählt.")
                    Button("Freigabe für 10 Minuten starten") {center.startPortal()}.buttonStyle(.glassProminent)
                }
            }
            Text("Dies ist ein zusätzlicher Übertragungsweg. Windows’ native Umgebungsfreigabe (MS-CDP/NearShare) ist in dieser Version nicht implementiert.").font(.caption).foregroundStyle(.secondary)
        }.padding(22)}}.navigationTitle("Browserfreigabe").onDisappear {center.stopPortal()}
    }
}
struct SettingsView:View {
    @AppStorage("deviceName") private var name="DropQuick iPhone"
    var body:some View {
        NavigationStack {Form {
            Section("Dein Gerät") {TextField("Gerätename",text:$name).onChange(of:name) {_,value in name=String(value.prefix(50))};Text("Namensänderungen gelten bei der nächsten Sichtbarkeit.").font(.caption)}
            Section("Verbindungen") {
                Label("Quick Share: verschlüsseltes WLAN-Protokoll",systemImage:"lock.shield")
                Label("AirDrop: iOS-Teilen-Menü",systemImage:"square.and.arrow.up")
                Label("Windows: lokale Browserfreigabe",systemImage:"laptopcomputer")
            }
            Section("So klappt’s mit Android") {
                Text("1. Beide Geräte mit demselben WLAN verbinden.\n2. Android: Quick Share → Empfangen → Alle für 10 Minuten.\n3. Falls nichts erscheint, den QR-Code in DropQuick scannen.\n4. PIN vergleichen und bestätigen.")
                Text("Gast-WLAN, Client-Isolation oder VPN können lokale Geräte blockieren. Bei kompatiblen Android-Geräten kann zusätzlich AirDrop im iOS-Teilen-Menü funktionieren.")
            }
            Section("Datenschutz & Grenzen") {
                Text("Kein Konto, keine Cloud, keine Analyse. Verlauf und Dateikopien bleiben auf diesem iPhone. Verlaufseinträge löschen entfernt nur den Eintrag. Dateien im App-Gruppencontainer werden bei Deinstallation entfernt.")
                Text("Quick Share basiert auf einem inoffiziellen offenen Protokoll. Die Kompatibilität mit deinem Samsung/Android-Gerät muss praktisch getestet werden. Kein Bluetooth-Dateitransport, keine Wi-Fi-Direct-Verbindung, keine native Windows-Umgebungsfreigabe. App für Empfang und Übertragung geöffnet lassen.")
                Text("Die Teilen-Erweiterung legt Dateien in der Ausgangsbox ab. Öffne danach DropQuick, um den Empfänger auszuwählen. Bei Sideloading müssen App und Erweiterung dieselbe App Group behalten.")
            }
            Section("Open Source") {
                Link("DropQuick auf GitHub",destination:URL(string:"https://github.com/Robin9094707/DropQuick")!)
                Link("Quick-Share-Basis: NearDrop · Grishka · Unlicense",destination:URL(string:"https://github.com/grishka/NearDrop")!)
                Text("Version 1.0.0 · iOS 26+").foregroundStyle(.secondary)
            }
        }.navigationTitle("Einstellungen")}
    }
}
struct QRCode:View {
    let value:String
    var body:some View {
        if let image=makeImage() {Image(uiImage:image).interpolation(.none).resizable().scaledToFit().padding(14).background(.white,in:RoundedRectangle(cornerRadius:18))}
    }
    private func makeImage()->UIImage? {
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(value.utf8)
        guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)),let cg=CIContext().createCGImage(output,from:output.extent) else {return nil}
        return UIImage(cgImage:cg)
    }
}
struct QRPanel:View {
    @Environment(\.dismiss) var dismiss
    let title:String
    let subtitle:String
    let value:String
    var body:some View {NavigationStack {VStack(spacing:24) {Text(title).font(.title.bold());QRCode(value:value).frame(width:260,height:260);Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)}.padding(28).toolbar {ToolbarItem(placement:.confirmationAction) {Button("Fertig") {dismiss()}}}}.presentationDetents([.large])}
}
struct ActivityView:UIViewControllerRepresentable {
    let items:[URL]
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:items,applicationActivities:nil)}
    func updateUIViewController(_ controller:UIActivityViewController,context:Context) {}
}
