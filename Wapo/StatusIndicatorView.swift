//
//  StatusIndicatorView.swift
//  Wapo
//
//  Progressive, left-aligned status indicators showing the agent's cognitive state.
//  Surfaces reasoning duration, tool loading, and active task status.
//

import SwiftUI

struct StatusIndicatorView: View {
    let indicators: [AgentStatus]
    let isThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(indicators) { indicator in
                HStack(spacing: 6) {
                    if indicator.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(indicator.text)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isThinking && (indicators.isEmpty || indicators.last?.isLoading != true) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: indicators.count)
    }
}
