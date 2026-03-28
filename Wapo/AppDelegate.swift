//
//  AppDelegate.swift
//  Wapo
//
//  Manages the NSStatusItem (menu bar icon) and the FloatingPanel lifecycle.
//  Bridges AppKit hosting into the SwiftUI application via @NSApplicationDelegateAdaptor.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    let chatViewModel = ChatViewModel()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupFloatingPanel()
    }

    // MARK: - Menu Bar Icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(
                systemSymbolName: "brain.head.profile.fill",
                accessibilityDescription: "Wapo AI Assistant"
            )?.withSymbolConfiguration(config)
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: - Floating Panel

    private func setupFloatingPanel() {
        panel = FloatingPanel()

        let swiftUIContent = PanelContentView(viewModel: chatViewModel)
            .frame(width: 380, height: 620)

        let hostingView = NSHostingView(rootView: swiftUIContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Use NSVisualEffectView as the base variable-blur container
        let blurContainer = NSVisualEffectView()
        blurContainer.material = .popover
        blurContainer.blendingMode = .behindWindow
        blurContainer.state = .active
        blurContainer.wantsLayer = true
        blurContainer.layer?.cornerRadius = 20
        blurContainer.layer?.masksToBounds = true

        blurContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: blurContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: blurContainer.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: blurContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: blurContainer.trailingAnchor),
        ])

        panel.contentView = blurContainer
    }

    // MARK: - Toggle

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanelBelowStatusItem()
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func positionPanelBelowStatusItem() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 620

        let x = buttonRect.midX - panelWidth / 2
        let y = buttonRect.minY - panelHeight - 4

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: true
        )
    }
}
