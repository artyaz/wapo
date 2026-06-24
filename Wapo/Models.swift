//
//  Models.swift
//  Wapo
//

import Foundation

// MARK: - Chat Message

enum AttachmentSource: String, Codable, Sendable {
    case drop
    case screenshot
}

struct AttachmentItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let source: AttachmentSource
    let createdAt: Date

    init(url: URL, source: AttachmentSource) {
        self.id = UUID()
        self.url = url
        self.source = source
        self.createdAt = Date()
    }

    nonisolated var displayName: String {
        url.lastPathComponent
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case agent
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachments: [AttachmentItem]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        attachments: [AttachmentItem] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.timestamp = timestamp
    }
}

// MARK: - Agent Status Indicators

struct AgentStatus: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var detail: String?
    var isLoading: Bool
    let timestamp: Date
    var symbolName: String?
    let callID: String?

    init(
        text: String,
        detail: String? = nil,
        isLoading: Bool = false,
        symbolName: String? = nil,
        callID: String? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.detail = detail
        self.isLoading = isLoading
        self.timestamp = Date()
        self.symbolName = symbolName
        self.callID = callID
    }
}

enum TranscriptItemPayload: Equatable, Sendable {
    case message(ChatMessage)
    case activity(AgentStatus)
}

struct TranscriptItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var payload: TranscriptItemPayload

    init(message: ChatMessage) {
        self.id = message.id
        self.payload = .message(message)
    }

    init(activity: AgentStatus) {
        self.id = activity.id
        self.payload = .activity(activity)
    }
}

// MARK: - WebSocket Protocol

enum WSMessageType: String, Codable, Sendable {
    case reasoning
    case content
    case text
    case textDelta = "text_delta"
    case status
    case error
    case heartbeat
    case messageStart = "message_start"
    case messageEnd = "message_end"
    case toolStart = "tool_start"
    case toolArgs = "tool_args"
    case toolOutput = "tool_output"
    case toolEnd = "tool_end"
    case taskUpdate = "task_update"
}

struct WSIncoming: Codable, Sendable {
    let type: WSMessageType
    let data: String?
    let metadata: [String: String]?

    var text: String {
        data ?? ""
    }

    var messageID: String? {
        metadata?["message_id"]
    }

    var callID: String? {
        metadata?["call_id"]
    }

    var toolName: String? {
        metadata?["tool"]
    }

    var statusValue: String? {
        metadata?["status"]
    }
}

struct WSOutgoing: Codable, Sendable {
    let type: String
    let content: String
    let timestamp: String

    init(content: String) {
        self.type = "user_message"
        self.content = content
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}
