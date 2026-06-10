import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make `swift run` behave like a real app: dock icon + key window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct NetworkMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FlowStore()

    var body: some Scene {
        WindowGroup("Network Monitor") {
            ContentView()
                .environmentObject(store)
                .onAppear { store.start() }
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(store.isPaused ? "Resume" : "Pause") { store.togglePause() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Clear") { store.clear() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
