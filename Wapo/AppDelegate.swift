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
    private enum Layout {
        static let panelWidth: CGFloat = 600
        static let maxPanelHeight: CGFloat = 620
        static let minPanelHeight: CGFloat = 150
        static let screenshotPanelAlpha: CGFloat = 0.42
    }

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var panelHeight: CGFloat = 220
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localFlagMonitor: Any?
    private var globalFlagMonitor: Any?
    private var modifierPollingTimer: Timer?
    private var screenshotController: ScreenshotSelectionController?
    private var dimOverlayWindow: ScreenDimOverlayWindow?
    private let backendProcessController = BackendProcessController.shared
    private var isHidingPanel = false
    let chatViewModel = ChatViewModel()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupFloatingPanel()
        Task {
            await backendProcessController.ensureRunning()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backendProcessController.terminateIfNeeded()
    }

    // MARK: - Menu Bar Icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Wapo AI Assistant"
            )?.withSymbolConfiguration(config)
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            presentStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func presentStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Wapo", action: #selector(quitApp), keyEquivalent: "q")
            .target = self

        // Standard trick to show a menu on the status item without making it
        // permanent: attach, click, detach.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        if panel.isVisible { hidePanel() }
        SettingsWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Floating Panel

    private func setupFloatingPanel() {
        panel = FloatingPanel(
            size: NSSize(width: Layout.panelWidth, height: panelHeight)
        )

        let swiftUIContent = PanelContentView(
            viewModel: chatViewModel,
            maxPanelHeight: Layout.maxPanelHeight,
            onPreferredHeightChange: { [weak self] preferredHeight in
                self?.updatePanelHeight(preferredHeight)
            }
        )
        .environment(\.controlActiveState, .key)
        .frame(width: Layout.panelWidth)

        let hostingView = DropAwareHostingView(
            rootView: swiftUIContent,
            viewModel: chatViewModel
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        panel.contentView = contentContainer
    }

    // MARK: - Toggle

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func positionPanelBelowStatusItem() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        let x = buttonRect.midX - Layout.panelWidth / 2
        let y = buttonRect.minY - panelHeight - 4

        panel.setFrame(
            NSRect(x: x, y: y, width: Layout.panelWidth, height: panelHeight),
            display: true
        )

        if let screen = buttonWindow.screen {
            updateDimOverlay(on: screen)
        }
    }

    private func updatePanelHeight(_ preferredHeight: CGFloat) {
        let clampedHeight = min(
            Layout.maxPanelHeight,
            max(Layout.minPanelHeight, preferredHeight)
        )

        guard abs(clampedHeight - panelHeight) > 1 else { return }
        panelHeight = clampedHeight

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.panel.isVisible {
                self.positionPanelBelowStatusItem()
            } else {
                self.panel.setContentSize(
                    NSSize(width: Layout.panelWidth, height: self.panelHeight)
                )
            }
        }
    }

    private func showPanel() {
        isHidingPanel = false
        Task {
            await backendProcessController.ensureRunning()
        }
        positionPanelBelowStatusItem()
        installEventMonitors()
        showDimOverlay()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        isHidingPanel = true
        screenshotController?.cancel()
        finishScreenshotSelection(with: nil, cancelled: true)
        removeEventMonitors()
        hideDimOverlay()

        guard panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
            self?.isHidingPanel = false
        }
    }

    private func installEventMonitors() {
        guard localMouseMonitor == nil,
              globalMouseMonitor == nil,
              localFlagMonitor == nil,
              globalFlagMonitor == nil else { return }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            self?.handleOutsideClickIfNeeded()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            self?.handleOutsideClickIfNeeded()
        }

        localFlagMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
            return event
        }

        globalFlagMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.handleModifierFlags(event.modifierFlags)
        }

        startModifierPolling()
    }

    private func removeEventMonitors() {
        stopModifierPolling()

        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        if let localFlagMonitor {
            NSEvent.removeMonitor(localFlagMonitor)
            self.localFlagMonitor = nil
        }

        if let globalFlagMonitor {
            NSEvent.removeMonitor(globalFlagMonitor)
            self.globalFlagMonitor = nil
        }
    }

    private func startModifierPolling() {
        guard modifierPollingTimer == nil else { return }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollModifierFlags()
        }
        modifierPollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        pollModifierFlags()
    }

    private func stopModifierPolling() {
        modifierPollingTimer?.invalidate()
        modifierPollingTimer = nil
    }

    private func pollModifierFlags() {
        guard panel.isVisible, !chatViewModel.isScreenshotModeActive else { return }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let isCommandPressed = flags.contains(.maskCommand)
        let isOptionPressed = flags.contains(.maskAlternate)
        guard isCommandPressed, isOptionPressed else { return }

        beginScreenshotSelection()
    }

    private func handleOutsideClickIfNeeded() {
        guard panel.isVisible, !chatViewModel.isScreenshotModeActive else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard !panel.frame.contains(mouseLocation) else { return }
        hidePanel()
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard panel.isVisible, !chatViewModel.isScreenshotModeActive else { return }
        let relevantFlags = flags.intersection(.deviceIndependentFlagsMask)
        guard relevantFlags.contains([.command, .option]) else { return }
        beginScreenshotSelection()
    }

    private func beginScreenshotSelection() {
        guard panel.isVisible, !chatViewModel.isScreenshotModeActive else { return }

        chatViewModel.isScreenshotModeActive = true
        panel.alphaValue = Layout.screenshotPanelAlpha
        hideDimOverlay(animated: false)
        NSApp.activate(ignoringOtherApps: true)

        let controller = ScreenshotSelectionController(screen: panel.screen) { [weak self] result, cancelled in
            self?.finishScreenshotSelection(with: result, cancelled: cancelled)
        }
        screenshotController = controller
        controller.begin()
    }

    private func finishScreenshotSelection(with url: URL?, cancelled: Bool) {
        guard chatViewModel.isScreenshotModeActive || screenshotController != nil else { return }

        chatViewModel.isScreenshotModeActive = false
        screenshotController = nil
        panel.alphaValue = 1

        if let url {
            chatViewModel.addAttachments(urls: [url], source: .screenshot)
        } else if !cancelled {
            chatViewModel.reportAttachmentFailure(
                "Screenshot capture failed. Check Screen Recording permission and try again."
            )
        }

        if panel.isVisible, !isHidingPanel {
            showDimOverlay()
            panel.makeKeyAndOrderFront(nil)
            positionPanelBelowStatusItem()
        }
    }

    private func updateDimOverlay(on screen: NSScreen) {
        if let dimOverlayWindow {
            dimOverlayWindow.update(screen: screen, focusFrame: panel.frame)
        } else {
            dimOverlayWindow = ScreenDimOverlayWindow(screen: screen, focusFrame: panel.frame)
        }
    }

    private func showDimOverlay() {
        guard let screen = panel.screen ?? statusItem.button?.window?.screen else { return }

        updateDimOverlay(on: screen)
        guard let dimOverlayWindow else { return }

        dimOverlayWindow.alphaValue = 0
        dimOverlayWindow.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimOverlayWindow.animator().alphaValue = 1
        }
    }

    private func hideDimOverlay(animated: Bool = true) {
        guard let dimOverlayWindow, dimOverlayWindow.isVisible else { return }

        let orderOut = {
            dimOverlayWindow.orderOut(nil)
            dimOverlayWindow.alphaValue = 1
        }

        guard animated else {
            orderOut()
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimOverlayWindow.animator().alphaValue = 0
        } completionHandler: {
            orderOut()
        }
    }
}

private final class DropAwareHostingView<Content: View>: NSHostingView<Content> {
    private unowned let viewModel: ChatViewModel

    init(rootView: Content, viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasReadableFileURLs(in: sender.draggingPasteboard) else { return [] }
        window?.makeKey()
        Task { @MainActor in
            viewModel.isDropTargeted = true
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasReadableFileURLs(in: sender.draggingPasteboard) else {
            clearDropTarget()
            return []
        }

        window?.makeKey()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropTarget()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasReadableFileURLs(in: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        clearDropTarget()

        guard !urls.isEmpty else { return false }

        Task { @MainActor in
            viewModel.addAttachments(urls: urls, source: .drop)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        clearDropTarget()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropTarget()
    }

    private func hasReadableFileURLs(in pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]

        return objects?.map { $0 as URL } ?? []
    }

    private func clearDropTarget() {
        Task { @MainActor in
            viewModel.isDropTargeted = false
        }
    }
}
