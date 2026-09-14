import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var monitor = PowerMonitor()
    @State private var pictureInPicture = TelemetryPictureInPictureController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(monitor)
                .environment(pictureInPicture)
        }
    }
}
