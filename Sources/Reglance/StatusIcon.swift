import AppKit

/// The menu bar icon: the app icon's motif in one colour. A reply card with two text
/// lines rises above the prompt bar, a capsule with the send button at its right end.
/// A template image, so the menu bar tints it for light, dark and highlighted states.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.set()

            // The reply: a filled card with its text lines cut out.
            let card = NSBezierPath(roundedRect: NSRect(x: 3, y: 1, width: 12, height: 8.5), xRadius: 2.5, yRadius: 2.5)
            for (y, width) in [(CGFloat(3.5), CGFloat(8)), (6, 5.5)] {
                card.append(NSBezierPath(roundedRect: NSRect(x: 5, y: y, width: width, height: 1.25),
                                         xRadius: 0.625, yRadius: 0.625))
            }
            card.windingRule = .evenOdd
            card.fill()

            // The prompt bar: an outlined capsule with typed text and a filled send button.
            let bar = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 11.25, width: 15, height: 5.5), xRadius: 2.75, yRadius: 2.75)
            bar.lineWidth = 1.25
            bar.stroke()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 13.4, width: 4.5, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 12.25, width: 3.5, height: 3.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ReGlance"
        return image
    }
}
