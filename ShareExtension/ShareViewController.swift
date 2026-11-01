import UIKit
import SwiftUI
import UniformTypeIdentifiers

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
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:StoragePaths.groupID) != nil else {
            state.message="Die gemeinsame App Group fehlt. Signiere App und Erweiterung mit derselben App Group. Du kannst Dateien auch direkt in DropQuick auswählen.";state.finished=true;return
        }
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
            state.message="\(paths.count) Dateien vorbereitet. Öffne jetzt DropQuick und wähle dort das Zielgerät."+(failures>0 ? " \(failures) Anhänge konnten nicht importiert werden.":"")
        } catch {state.message="Import fehlgeschlagen: \(error.localizedDescription)"}
        state.finished=true
    }
    private func storeText(_ text:String,name:String)throws->URL {
        let dir=StoragePaths.outbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let dest=dir.appendingPathComponent(name)
        try Data(text.utf8).write(to:dest,options:.atomic)
        return dest
    }
}
private final class ImportState:ObservableObject {
    @Published var message="Dateien werden vorbereitet…"
    @Published var finished=false
}
private struct ImportView:View {
    @ObservedObject var state:ImportState
    let done:()->Void
    var body:some View {
        VStack(spacing:24) {
            Image(systemName:"arrow.up.right.circle.fill").font(.system(size:68)).foregroundStyle(.green)
            Text("DropQuick").font(.largeTitle.bold())
            Text(state.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if state.finished {Button("Fertig",action:done).buttonStyle(.glassProminent).controlSize(.large)} else {ProgressView()}
        }.padding(32)
    }
}
