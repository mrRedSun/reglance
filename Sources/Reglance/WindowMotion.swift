import AppKit
import SwiftUI

/// The chats window's sidebar is always shown: it can't be collapsed by a button,
/// a shortcut or dragging the divider. Its width limits are set on the native split item,
/// because SwiftUI's `navigationSplitViewColumnWidth` doesn't reach it (it stayed at 140pt).
enum SidebarLayout {
    static let minimumWidth: CGFloat = 250
    static let maximumWidth: CGFloat = 360
    static let idealWidth: CGFloat = 280

    static func configure(in root: NSView) {
        guard let split = splitView(in: root),
              let controller = split.delegate as? NSSplitViewController else { return }
        for (index, item) in controller.splitViewItems.enumerated() where item.behavior == .sidebar {
            if item.minimumThickness != minimumWidth { item.minimumThickness = minimumWidth }
            if item.maximumThickness != maximumWidth { item.maximumThickness = maximumWidth }
            if item.canCollapse { item.canCollapse = false }
            if item.isCollapsed { item.isCollapsed = false }
            // A width saved before these limits existed (or SwiftUI's 140pt default) is
            // below the minimum; AppKit wouldn't correct it until the next layout change.
            let width = item.viewController.view.frame.width
            if !item.isCollapsed, width > 0, width < minimumWidth, index < split.arrangedSubviews.count - 1 {
                split.setPosition(idealWidth, ofDividerAt: index)
            }
        }
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(splitView).first
    }
}

/// The bloom: a spring out of about a third of the size and a blur, with a slight overshoot.
/// The floating bar opens this way on ⌥Space, and the picker card out of its pill.
enum BloomMotion {
    static let animation = Animation.spring(response: 0.40, dampingFraction: 0.62)
    static let startScale: CGFloat = 0.35
    static let startBlur: CGFloat = 12
}

enum FloatingPanelMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : BloomMotion.animation
    }

    static func scale(isPresented: Bool, reduceMotion: Bool) -> CGSize {
        guard !isPresented, !reduceMotion else { return CGSize(width: 1, height: 1) }
        return CGSize(width: BloomMotion.startScale, height: BloomMotion.startScale)
    }

    static func blur(isPresented: Bool, reduceMotion: Bool) -> CGFloat {
        isPresented || reduceMotion ? 0 : BloomMotion.startBlur
    }
}
