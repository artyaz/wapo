//
//  ContentView.swift
//  Wapo
//
//  Created by Artem Chmylenko on 28.03.2026.
//
//  Root SwiftUI content injected into the FloatingPanel via NSHostingView.
//  The panel grows with its content until it reaches the current maximum size,
//  after which the transcript becomes scrollable without visible indicators.
//

import AppKit
import SwiftUI

struct PanelContentView: View {
    @Bindable var viewModel: ChatViewModel
    var maxPanelHeight: CGFloat = 620
    var onPreferredHeightChange: (CGFloat) -> Void = { _ in }

    @State private var inputHeight: CGFloat = 0
    @State private var chatContentHeight: CGFloat = 0
    @State private var composerTextHeight: CGFloat = 56
    @State private var shouldStickTranscriptToBottom = true

    private let blurVerticalPadding: CGFloat = 8
    private let blurHorizontalPadding: CGFloat = 12
    private let blurExtraCoverage: CGFloat = 14
    private let contentVerticalPadding: CGFloat = 18
    private let contentHorizontalPadding: CGFloat = 24
    private let innerStackPadding: CGFloat = 16
    private let moduleSpacing: CGFloat = 8
    private let composerMinHeight: CGFloat = 56
    private let composerMaxHeight: CGFloat = 112

    private var chromeHeight: CGFloat {
        inputHeight
            + (contentVerticalPadding * 2)
            + (innerStackPadding * 2)
            + moduleSpacing
    }

    private var maxChatViewportHeight: CGFloat {
        max(160, maxPanelHeight - chromeHeight)
    }

    private var chatViewportHeight: CGFloat {
        let measuredContent = max(24, chatContentHeight)
        return min(measuredContent, maxChatViewportHeight)
    }

    private var preferredPanelHeight: CGFloat {
        min(maxPanelHeight, chromeHeight + chatViewportHeight)
    }

    private var composerHeight: CGFloat {
        min(composerMaxHeight, max(composerMinHeight, composerTextHeight))
    }

    private var composerBarHeight: CGFloat {
        composerHeight + 16
    }

    var body: some View {
        ZStack(alignment: .top) {
            VariableBlurBackdrop(maxBlurRadius: 2, featherRadius: 96)
                .frame(maxWidth: .infinity)
                .frame(height: max(0, preferredPanelHeight - (blurVerticalPadding * 2) + blurExtraCoverage))
                .padding(.horizontal, blurHorizontalPadding)
                .padding(.vertical, blurVerticalPadding)
                .allowsHitTesting(false)

            VStack(spacing: moduleSpacing) {
                chatModule
                inputModule
                    .readHeight { inputHeight = $0 }
            }
            .padding(innerStackPadding)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, contentVerticalPadding)

            if viewModel.isDropTargeted {
                dropOverlay
            }

            if viewModel.isScreenshotModeActive {
                screenshotHintOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            onPreferredHeightChange(preferredPanelHeight)
            viewModel.connect()
        }
        .onChange(of: preferredPanelHeight) { _, newValue in
            onPreferredHeightChange(newValue)
        }
        .onDisappear { viewModel.disconnect() }
    }

    // MARK: - Chat Transcript Module

    private var chatModule: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.transcriptItems) { item in
                        switch item.payload {
                        case .message(let message):
                            MessageView(message: message)
                                .transition(messageTransition(for: message.role))

                        case .activity(let activity):
                            StatusIndicatorView(
                                indicators: [activity],
                                isThinking: false
                            )
                        }
                    }

                    if let streamingMessage = viewModel.streamingAgentMessage {
                        MessageView(message: streamingMessage)
                    }

                    if viewModel.isAgentThinking &&
                        viewModel.streamingAgentMessage == nil &&
                        !viewModel.hasInlineLoadingActivity {
                        StatusIndicatorView(
                            indicators: [],
                            isThinking: true
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-end")
                }
                .padding(innerStackPadding)
                .readHeight { chatContentHeight = $0 }

                Color.clear
                    .frame(height: 0)
                    .background {
                        TranscriptScrollObserver(threshold: 18) { isNearBottom in
                            shouldStickTranscriptToBottom = isNearBottom
                        }
                    }
                    .id("transcript-end")
            }
            .clipped()
            .onChange(of: viewModel.transcriptRevision) {
                guard shouldStickTranscriptToBottom else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.animation = nil

                    withTransaction(transaction) {
                        proxy.scrollTo("transcript-end", anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: chatViewportHeight, alignment: .top)
        .padding(.horizontal, 6)
    }

    // MARK: - Liquid Glass Input Module

    private var inputModule: some View {
        VStack(spacing: 12) {
            if !viewModel.pendingAttachments.isEmpty {
                attachmentTray
            }

            ZStack(alignment: .top) {
                composerGlassBackground

                HStack(alignment: .bottom, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        if viewModel.currentInput.isEmpty {
                            Text("Ask anything…")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .shadow(color: .black.opacity(0.08), radius: 0.8, x: 0, y: 1)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                        }

                        ComposerTextEditor(
                            text: $viewModel.currentInput,
                            onSend: viewModel.sendMessage,
                            onHeightChange: { composerTextHeight = $0 }
                        )
                        .frame(height: composerHeight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: { viewModel.sendMessage() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(
                        viewModel.currentInput
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty && viewModel.pendingAttachments.isEmpty
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: composerBarHeight)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: viewModel.pendingAttachments.count)
    }

    private var composerGlassBackground: some View {
        Color.clear
            .frame(height: composerMaxHeight + 16)
            .glassEffect(.clear.tint(.white.opacity(0.08)).interactive(), in: .rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.44), location: 0.0),
                                .init(color: .white.opacity(0.18), location: 0.24),
                                .init(color: .white.opacity(0.05), location: 0.54),
                                .init(color: .white.opacity(0.14), location: 0.8),
                                .init(color: .white.opacity(0.3), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.18), location: 0.0),
                                .init(color: .white.opacity(0.035), location: 0.5),
                                .init(color: .white.opacity(0.14), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
                    .blur(radius: 0.6)
            }
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .frame(height: composerBarHeight)
            }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    ComposerAttachmentCardView(attachment: attachment) {
                        viewModel.removePendingAttachment(id: attachment.id)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.84)
                                .combined(with: .move(edge: .bottom))
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.92).combined(with: .opacity)
                        )
                    )
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
    }

    private var dropOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 28, weight: .medium))
            Text("Drop files here")
                .font(.headline)
                .shadow(color: .black.opacity(0.16), radius: 1.4, x: 0, y: 1)
            Text("They’ll attach to your next message")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.top, 72)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private var screenshotHintOverlay: some View {
        Text("Drag an area to attach a screenshot")
            .font(.callout.weight(.medium))
            .shadow(color: .black.opacity(0.16), radius: 1.2, x: 0, y: 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 18)
            .transition(.opacity)
    }

    private func messageTransition(for _: MessageRole) -> AnyTransition {
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .offset(CGSize(width: 0, height: 24)))
                .combined(with: .scale(scale: 0.975))
                .combined(with: .opacity),
            removal: .opacity
        )
    }
}

