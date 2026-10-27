import SwiftUI

@main
struct NSPortBuilderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("NX2Apple") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1280, height: 900)
            .windowResizability(.automatic)
    }
}

/// `swift run` starts a bare executable with no Info.plist, which macOS does not treat as a
/// regular app: no Dock icon, and the window can stay hidden behind the terminal. Inside the
/// .app bundle this changes nothing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
