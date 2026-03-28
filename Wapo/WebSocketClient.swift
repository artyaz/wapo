//
//  WebSocketClient.swift
//  Wapo
//
//  Persistent bidirectional WebSocket connection to the Python LangGraph backend.
//  Uses URLSessionWebSocketTask with async/await for non-blocking message handling.
//

import Foundation

actor WebSocketClient {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var isActive = false

    init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Connection Lifecycle

    func connect() {
        guard !isActive else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        isActive = true
    }

    func disconnect() {
        isActive = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    var connected: Bool { isActive && task?.state == .running }

    // MARK: - Send

    func send(_ content: String) async throws {
        let message = WSOutgoing(content: content)
        let data = try JSONEncoder().encode(message)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try await task?.send(.string(json))
    }

    // MARK: - Receive (yields decoded messages as an AsyncStream)

    func receive() async throws -> WSIncoming {
        guard let task else {
            throw WebSocketError.notConnected
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return try JSONDecoder().decode(WSIncoming.self, from: Data(text.utf8))
        case .data(let data):
            return try JSONDecoder().decode(WSIncoming.self, from: data)
        @unknown default:
            throw WebSocketError.unknownFormat
        }
    }
}

enum WebSocketError: Error, LocalizedError {
    case notConnected
    case unknownFormat

    var errorDescription: String? {
        switch self {
        case .notConnected: "WebSocket is not connected"
        case .unknownFormat: "Unknown WebSocket message format"
        }
    }
}
