//
//  FloatingPanel.swift
//  Wapo
//
//  Custom NSPanel subclass configured as a non-activating, floating overlay.
//  Hovers above desktop content without stealing focus from the active application.
//

import AppKit

final class FloatingPanel: NSPanel {

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    convenience init(size: NSSize = NSSize(width: 380, height: 620)) {
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func configure() {
        // Floating level — hovers over all desktop content
        level = .floating

        // Fully transparent — no solid chrome. The SwiftUI glass effects provide all visuals.
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Shadow for depth perception against the desktop
        hasShadow = true

        // Prevent dock icon and mission control appearance
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Allow the panel to become key (for text input) but not activate the app
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }

    // Panel must become key to accept keyboard input
    override var canBecomeKey: Bool { true }

    // Dismiss when focus moves away
    override func resignKey() {
        super.resignKey()
        animator().alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        }
    }
}
