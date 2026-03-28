//
//  Models.swift
//  Wapo
//

import Foundation

// MARK: - Chat Message

enum MessageRole: String, Codable, Sendable {
    case user
    case agent
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

// MARK: - Agent Status Indicators

struct AgentStatus: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let isLoading: Bool
    let timestamp: Date

    init(text: String, isLoading: Bool = false) {
        self.id = UUID()
        self.text = text
        self.isLoading = isLoading
        self.timestamp = Date()
    }
}

// MARK: - WebSocket Protocol

enum WSMessageType: String, Codable, Sendable {
    case reasoning
    case content
    case status
    case error
    case heartbeat
    case taskUpdate = "task_update"
}

struct WSIncoming: Codable, Sendable {
    let type: WSMessageType
    let data: String
    let metadata: [String: String]?
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
