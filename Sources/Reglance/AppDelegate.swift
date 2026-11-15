import AppKit
import Carbon.HIToolbox
import ChatCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let chats = ChatController()
    private lazy var mainWindow = MainWindowController(chats: chats)
    private var panel: FloatingPanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = makeStatusItem()
        panel = FloatingPanelController(chats: chats) { [weak self] chatID in
            self?.panel.hide()
            self?.mainWindow.show(chatID: chatID)
        }
        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.panel.toggle() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    @objc private func showPanel() { panel.show() }
    @objc private func openMainWindow() { mainWindow.show() }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Reglance")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show Prompt Bar", action: #selector(showPanel), keyEquivalent: " ")
        show.keyEquivalentModifierMask = .option
        show.target = self
        menu.addItem(withTitle: "Open Chats…", action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Reglance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    /// Agent apps show no menu bar, but the key equivalents still need a main menu:
    /// without an Edit menu, ⌘C/⌘V/⌘A don't work in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Reglance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu

        return main
    }
}
