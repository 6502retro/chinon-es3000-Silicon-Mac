//  ChinonApp.swift — app entry point and menus.

import SwiftUI

@main
struct ChinonES3000App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Chinon ES-3000", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Convert .DCT Files…") { model.chooseAndConvert() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Photos Folder") { model.openPhotoFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Camera") {
                Button(model.connected ? "Disconnect" : "Connect") { model.toggleConnection() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.busy)
                Divider()
                Button("Download New Pictures") { model.download(.new) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.connected || model.busy)
                Button("Download All Pictures") { model.download(.all) }
                    .disabled(!model.connected || model.busy)
                Button("Refresh List") { model.refreshList() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.connected || model.busy)
                Divider()
                Button("Take Picture") { model.takePicture() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.connected || model.busy)
                Button("Sync Camera Clock to Mac") { model.syncClock() }
                    .disabled(!model.connected || model.busy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()        // put the camera back to 9600 baud and close the port
    }

    /// .DCT files dropped on the Dock icon or opened with the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.convert(urls)
    }
}
