import AppKit
import Sparkle

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
let controller = MainActor.assumeIsolated { AppController(updaterController: updaterController) }
withExtendedLifetime((controller, updaterController)) {
    app.run()
}
