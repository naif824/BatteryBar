import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = MainActor.assumeIsolated { AppController() }
withExtendedLifetime(controller) {
    app.run()
}
