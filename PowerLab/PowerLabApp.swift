import SwiftUI

@main
struct PowerLabApp: App {
    @State private var monitor = PowerLabMonitor()

    var body: some Scene {
        WindowGroup {
            PowerLabRootView()
                .environment(monitor)
                .task { monitor.start() }
        }
    }
}
