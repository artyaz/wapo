//
//  ChatViewModel.swift
//  Wapo
//
//  Central state manager bridging the WebSocket telemetry stream to SwiftUI.
//  All properties are @Observable for automatic view invalidation.
//

import SwiftUI

@Observable
final class ChatViewModel {
    private enum TransportMode {
        case localTesting
        case backend
    }

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var transcriptItems: [TranscriptItem] = []
    var pendingAttachments: [AttachmentItem] = []
    var statusIndicators: [AgentStatus] = []
    var isAgentThinking = false
    var currentInput = ""
    var isConnected = false
    var isDropTargeted = false
    var isScreenshotModeActive = false
    var streamingAgentText = ""
    var transcriptRevision = 0

    // MARK: - Private

    private let testingAgent = TestingAgentSimulator()
    private let transportMode: TransportMode
    private let settingsStore: BackendSettingsStore
    private var currentBackend: AgentBackend?
    private var currentBackendKind: BackendKind?
    private var settingsObserver: NSObjectProtocol?
    private var localTestingTask: Task<Void, Never>?
    private var activeStreamMessageID: UUID?
    private var activeStreamStartedAt: Date?
    private var toolDetailBuffers: [String: String] = [:]

    init(settingsStore: BackendSettingsStore = .shared) {
        self.transportMode = Self.defaultTransportMode
        self.settingsStore = settingsStore

        if transportMode == .backend {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .backendSettingsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { [weak self] in await self?.reconfigureBackend() }
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        localTestingTask?.cancel()
    }

    // MARK: - Connection

    func connect() {
        guard transportMode == .backend else {
            isConnected = true
            return
        }

        Task { await reconfigureBackend() }
    }

    func disconnect() {
        localTestingTask?.cancel()

        guard transportMode == .backend else {
            isConnected = false
            return
        }

        Task { [backend = currentBackend] in
            await backend?.disconnect()
            await MainActor.run { self.isConnected = false }
        }
    }

    private func reconfigureBackend() async {
        let desiredKind = settingsStore.kind

        if let currentBackend, currentBackendKind == desiredKind {
            // Settings of an existing backend may have changed (e.g. Hermes
            // URL). Hermes reads settings on every send via its provider, so
            // we just probe.
            let reachable = await currentBackend.isReachable()
            await MainActor.run { self.isConnected = reachable }
            return
        }

        if let currentBackend {
            await currentBackend.disconnect()
        }

        let backend = makeBackend(for: desiredKind)
        let sink: BackendEventSink = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.handleIncoming(msg)
            }
        }
        await backend.setEventSink(sink)
        await backend.connect()
        let reachable = await backend.isReachable()

