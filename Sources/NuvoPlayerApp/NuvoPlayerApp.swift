import SwiftUI
import NuvoKit

@main
struct NuvoPlayerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var system = NuvoSystem()

    var body: some Scene {
        WindowGroup("Nuvo Player") {
            ContentView()
                .environment(system)
                .frame(minWidth: 440, minHeight: 380)
                .task { system.start() }
        }
    }
}

#if os(macOS)
import AppKit

/// When launched with `swift run` there is no app bundle, so the process
/// starts as a background tool. This makes it a normal foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
