import AppKit
import Carbon.HIToolbox
import ChatCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let chats = AppDelegate.makeChats()
    private let bar = FloatingBarModel()
    private lazy var mainWindow = MainWindowController(chats: chats)
    private lazy var settingsWindow = SettingsWindowController(hotKey: hotKeySettings)
    private var panel: FloatingPanelController!
    private var hotKey: HotKey?
    private var hotKeySettings: HotKeySettings!
    private var statusItem: NSStatusItem?
    private var showPanelItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = makeStatusItem()
        panel = FloatingPanelController(chats: chats, model: bar) { [weak self] chatID in
            self?.panel.hide()
            self?.mainWindow.show(chatID: chatID)
        }
        hotKeySettings = HotKeySettings { [weak self] combo in self?.registerHotKey(combo) ?? false }
        if let scene = DemoScene.fromEnvironment() {
            scene.run(chats: chats, panel: panel, bar: bar, mainWindow: mainWindow)
        } else {
            mainWindow.show()
        }
    }

    /// Replaces the global hotkey and the menu bar item's shortcut label. Nil only unregisters.
    private func registerHotKey(_ combo: HotKeyCombo?) -> Bool {
        hotKey = nil
        guard let combo else { return true }
        hotKey = HotKey(keyCode: Int(combo.keyCode), modifiers: Int(combo.modifiers)) { [weak self] in
            self?.panel.toggle()
        }
        guard hotKey != nil else { return false }
        showPanelItem?.keyEquivalent = combo.keyEquivalent
        showPanelItem?.keyEquivalentModifierMask = combo.menuModifiers
        return true
    }

    /// Demo mode swaps the saved chats and Claude for made-up chats and canned replies.
    private static func makeChats() -> ChatController {
        guard DemoMode.isEnabled else { return ChatController() }
        let store = ChatStore()
        try? DemoMode.seed(store)
        return ChatController(store: store, client: DemoClient())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    /// Like other Mac chat apps, closing a window doesn't quit the app or its hotkey.
    /// Cmd-Q, the application menu and the Dock's Quit command do quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        for id in chats.streaming { chats.cancel(id) }
    }

    @objc private func showPanel() { panel.show() }
    @objc private func openMainWindow() { mainWindow.show() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func newChat() { mainWindow.newChat() }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Reglance")
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show Prompt Bar", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        showPanelItem = show
        menu.addItem(withTitle: "Open Chats…", action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Reglance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Reglance")
        appMenu.addItem(withTitle: "About Reglance", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Reglance", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Reglance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Reglance", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "File")
        // Cmd-N inside the floating panel is handled by its local keyboard routing.
        file.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Open Chats", action: #selector(openMainWindow), keyEquivalent: "o").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

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
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}
