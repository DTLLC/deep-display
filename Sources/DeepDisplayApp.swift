import AppKit
import SwiftUI

final class DeepDisplayApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.processName = "Deep Display"
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct DeepDisplayApp: App {
    @NSApplicationDelegateAdaptor(DeepDisplayApplicationDelegate.self) private var appDelegate
    @State private var appController = AppController()

    var body: some Scene {
        WindowGroup("Deep Display") {
            DeepDisplayMainView(appController: appController)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
        }

        Window("Workspace Settings", id: "settings") {
            WorkspaceSettingsWindowView(appController: appController)
                .frame(minWidth: 460, minHeight: 320)
        }

        Window("Virtual Resolutions", id: "virtual-resolutions") {
            VirtualResolutionWindowView(appController: appController)
                .frame(minWidth: 620, minHeight: 360)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Deep Display") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