        currentBackend = backend
        currentBackendKind = desiredKind
        await MainActor.run { self.isConnected = reachable }
    }

    private func makeBackend(for kind: BackendKind) -> AgentBackend {
        switch kind {
        case .localLangGraph:
            return LocalLangGraphBackend.make()

        case .hermes:
            let store = settingsStore
            return HermesBackend { @Sendable in
                let trimmed = store.hermes.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    URL(string: trimmed),
                    store.hermesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    store.hermes.model.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    var streamingAgentMessage: ChatMessage? {
        guard let activeStreamMessageID,
              let activeStreamStartedAt,
              !streamingAgentText.isEmpty else {
            return nil
        }

        return ChatMessage(
            id: activeStreamMessageID,
            role: .agent,
            content: streamingAgentText,
            timestamp: activeStreamStartedAt
        )
    }

    var hasInlineLoadingActivity: Bool {
        transcriptItems.contains { item in
            if case .activity(let activity) = item.payload {
                return activity.isLoading
            }
            return false
        }
    }

    // MARK: - Send User Message

    func sendMessage() {
        let text = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let userMessage = ChatMessage(
            role: .user,
            content: text,
            attachments: attachments
        )

        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            messages.append(userMessage)
            transcriptItems.append(TranscriptItem(message: userMessage))
            currentInput = ""
            pendingAttachments = []
            isAgentThinking = true
            statusIndicators = []
            resetStreamState()
            toolDetailBuffers = [:]
        }
        bumpTranscriptRevision()

        // Local testing simulator still operates on flattened text.
        let flattenedForLocalTesting: String
        if attachments.isEmpty {
            flattenedForLocalTesting = text
        } else {
            let attachmentLines = attachments
                .map { "- \($0.displayName)" }
                .joined(separator: "\n")
            let messageBody = text.isEmpty ? "(no text)" : text
            flattenedForLocalTesting = "\(messageBody)\n\nAttachments:\n\(attachmentLines)"
        }

        Task { [weak self] in
            await self?.dispatchOutboundMessage(
                text: text,
                attachments: attachments,
                flattenedForLocalTesting: flattenedForLocalTesting
            )
        }
    }

    // MARK: - Attachments

    func addAttachments(urls: [URL], source: AttachmentSource) {
        let newItems = urls
            .filter { !$0.path.isEmpty }
            .filter { candidate in
                !pendingAttachments.contains(where: { $0.url == candidate })
            }
            .map { AttachmentItem(url: $0, source: source) }

        guard !newItems.isEmpty else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            pendingAttachments.append(contentsOf: newItems)
        }
    }

    func removePendingAttachment(id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            pendingAttachments.removeAll { $0.id == id }
        }
    }

    func reportAttachmentFailure(_ message: String) {
        appendAgentMessage("⚠️ \(message)")
    }

    // MARK: - Dispatch

    private func dispatchOutboundMessage(
        text: String,
        attachments: [AttachmentItem],
        flattenedForLocalTesting: String
    ) async {
        switch transportMode {
        case .localTesting:
            localTestingTask?.cancel()
            localTestingTask = testingAgent.streamResponse(for: flattenedForLocalTesting) { [weak self] event in
                self?.handleIncoming(event)
            }

        case .backend:
            if currentBackend == nil {
                await reconfigureBackend()
            }
            guard let backend = currentBackend else {
                presentBackendUnavailableMessage()
                return
            }

            let history = await MainActor.run { self.buildOutboundHistory() }
            await backend.send(text: text, attachments: attachments, history: history)
            await MainActor.run { self.isConnected = true }
        }
    }

    @MainActor
    private func buildOutboundHistory() -> [OutboundTurn] {
        messages.map { msg in
            OutboundTurn(
                role: msg.role == .user ? .user : .assistant,
                content: msg.content
            )
        }
    }

    // MARK: - Message Handling (MainActor)

    private func handleIncoming(_ msg: WSIncoming) {
        if msg.type != .heartbeat {
            settleTransientStatuses()
        }

        switch msg.type {
        case .reasoning:
            let elapsed = msg.metadata?["elapsed"] ?? "…"
            appendStatus(
                AgentStatus(
                    text: "Thought for \(elapsed)s",
                    isLoading: false,
                    symbolName: "sparkles"
                )
            )

        case .content:
            isAgentThinking = false
            if activeStreamMessageID != nil {
                appendStreamingText(msg.text, messageID: msg.messageID)
                finalizeStreamingMessage()
            } else {
                appendAgentMessage(msg.text)
            }

        case .text, .textDelta:
            isAgentThinking = false
            appendStreamingText(msg.text, messageID: msg.messageID)

        case .status:
            appendStatus(
                AgentStatus(
                    text: msg.text,
                    isLoading: true,
                    symbolName: "ellipsis"
                )
            )

        case .taskUpdate:
            appendStatus(
                AgentStatus(
                    text: msg.text,
                    isLoading: true,
                    symbolName: "list.bullet.rectangle.portrait"
                )
            )

        case .messageStart:
            isAgentThinking = true
            beginStreamingMessage(messageID: msg.messageID)

        case .messageEnd:
            isAgentThinking = false
            finalizeStreamingMessage()

        case .toolStart:
            // Flush any text that's streamed so far into its own bubble so
            // the tool chip lands chronologically *after* that text, not at
            // the top of the response. Subsequent text deltas will start a
            // fresh streaming bubble below the chip.
            finalizeStreamingMessage()
            beginToolStatus(for: msg)

        case .toolArgs:
            updateToolStatus(
                callID: msg.callID,
                toolName: msg.toolName ?? msg.text,
                prefix: "Args",
                addition: msg.text
            )

        case .toolOutput:
            updateToolStatus(
                callID: msg.callID,
                toolName: msg.toolName ?? msg.text,
                prefix: "Live output",
                addition: msg.text
            )

        case .toolEnd:
            completeToolStatus(for: msg)

        case .error:
            isAgentThinking = false
            finalizeStreamingMessage()
            appendAgentMessage("⚠️ \(msg.text)")

        case .heartbeat:
            break
        }
    }

    private func appendAgentMessage(_ content: String) {
        guard !content.isEmpty else { return }
        let message = ChatMessage(role: .agent, content: content)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            messages.append(message)
            transcriptItems.append(TranscriptItem(message: message))
        }
        bumpTranscriptRevision()
    }

    private func appendStatus(_ status: AgentStatus) {
        withAnimation(.easeInOut(duration: 0.18)) {
            statusIndicators.append(status)
            transcriptItems.append(TranscriptItem(activity: status))
        }
        bumpTranscriptRevision()
    }

    private func beginStreamingMessage(messageID: String?) {
        if activeStreamMessageID != nil, !streamingAgentText.isEmpty {
            finalizeStreamingMessage()
        }

        activeStreamMessageID = resolvedStreamMessageID(from: messageID)
        activeStreamStartedAt = Date()
        streamingAgentText = ""
        bumpTranscriptRevision()
    }

    private func appendStreamingText(_ text: String, messageID: String?) {
        guard !text.isEmpty else { return }

        let resolvedID = resolvedStreamMessageID(from: messageID)
        if activeStreamMessageID == nil {
            activeStreamMessageID = resolvedID
            activeStreamStartedAt = Date()
        } else if activeStreamMessageID != resolvedID, !streamingAgentText.isEmpty {
            finalizeStreamingMessage()
            activeStreamMessageID = resolvedID
            activeStreamStartedAt = Date()
        }

        streamingAgentText.append(text)
        bumpTranscriptRevision()
    }

    private func finalizeStreamingMessage() {
        guard let message = streamingAgentMessage else {
            resetStreamState()
            return
        }

        resetStreamState()
        messages.append(message)
        transcriptItems.append(TranscriptItem(message: message))
        bumpTranscriptRevision()
    }

    private func resetStreamState() {
        streamingAgentText = ""
        activeStreamMessageID = nil
        activeStreamStartedAt = nil
    }

    private func resolvedStreamMessageID(from rawValue: String?) -> UUID {
        if let rawValue,
           let parsed = UUID(uuidString: rawValue) {
            return parsed
        }

        return UUID()
    }

    private func beginToolStatus(for msg: WSIncoming) {
        let toolName = displayName(forTool: msg.toolName ?? msg.text)
        let detail = normalizedDetail(msg.text)
        let status = AgentStatus(
            text: "Running \(toolName)",
            detail: detail.isEmpty ? nil : detail,
            isLoading: true,
            symbolName: "hammer",
            callID: msg.callID
        )

        if let callID = msg.callID, let detail = status.detail {
            toolDetailBuffers[callID] = detail
        }

        appendStatus(status)
    }

    private func updateToolStatus(
        callID: String?,
        toolName: String,
        prefix: String,
        addition: String
    ) {
        let detailLine = "\(prefix): \(normalizedDetail(addition))"
        let resolvedToolName = displayName(forTool: toolName)

        guard let callID, !callID.isEmpty else {
            appendStatus(
                AgentStatus(
                    text: "Running \(resolvedToolName)",
                    detail: detailLine,
                    isLoading: true,
                    symbolName: "hammer"
                )
            )
            return
        }

        let existingBuffer = toolDetailBuffers[callID].map { "\($0)\n\(detailLine)" } ?? detailLine
        toolDetailBuffers[callID] = existingBuffer
        let preview = previewDetail(existingBuffer)

        guard let index = statusIndicators.lastIndex(where: { $0.callID == callID }) else {
            appendStatus(
                AgentStatus(
                    text: "Running \(resolvedToolName)",
                    detail: preview,
                    isLoading: true,
                    symbolName: "hammer",
                    callID: callID
                )
            )
            return
        }

        statusIndicators[index].detail = preview
        statusIndicators[index].isLoading = true
        syncTranscriptActivity(statusIndicators[index])
        bumpTranscriptRevision()
    }

    private func completeToolStatus(for msg: WSIncoming) {
        let toolName = displayName(forTool: msg.toolName ?? msg.text)
        let completionText = msg.text.isEmpty ? "Completed \(toolName)" : msg.text

        guard let callID = msg.callID,
              let index = statusIndicators.lastIndex(where: { $0.callID == callID }) else {
            appendStatus(
                AgentStatus(
                    text: completionText,
                    isLoading: false,
                    symbolName: "checkmark.circle.fill"
                )
            )
            return
        }

        statusIndicators[index].text = completionText
        statusIndicators[index].detail = previewDetail(toolDetailBuffers[callID])
        statusIndicators[index].isLoading = false
        statusIndicators[index].symbolName = "checkmark.circle.fill"
        toolDetailBuffers.removeValue(forKey: callID)
        syncTranscriptActivity(statusIndicators[index])
        bumpTranscriptRevision()
    }

    private func displayName(forTool rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Tool" }

        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func normalizedDetail(_ rawValue: String) -> String {
        rawValue
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func previewDetail(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = normalizedDetail(rawValue)
        guard !normalized.isEmpty else { return nil }

        if normalized.count <= 220 {
            return normalized
        }

        return String(normalized.prefix(219)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func bumpTranscriptRevision() {
        transcriptRevision += 1
    }

    private func settleTransientStatuses() {
        var didChange = false

        for index in statusIndicators.indices {
            guard statusIndicators[index].isLoading,
                  statusIndicators[index].callID == nil else {
                continue
            }

            statusIndicators[index].isLoading = false
            if statusIndicators[index].symbolName == nil ||
                statusIndicators[index].symbolName == "ellipsis" ||
                statusIndicators[index].symbolName == "list.bullet.rectangle.portrait" {
                statusIndicators[index].symbolName = "checkmark.circle.fill"
            }
            syncTranscriptActivity(statusIndicators[index])
            didChange = true
        }

        if didChange {
            bumpTranscriptRevision()
        }
    }

    private func syncTranscriptActivity(_ status: AgentStatus) {
        guard let index = transcriptItems.firstIndex(where: { $0.id == status.id }) else { return }
        transcriptItems[index].payload = .activity(status)
    }

    private static var defaultTransportMode: TransportMode {
        let environmentValue = ProcessInfo.processInfo.environment["WAPO_TRANSPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return environmentValue == "local-testing" ? .localTesting : .backend
    }

    @MainActor
    private func presentBackendUnavailableMessage() {
        isConnected = false
        isAgentThinking = false
        statusIndicators = []
        resetStreamState()

        let diagnostic = BackendProcessController.shared.lastLaunchIssue
            ?? BackendProcessController.shared.lastLogLine

        var message = "⚠️ Couldn’t reach the local backend on loopback. I checked both `127.0.0.1` and `localhost` on port `\(BackendEndpoint.port)`."
        if let diagnostic, !diagnostic.isEmpty {
            message += "\n\nBackend diagnostic: \(diagnostic)"
        }

        appendAgentMessage(message)
    }
}
