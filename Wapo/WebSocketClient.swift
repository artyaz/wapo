//
//  WebSocketClient.swift
//  Wapo
//
//  Persistent bidirectional WebSocket connection to the Python LangGraph backend.
//  Uses URLSessionWebSocketTask with async/await for non-blocking message handling.
//

import Foundation

actor WebSocketClient {
    private let urls: [URL]
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var isActive = false
    private var currentURLIndex = 0

    init(urls: [URL]) {
        self.urls = urls
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Connection Lifecycle

    func connect() {
        guard !isActive, let url = currentURL else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        isActive = true
    }

    func ensureConnected() {
        guard !isActive else { return }
        connect()
    }

    func reconnect(rotating: Bool = false) {
        disconnect()
        if rotating {
            advanceURL()
        }
        connect()
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

    private var currentURL: URL? {
        guard !urls.isEmpty else { return nil }
        return urls[currentURLIndex]
    }

    private func advanceURL() {
        guard !urls.isEmpty else { return }
        currentURLIndex = (currentURLIndex + 1) % urls.count
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
