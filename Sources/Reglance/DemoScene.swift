import AppKit
import ChatCore
import SwiftUI

/// Stages one README shot in demo mode, chosen with `REGLANCE_DEMO_SCENE`. Used by
/// `scripts/capture-readme.sh`, which talks to the app through files in the demo folder:
///
/// 1. The app stages the shot over a gradient backdrop (so nothing else on screen shows),
///    then writes `scene-ready.json`: the screen rectangle to capture (`"x,y,w,h"`, points,
///    top-left origin) and `video`, the seconds to record (0 for a still).
/// 2. The script starts capturing and creates `scene-go`.
/// 3. The app plays the scene's animation, if any.
///
/// `REGLANCE_DEMO_APPEARANCE=light|dark` forces the appearance.
struct DemoScene {
    enum Name: String, CaseIterable {
        /// GIF: a question typed into the floating bar, the reply streaming in with a chart.
        case hero
        /// GIF: the model pill growing into its picker card.
        case picker
        /// Still: a floor plan image and a lease PDF attached in the floating bar.
        case attachments
        /// Still: the chats window with a saved itinerary document.
        case chats
        /// Still: the chats window with an interactive HTML widget.
        case widgets
        /// Still: an agent chat with its agent glow.
        case agent
    }

    let name: Name
    let directory: URL

    static func fromEnvironment() -> DemoScene? {
        guard let directory = DemoMode.directory,
              let value = ProcessInfo.processInfo.environment["REGLANCE_DEMO_SCENE"] else { return nil }
        guard let name = Name(rawValue: value) else {
            FileHandle.standardError.write(Data("Unknown REGLANCE_DEMO_SCENE \(value)\n".utf8))
            exit(2)
        }
        return DemoScene(name: name, directory: directory)
    }

