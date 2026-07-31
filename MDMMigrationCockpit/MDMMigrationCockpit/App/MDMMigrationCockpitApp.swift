import SwiftUI

@main
struct MDMMigrationCockpitApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
    }
}
