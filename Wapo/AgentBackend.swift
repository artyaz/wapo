//
//  AgentBackend.swift
//  Wapo
//
//  Protocol abstracting the wire transport behind the chat UI. Each concrete
//  backend (local LangGraph WebSocket, Hermes OpenAI-compatible HTTP, …) is
//  responsible for translating user input + history into a stream of
//  `WSIncoming` events that the view model already knows how to render.
//

import Foundation

/// Lightweight role-tagged transcript snapshot passed to backends so they can
/// reconstruct request bodies without coupling to ChatMessage internals.
struct OutboundTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String
}

/// Backends emit events through this closure on an arbitrary task; the view
/// model is responsible for hopping to the main actor.
typealias BackendEventSink = @Sendable (WSIncoming) -> Void

protocol AgentBackend: AnyObject, Sendable {
    /// Persistent sink the backend uses for any event (out-of-band telemetry,
    /// streamed deltas, errors). The view model installs this once.
    func setEventSink(_ sink: @escaping BackendEventSink) async

    /// Optional eager connect (used by the local WS backend to spin up the
    /// receive loop). Network-only backends like Hermes can no-op.
    func connect() async

    /// Tear down any persistent transport; called when switching backends.
    func disconnect() async

    /// Returns true when the backend looks reachable (e.g. /health or /v1/models).
    func isReachable() async -> Bool

    /// Send a single user turn. Telemetry events (messageStart / textDelta /
    /// messageEnd / error / status / tool_*) are delivered through the sink
    /// installed via `setEventSink`.
    ///
    /// - Parameters:
    ///   - text: the raw user-typed text (no attachment list baked in)
    ///   - attachments: file/screenshot URLs the user attached to this turn
    ///   - history: prior turns (text only)
    func send(text: String, attachments: [AttachmentItem], history: [OutboundTurn]) async
}

extension AgentBackend {
    func connect() async {}
    func disconnect() async {}
}

// MARK: - Helpers shared by backends

nonisolated enum BackendEventFactory {
    static func messageStart(id: UUID = UUID()) -> WSIncoming {
        WSIncoming(type: .messageStart, data: nil, metadata: ["message_id": id.uuidString])
    }

    static func textDelta(_ text: String, messageID: UUID) -> WSIncoming {
        WSIncoming(type: .textDelta, data: text, metadata: ["message_id": messageID.uuidString])
    }

    static func messageEnd(messageID: UUID) -> WSIncoming {
        WSIncoming(type: .messageEnd, data: nil, metadata: ["message_id": messageID.uuidString])
    }

    static func error(_ text: String) -> WSIncoming {
        WSIncoming(type: .error, data: text, metadata: nil)
    }

    static func status(_ text: String) -> WSIncoming {
        WSIncoming(type: .status, data: text, metadata: nil)
    }
}
