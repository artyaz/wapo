//
//  MessageView.swift
//  Wapo
//
//  Renders a single chat message as pure text — no bubbles, no colored backgrounds.
//  User messages are right-aligned; agent responses are left-aligned.
//

import SwiftUI

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            Text(message.content)
                .font(.body)
                .foregroundStyle(message.role == .user ? .primary : .secondary)
                .multilineTextAlignment(message.role == .user ? .trailing : .leading)
                .textSelection(.enabled)
                .frame(
                    maxWidth: .infinity,
                    alignment: message.role == .user ? .trailing : .leading
                )

            if message.role == .agent {
                Spacer(minLength: 60)
            }
        }
        .id(message.id)
    }
}
