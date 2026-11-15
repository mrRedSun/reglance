import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular) // regular Dock/menu-bar app, plus an independent floating panel
// One chats window, no window tabs: drops View > Show Tab Bar and its New Tab button.
NSWindow.allowsAutomaticWindowTabbing = false
app.run()
