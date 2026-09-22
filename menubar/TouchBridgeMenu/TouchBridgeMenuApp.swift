import SwiftUI

@main
struct TouchBridgeMenuApp: App {
    @StateObject private var appState = MenuBarState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: appState)
        } label: {
            Image(systemName: "touchid")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appState.isDaemonRunning ? .green : .secondary)
        }
        .menuBarExtraStyle(.window)
    }
}
