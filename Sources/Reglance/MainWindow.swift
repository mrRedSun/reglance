import AppKit
import ChatCore
import SwiftUI

@Observable
final class MainWindowModel {
    /// The window's composer; its open chat is the sidebar selection.
    let composer: ComposerSession
    var showsArchive = false
    /// Changes for every new conversation, so its scroll view starts fresh.
    private(set) var conversationID = UUID()

    init(chats: ChatController) {
        composer = ComposerSession(chats: chats)
    }

    /// Nil shows a new conversation in Chats, or the archive's selection prompt.
    var selection: UUID? {
        get { composer.chatID }
        set {
            guard newValue != composer.chatID else { return }
            composer.open(newValue)
            if newValue == nil { conversationID = UUID() }
        }
    }

    func newChat() {
        showsArchive = false
        composer.startNewChat()
        conversationID = UUID()
    }

    func showArchive(_ archived: Bool) {
        showsArchive = archived
        selection = nil
        conversationID = UUID()
    }
}

final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: MainWindowModel
    /// AppDelegate can update application policy without the window owning app-wide behavior.
    var onVisibilityChange: ((Bool) -> Void)?
    var isVisible: Bool { window.isVisible }

    private(set) lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "ReGlance"
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.contentViewController = MainHostingController(rootView: MainView(chats: chats, window: model))
        window.addTitlebarAccessoryViewController(ConversationTitleController())
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        // Demo mode must not move the real window's saved frame.
        if !DemoMode.isEnabled { window.setFrameAutosaveName("MainWindow") }
        return window
    }()
    private let chats: ChatController

    init(chats: ChatController) {
        self.chats = chats
        model = MainWindowModel(chats: chats)
        super.init()
    }

    func show(chatID: UUID? = nil) {
        NSApp.setActivationPolicy(.regular)
        Task { await ModelLibrary.shared.refresh() }
        if let chat = chats.chat(chatID) {
            model.showsArchive = chat.isArchived
            model.selection = chat.id
        }
        WindowPresentation.prepare(window)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        if !WindowPresentation.isHeadless { NSApp.activate() }
        onVisibilityChange?(true)
    }

    /// Entry point for the app menu's Command-N action.
    func newChat() {
        model.newChat()
        show()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.composer.dictation.finish()
        sender.orderOut(nil)
        onVisibilityChange?(false)
        return false
    }
}

private final class MainHostingController: NSHostingController<MainView> {
    override func viewDidLayout() {
        super.viewDidLayout()
        // SwiftUI may recreate the native split item after a layout change.
        SidebarLayout.configure(in: view)
    }
}

private final class ConversationTitleController: NSTitlebarAccessoryViewController {
    private let label = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?

    override func loadView() {
        layoutAttribute = .left
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        label.identifier = NSUserInterfaceItemIdentifier("conversationTitle")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        view.addSubview(label)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.label.stringValue = window.title
                self?.label.toolTip = window.title
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(centerTitle),
                                               name: NSWindow.didResizeNotification, object: window)
        centerTitle()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        titleObservation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        centerTitle()
    }

    @objc private func centerTitle() {
        guard let window = view.window else { return }
        // A leading accessory participates in native titlebar layout, but its label
        // is positioned in window coordinates, independently of the split divider.
        let center = view.convert(NSPoint(x: window.frame.width / 2, y: 0), from: nil).x
        let width: CGFloat = 360
        view.setFrameSize(NSSize(width: center + width / 2, height: view.frame.height))
        let height = label.fittingSize.height
        label.frame = NSRect(x: center - width / 2, y: (view.bounds.height - height) / 2,
                             width: width, height: height)
    }
}
