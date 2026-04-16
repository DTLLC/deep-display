import AppKit

@main
final class MacResApp: NSObject, NSApplicationDelegate {
    private var appController: AppController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MacResApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appController = AppController()
    }
}
