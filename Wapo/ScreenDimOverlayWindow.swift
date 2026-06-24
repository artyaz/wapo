//
//  ScreenDimOverlayWindow.swift
//  Wapo
//

import AppKit
import QuartzCore

final class ScreenDimOverlayWindow: NSWindow {
    private let dimView = ScreenDimOverlayView()

    init(screen: NSScreen, focusFrame: CGRect) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configure()
        contentView = dimView
        update(screen: screen, focusFrame: focusFrame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(screen: NSScreen, focusFrame: CGRect) {
        let screenFrame = screen.frame
        setFrame(screenFrame, display: true)
        dimView.frame = NSRect(origin: .zero, size: screenFrame.size)
        dimView.update(screenFrame: screenFrame, focusFrame: focusFrame)
    }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 1
    }
}

private final class ScreenDimOverlayView: NSView {
    private let shadowLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(screenFrame: CGRect, focusFrame: CGRect) {
        let localFocus = CGRect(
            x: focusFrame.origin.x - screenFrame.origin.x,
            y: focusFrame.origin.y - screenFrame.origin.y,
            width: focusFrame.width,
            height: focusFrame.height
        )
        let shadowRect = localFocus.insetBy(dx: -66, dy: -58)
        let constrainedRect = shadowRect.intersection(bounds.insetBy(dx: 24, dy: 24))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = constrainedRect
        shadowLayer.cornerRadius = 40
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.38
        shadowLayer.shadowRadius = 120
        shadowLayer.shadowOffset = .zero
        shadowLayer.shadowPath = CGPath(
            roundedRect: shadowLayer.bounds,
            cornerWidth: shadowLayer.cornerRadius,
            cornerHeight: shadowLayer.cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shadowLayer.masksToBounds = false
        layer?.addSublayer(shadowLayer)
    }
}
