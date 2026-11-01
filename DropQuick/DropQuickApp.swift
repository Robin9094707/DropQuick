import SwiftUI

@main struct DropQuickApp:App {
    @StateObject private var center=TransferCenter()
    @Environment(\.scenePhase) private var phase
    private var isPreview:Bool {ProcessInfo.processInfo.arguments.contains("--preview")}
    var body:some Scene {
        WindowGroup {
            RootView().environmentObject(center)
                .tint(.green)
                .task {if !isPreview {center.activate()}}
                .onOpenURL {url in if url.isFileURL {center.add(urls:[url])}}
                .onChange(of:phase) {_,value in
                    if value == .active && !isPreview {center.activate()}
                    if value == .background {center.background()}
                }
        }
    }
}
