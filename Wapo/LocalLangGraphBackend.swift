//
//  LocalLangGraphBackend.swift
//  Wapo
//
//  Wraps the existing local Python backend (LangGraph + WebSocket telemetry)
//  behind the AgentBackend protocol. Behavior preserved 1:1 with the prior
//  WebSocket pipeline: ensures the bundled backend is running, maintains a
//  receive loop, and rotates loopback hosts on failure.
//

import Foundation

actor LocalLangGraphBackend: AgentBackend {
    private let wsClient: WebSocketClient
    private var receiveTask: Task<Void, Never>?
    private var sink: BackendEventSink?

    init(urls: [URL]) {
        self.wsClient = WebSocketClient(urls: urls)
    }

    @MainActor
    static func make() -> LocalLangGraphBackend {
        LocalLangGraphBackend(urls: BackendEndpoint.webSocketURLs)
    }

    func setEventSink(_ sink: @escaping BackendEventSink) async {
        self.sink = sink
    }

    func connect() async {
        let backendReady = await BackendProcessController.shared.ensureRunning()
        guard backendReady else { return }
        await wsClient.connect()
        ensureReceiveLoop()
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await wsClient.disconnect()
    }

    func isReachable() async -> Bool {
        await BackendProcessController.shared.backendReady()
    }

    func send(text: String, attachments: [AttachmentItem], history: [OutboundTurn]) async {
        let backendReady = await MainActor.run { BackendProcessController.shared }
        let ready = await backendReady.ensureRunning()
        guard ready else {
            let message = await unavailableMessage()
            sink?(BackendEventFactory.error(message))
            return
        }

        ensureReceiveLoop()

        let outboundContent = Self.flattenForLocalBackend(text: text, attachments: attachments)

        for attempt in 0..<6 {
            do {
                if attempt == 0 {
                    await wsClient.ensureConnected()
                } else {
                    await wsClient.reconnect(rotating: true)
                    try? await Task.sleep(for: .milliseconds(350))
                }

                try await wsClient.send(outboundContent)
                return
            } catch {
                continue
            }
        }

        let fallbackMessage = await unavailableMessage()
        sink?(BackendEventFactory.error(fallbackMessage))
    }

    private func ensureReceiveLoop() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let msg = try await self.wsClient.receive()
                    await self.deliver(msg)
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    _ = await BackendProcessController.shared.ensureRunning()
                    await self.wsClient.reconnect(rotating: true)
                }
            }
        }
    }

    private func deliver(_ msg: WSIncoming) {
        sink?(msg)
    }

    private nonisolated static func flattenForLocalBackend(
        text: String,
        attachments: [AttachmentItem]
    ) -> String {
        guard !attachments.isEmpty else { return text }
        let lines = attachments.map { "- \($0.displayName)" }.joined(separator: "\n")
        let body = text.isEmpty ? "(no text)" : text
        return "\(body)\n\nAttachments:\n\(lines)"
    }

    private func unavailableMessage() async -> String {
        await MainActor.run {
            let diagnostic = BackendProcessController.shared.lastLaunchIssue
                ?? BackendProcessController.shared.lastLogLine
            var message = "Couldn’t reach the local backend on loopback. I checked both `127.0.0.1` and `localhost` on port `\(BackendEndpoint.port)`."
            if let diagnostic, !diagnostic.isEmpty {
                message += "\n\nBackend diagnostic: \(diagnostic)"
            }
            return message
        }
    }
}
