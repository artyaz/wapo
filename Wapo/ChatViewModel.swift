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

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var statusIndicators: [AgentStatus] = []
    var isAgentThinking = false
    var currentInput = ""
    var isConnected = false

    // MARK: - Private

    private let wsClient: WebSocketClient
    private var receiveTask: Task<Void, Never>?

    init(serverURL: URL = URL(string: "ws://127.0.0.1:8765/ws")!) {
        self.wsClient = WebSocketClient(url: serverURL)
    }

    deinit {
        receiveTask?.cancel()
    }

    // MARK: - Connection

    func connect() {
        Task {
            await wsClient.connect()
            isConnected = await wsClient.connected
            startReceiveLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        Task {
            await wsClient.disconnect()
            isConnected = false
        }
    }

    // MARK: - Send User Message

    func sendMessage() {
        let text = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        currentInput = ""
        isAgentThinking = true
        statusIndicators = []

        Task {
            try? await wsClient.send(text)
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let msg = try await wsClient.receive()
                    await MainActor.run { self.handleIncoming(msg) }
                } catch {
                    await MainActor.run {
                        self.isConnected = false
                    }
                    // Backoff and retry
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await wsClient.connect()
                    await MainActor.run {
                        self.isConnected = true
                    }
                }
            }
        }
    }

    // MARK: - Message Handling (MainActor)

    private func handleIncoming(_ msg: WSIncoming) {
        switch msg.type {
        case .reasoning:
            let elapsed = msg.metadata?["elapsed"] ?? "…"
            statusIndicators.append(AgentStatus(text: "Thought for \(elapsed)s"))

        case .content:
            isAgentThinking = false
            messages.append(ChatMessage(role: .agent, content: msg.data))

        case .status:
            statusIndicators.append(AgentStatus(text: msg.data, isLoading: true))

        case .taskUpdate:
            statusIndicators.append(AgentStatus(text: msg.data, isLoading: true))

        case .error:
            isAgentThinking = false
            messages.append(ChatMessage(role: .agent, content: "⚠️ \(msg.data)"))

        case .heartbeat:
            break
        }
    }
}
