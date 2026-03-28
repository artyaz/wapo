//
//  ContentView.swift
//  Wapo
//
//  Created by Artem Chmylenko on 28.03.2026.
//
//  Root SwiftUI content injected into the FloatingPanel via NSHostingView.
//  Uses GlassEffectContainer for the macOS 26 Tahoe "Liquid Glass" aesthetic.
//  Each module block is a stacked, pill-shaped glass element — no solid fills.
//

import SwiftUI

// MARK: - Panel Content (injected into FloatingPanel)

struct PanelContentView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 8) {
                headerModule
                chatModule
                inputModule
            }
            .padding(12)
        }
        .onAppear { viewModel.connect() }
        .onDisappear { viewModel.disconnect() }
    }

    // MARK: - Header Module

    private var headerModule: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)

            Text("Wapo")
                .font(.system(.headline, design: .rounded, weight: .semibold))

            Spacer()

            Text(viewModel.isConnected ? "Connected" : "Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: - Chat Transcript Module

    private var chatModule: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                    }

                    // Agent status indicators (left-aligned progressive list)
                    if !viewModel.statusIndicators.isEmpty || viewModel.isAgentThinking {
                        StatusIndicatorView(
                            indicators: viewModel.statusIndicators,
                            isThinking: viewModel.isAgentThinking
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Liquid Glass Input Module

    private var inputModule: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $viewModel.currentInput)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { viewModel.sendMessage() }

            Button(action: { viewModel.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.currentInput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Previews

#Preview {
    PanelContentView(viewModel: ChatViewModel())
        .frame(width: 380, height: 620)
}