    func run(chats: ChatController, panel: FloatingPanelController, bar: ComposerSession, mainWindow: MainWindowController) {
        switch ProcessInfo.processInfo.environment["REGLANCE_DEMO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        DemoBackdrop.show(on: screen)
        NSCursor.setHiddenUntilMouseMoves(true)
        Task {
            do {
                try await play(chats: chats, panel: panel, bar: bar, mainWindow: mainWindow, screen: screen)
            } catch {
                FileHandle.standardError.write(Data("Demo scene \(name) failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private func play(chats: ChatController, panel: FloatingPanelController, bar: ComposerSession,
                      mainWindow: MainWindowController, screen: NSScreen) async throws {
        switch name {
        case .hero:
            panel.show()
            try await pause(1)
            await ready(panel.panel.frame, video: 10)
            try await pause(0.6)
            for character in DemoContent.heroQuestion {
                bar.text.append(character)
                try await pause(0.045)
            }
            try await pause(0.5)
            withAnimation(ComposerMotion.layout()) { bar.send() }

        case .picker:
            panel.show()
            try await pause(1)
            await ready(Self.bottom(of: panel.panel.frame, height: 520), video: 5)
            try await pause(0.6)
            bar.setPickerPresented(true)
            try await pause(1.4)
            withAnimation(.snappy) { bar.model = .opus }
            try await pause(1.0)
            withAnimation(.snappy) { bar.effort = .high }
            try await pause(1.0)
            bar.setPickerPresented(false)

        case .attachments:
            panel.show()
            bar.attachments.add(fileURLs: try DemoFiles.write(to: directory))
            bar.text = DemoContent.attachmentQuestion
            try await pause(1.5)
            await ready(Self.bottom(of: panel.panel.frame, height: 300), video: 0)

        case .chats, .widgets, .agent:
            let title = switch name {
            case .widgets: DemoContent.compound.title
            case .agent: DemoContent.blog.title
            default: DemoContent.lisbon.title
            }
            let window = mainWindow.window
            // Above the backdrop, below the floating panel.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)
            let visible = screen.visibleFrame
            window.setFrame(NSRect(x: visible.midX - 560, y: visible.midY - 360, width: 1120, height: 720), display: false)
            mainWindow.show(chatID: chats.chats.first { $0.title == title }?.id)
            try await pause(2.5) // the HTML widget's web view loads after layout
            await ready(window.frame.insetBy(dx: -48, dy: -48), video: 0)
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// The lower part of the tall floating panel, where the bar and its card sit.
    private static func bottom(of frame: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(height, frame.height))
    }

    /// Reports the capture rectangle, then waits until the script has started capturing.
    private func ready(_ rect: NSRect, video: Int) async {
        // screencapture's coordinates start at the top left of the menu bar screen.
        let top = NSScreen.screens[0].frame.maxY - rect.maxY
        let json = #"{"rect":"\#(Int(rect.minX)),\#(Int(top)),\#(Int(rect.width)),\#(Int(rect.height))","video":\#(video)}"#
        let go = directory.appending(path: "scene-go")
        try? FileManager.default.removeItem(at: go)
        try? Data(json.utf8).write(to: directory.appending(path: "scene-ready.json"), options: .atomic)
        while !FileManager.default.fileExists(atPath: go.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A full-screen gradient behind the demo windows, so captures show no other app or desktop.
private enum DemoBackdrop {
    static var window: NSWindow?

    static func show(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Gradient())
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    private struct Gradient: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let colors: [Color] = colorScheme == .dark
                ? [.init(red: 0.10, green: 0.09, blue: 0.24), .init(red: 0.22, green: 0.10, blue: 0.32), .init(red: 0.05, green: 0.16, blue: 0.27),
                   .init(red: 0.16, green: 0.20, blue: 0.45), .init(red: 0.35, green: 0.16, blue: 0.42), .init(red: 0.06, green: 0.30, blue: 0.38),
                   .init(red: 0.08, green: 0.10, blue: 0.20), .init(red: 0.28, green: 0.12, blue: 0.30), .init(red: 0.05, green: 0.22, blue: 0.30)]
                : [.init(red: 0.78, green: 0.86, blue: 1.00), .init(red: 0.98, green: 0.80, blue: 0.86), .init(red: 1.00, green: 0.88, blue: 0.74),
                   .init(red: 0.66, green: 0.80, blue: 0.98), .init(red: 0.90, green: 0.78, blue: 0.96), .init(red: 1.00, green: 0.80, blue: 0.70),
                   .init(red: 0.62, green: 0.86, blue: 0.92), .init(red: 0.80, green: 0.82, blue: 0.98), .init(red: 0.98, green: 0.74, blue: 0.80)]
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: colors)
            .ignoresSafeArea()
        }
    }
}

/// Made-up attachments for the attachments scene: a floor plan image and a lease PDF.
private enum DemoFiles {
    static func write(to directory: URL) throws -> [URL] {
        let plan = directory.appending(path: "Floor plan.png")
        let lease = directory.appending(path: "Lease agreement.pdf")
        try floorPlan().write(to: plan)
        try leasePDF().write(to: lease)
        return [plan, lease]
    }

    private static func floorPlan() -> Data {
        let size = NSSize(width: 800, height: 560)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let rooms: [(NSRect, String)] = [
                (NSRect(x: 40, y: 40, width: 420, height: 300), "Living room\n5.2 × 3.8 m"),
                (NSRect(x: 460, y: 40, width: 300, height: 300), "Bedroom\n3.6 × 3.8 m"),
                (NSRect(x: 40, y: 340, width: 280, height: 180), "Kitchen\n3.4 × 2.2 m"),
                (NSRect(x: 320, y: 340, width: 180, height: 180), "Bath"),
                (NSRect(x: 500, y: 340, width: 260, height: 180), "Study\n3.2 × 2.2 m"),
            ]
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: NSColor(white: 0.25, alpha: 1),
                .paragraphStyle: style,
            ]
            NSColor(white: 0.15, alpha: 1).setStroke()
            for (rect, label) in rooms {
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 8
                path.stroke()
                let text = NSAttributedString(string: label, attributes: attributes)
                let height = text.boundingRect(with: rect.size, options: .usesLineFragmentOrigin).height
                text.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func leasePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let text = """
            Residential Lease Agreement

            Premises: two-room apartment with study, approx. 62 m².
            Term: 12 months. Rent is due on the first day of each month.
            """
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .draw(in: CGRect(x: 72, y: 72, width: 468, height: 648))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
