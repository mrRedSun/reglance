import AppKit

/// Tests turn on headless mode so windows still open, lay out and become key, but stay
/// invisible and never take focus from the app you're using.
enum WindowPresentation {
    static var isHeadless = false

    /// Call before putting a window on screen.
    static func prepare(_ window: NSWindow) {
        // A fully transparent window draws nothing and lets clicks through.
        if isHeadless { window.alphaValue = 0 }
    }
}
