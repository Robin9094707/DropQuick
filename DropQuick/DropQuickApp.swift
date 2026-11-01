import SwiftUI

@main struct DropQuickApp:App {
    @StateObject private var center=TransferCenter()
    @Environment(\.scenePhase) private var phase
    var body:some Scene {
        WindowGroup {
            RootView().environmentObject(center)
                .tint(.green)
                .task {center.activate()}
                .onOpenURL {url in if url.isFileURL {center.add(urls:[url])}}
                .onChange(of:phase) {_,value in
                    if value == .active {center.activate()}
                    if value == .background {center.background()}
                }
        }
    }
}
