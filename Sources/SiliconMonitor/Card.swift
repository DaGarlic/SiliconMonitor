import AppKit
import SwiftUI

// A custom borderless card instead of MenuBarExtra's window: same approach as Local Assistant.
// The system popover has a small fixed corner radius, so this panel draws its own translucent
// material with a larger, continuous (squircle-style) corner.

enum CardStyle {
    static let cornerRadius: CGFloat = 22
    static let width: CGFloat = 330
    static let gap: CGFloat = 6   // space between the menu bar and the card
    /// The tallest the card may be: the screen space under the menu bar. Set each time the card opens.
    nonisolated(unsafe) static var maxHeight: CGFloat = 10_000
}

enum CardPlacement {
    /// Centered under the status item, nudged so it stays fully on screen.
    static func frame(anchor: NSRect, screen: NSRect, size: NSSize,
                      gap: CGFloat = CardStyle.gap, margin: CGFloat = 8) -> NSRect {
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        var y = anchor.minY - gap - size.height
        y = max(y, screen.minY + margin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func isInsideAny(_ point: NSPoint, _ rects: [NSRect]) -> Bool {
        rects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }
}

/// A borderless panel that can still take key status (so Esc works).
final class CardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Clips to the rounded shape and draws a hairline edge that stays right in dark/light mode.
final class RoundedHostingView<Content: View>: NSHostingView<Content> {
    /// Called when the SwiftUI content's ideal size changes (a row appeared or went away), so the card can resize.
    var onContentSizeChange: (() -> Void)?
    /// The hairline edge suits the plain material; Liquid Glass supplies its own, so it turns this off.
    var drawsBorder = true { didSet { layer?.borderWidth = drawsBorder ? 0.5 : 0 } }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }

    private func style() {
        wantsLayer = true
        layer?.cornerRadius = CardStyle.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        style()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

@MainActor
enum CardWindow {
    /// A stretchable rounded-rect mask. This is the supported way to round a vibrancy view:
    /// clipping its layer would break the blur at the corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    static func make<Content: View>(_ content: Content) -> (panel: CardPanel, host: RoundedHostingView<Content>) {
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: CardStyle.width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bounds = panel.contentRect(forFrameRect: panel.frame)
        let host = RoundedHostingView(rootView: content)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26, *) {
            // Liquid Glass: the system's glass material, with the same continuous corner as the card.
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = CardStyle.cornerRadius
            glass.contentView = host
            if #available(macOS 27, *) { glass.effectIsInteractive = false }   // no hover/press response on the background
            panel.contentView = glass
            host.drawsBorder = false   // the glass draws its own edge highlight
            panel.hasShadow = false    // the system window shadow showed as a dark outline around the glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            // .inactive draws the material without the live behind-window blur. A live blur is recomputed whenever
            // anything inside the window moves (the scrolling graphs), which cost ~17% GPU; this costs ~0%.
            effect.state = .inactive
            effect.maskImage = roundedMask(radius: CardStyle.cornerRadius)
            effect.addSubview(host)
            panel.contentView = effect
        }
        return (panel, host)
    }

    private static var generation = 0
    private static let easeOutQuint = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    private static let easeInOut = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

    static func present(_ panel: CardPanel, at frame: NSRect) {
        generation += 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            if !panel.isVisible {
                panel.setFrame(frame.offsetBy(dx: 0, dy: -10), display: false)
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = easeOutQuint
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: false)
            }
        }
        panel.makeKey()
        panel.invalidateShadow()
    }

    static func dismiss(_ panel: CardPanel) {
        generation += 1
        let mine = generation
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        let end = panel.frame.offsetBy(dx: 0, dy: -6)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = easeInOut
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: false)
        }, completionHandler: {
            MainActor.assumeIsolated { if mine == generation { panel.orderOut(nil) } }
        })
    }
}