#Preview {
    PanelContentView(viewModel: ChatViewModel())
        .frame(width: 600, height: 620)
}

private struct HeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, newValue in
                    onChange(newValue)
                }
        }
    }
}

private struct TranscriptScrollObserver: NSViewRepresentable {
    let threshold: CGFloat
    let onBottomLockChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: threshold, onBottomLockChange: onBottomLockChange)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        context.coordinator.threshold = threshold
        context.coordinator.onBottomLockChange = onBottomLockChange
        nsView.coordinator = context.coordinator
        context.coordinator.attachIfPossible(from: nsView)
    }

    final class Coordinator: NSObject {
        var threshold: CGFloat
        var onBottomLockChange: (Bool) -> Void

        private weak var observedClipView: NSClipView?
        private weak var observedScrollView: NSScrollView?
        private var lastReportedState: Bool?

        init(threshold: CGFloat, onBottomLockChange: @escaping (Bool) -> Void) {
            self.threshold = threshold
            self.onBottomLockChange = onBottomLockChange
        }

        deinit {
            detachObserver()
        }

        func attachIfPossible(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attachIfPossible(from: view)
                }
                return
            }

            let clipView = scrollView.contentView
            guard clipView !== observedClipView else {
                reportBottomState()
                return
            }

            detachObserver()
            observedScrollView = scrollView
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            reportBottomState()
        }

        @objc
        private func boundsDidChange() {
            reportBottomState()
        }

        private func detachObserver() {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = nil
            observedScrollView = nil
        }

        private func reportBottomState() {
            guard let scrollView = observedScrollView,
                  let documentView = scrollView.documentView else {
                return
            }

            let visibleBottom = scrollView.contentView.bounds.maxY
            let contentBottom = documentView.frame.maxY
            let distanceToBottom = max(0, contentBottom - visibleBottom)
            let isNearBottom = distanceToBottom <= threshold

            guard lastReportedState != isNearBottom else { return }
            lastReportedState = isNearBottom
            onBottomLockChange(isNearBottom)
        }
    }

    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if let coordinator {
                coordinator.attachIfPossible(from: self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let coordinator {
                coordinator.attachIfPossible(from: self)
            }
        }
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(HeightReader(onChange: onChange))
    }
}

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.onSubmit = onSend
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? ComposerNSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.onSubmit = onSend
        context.coordinator.onHeightChange = onHeightChange
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var onHeightChange: (CGFloat) -> Void

        init(text: Binding<String>, onHeightChange: @escaping (CGFloat) -> Void) {
            self.text = text
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            reportHeight(for: textView)
        }

        func reportHeight(for textView: NSTextView) {
            let measuredHeight = textView.measuredComposerHeight
            DispatchQueue.main.async {
                self.onHeightChange(measuredHeight)
            }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let relevantFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if isReturn {
            let significantFlags = relevantFlags.intersection([.shift, .command, .option, .control])

            if significantFlags == [.shift] {
                super.keyDown(with: event)
                return
            }

            if significantFlags.isEmpty {
                onSubmit?()
                return
            }
        }

        super.keyDown(with: event)
    }
}

private extension NSTextView {
    var measuredComposerHeight: CGFloat {
        guard let textContainer,
              let layoutManager else {
            return 30
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        let insetHeight = textContainerInset.height * 2
        return max(30, usedHeight + insetHeight)
    }
}
