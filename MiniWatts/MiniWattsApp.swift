import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var monitor = PowerMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(monitor)
        }
    }
}
