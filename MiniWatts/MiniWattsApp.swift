import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var monitor = PowerMonitor()
    /// One per process, and alive for as long as the app is: the layer Picture in
    /// Picture draws from cannot come and go with a settings sheet.
    @State private var floatingMeter = FloatingMeterController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(monitor)
                .environment(floatingMeter)
        }
    }
}
