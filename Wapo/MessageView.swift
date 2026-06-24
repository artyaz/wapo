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

            VStack(
                alignment: message.role == .user ? .trailing : .leading,
                spacing: 8
            ) {
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(message.role == .user ? .primary : .secondary)
                        .multilineTextAlignment(message.role == .user ? .trailing : .leading)
                        .textSelection(.enabled)
                        .shadow(color: .black.opacity(0.14), radius: 1.2, x: 0, y: 1)
                }

                if !message.attachments.isEmpty {
                    MessageAttachmentStripView(
                        attachments: message.attachments,
                        alignment: message.role == .user ? .trailing : .leading
                    )
                }
            }
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
