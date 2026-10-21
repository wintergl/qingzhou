import SwiftUI

@main
struct SplitVpnIphoneApp: App {
    @StateObject private var appState = SplitVpnAppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrap()
                }
        }
    }
}
