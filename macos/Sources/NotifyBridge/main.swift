import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) {
    application.run()
}
