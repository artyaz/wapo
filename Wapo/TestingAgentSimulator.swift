//
//  TestingAgentSimulator.swift
//  Wapo
//
//  In-app fallback transport that emits the same typed event stream as the
//  backend testing engine, allowing the SwiftUI client to function when the
//  local Python WebSocket stack is unavailable.
//

import Foundation

struct TestingAgentSimulator {
    func streamResponse(
        for prompt: String,
        onEvent: @escaping @MainActor (WSIncoming) -> Void
    ) -> Task<Void, Never> {
        Task {
            let scenario = buildScenario(for: prompt)
            let messageID = UUID().uuidString

            await emit(.status, data: scenario.planningText, onEvent: onEvent)
            await pause(180_000_000...320_000_000)

            for reasoning in scenario.reasoningSteps.prefix(2) {
                await emit(
                    .reasoning,
                    data: reasoning,
                    metadata: ["elapsed": String(format: "%.1f", Double.random(in: 0.6...1.7))],
                    onEvent: onEvent
                )
                await pause(120_000_000...240_000_000)
            }

            for (index, tool) in scenario.tools.enumerated() {
                guard !Task.isCancelled else { return }
                let callID = "call_\(UUID().uuidString.prefix(8))"

                await emit(
                    .toolStart,
                    data: tool.title,
                    metadata: ["call_id": callID, "tool": tool.name],
                    onEvent: onEvent
                )
                await pause(140_000_000...260_000_000)

                await emit(
                    .toolArgs,
                    data: tool.arguments,
                    metadata: ["call_id": callID, "tool": tool.name],
                    onEvent: onEvent
                )
                await pause(160_000_000...280_000_000)

                for output in tool.outputs {
                    guard !Task.isCancelled else { return }
                    await emit(
                        .toolOutput,
                        data: output,
                        metadata: ["call_id": callID, "tool": tool.name],
                        onEvent: onEvent
                    )
                    await pause(120_000_000...220_000_000)
                }

                await emit(
                    .toolEnd,
                    data: tool.completion,
                    metadata: [
                        "call_id": callID,
                        "tool": tool.name,
                        "status": "success"
                    ],
                    onEvent: onEvent
                )
                await pause(180_000_000...320_000_000)

                if index == scenario.tools.count - 1, scenario.reasoningSteps.count > 2 {
                    await emit(
                        .reasoning,
                        data: scenario.reasoningSteps[2],
                        metadata: ["elapsed": String(format: "%.1f", Double.random(in: 0.7...1.5))],
                        onEvent: onEvent
                    )
                    await pause(120_000_000...220_000_000)
                }
            }

            await emit(
                .messageStart,
                metadata: ["message_id": messageID],
                onEvent: onEvent
            )
            await pause(80_000_000...140_000_000)

            for delta in chunkedText(scenario.finalText) {
                guard !Task.isCancelled else { return }
                await emit(
                    .textDelta,
                    data: delta,
                    metadata: ["message_id": messageID],
                    onEvent: onEvent
                )
                await pause(40_000_000...100_000_000)
            }

            await emit(
                .messageEnd,
                metadata: ["message_id": messageID],
                onEvent: onEvent
            )
        }
    }

    private func emit(
        _ type: WSMessageType,
        data: String? = nil,
        metadata: [String: String]? = nil,
        onEvent: @escaping @MainActor (WSIncoming) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        await onEvent(WSIncoming(type: type, data: data, metadata: metadata))
    }

    private func pause(_ range: ClosedRange<UInt64>) async {
        try? await Task.sleep(nanoseconds: UInt64.random(in: range))
    }

    private func buildScenario(for prompt: String) -> SimulatedScenario {
        let cleanedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = extractAttachments(from: cleanedPrompt)
        let normalizedPrompt = cleanedPrompt.lowercased()

        var tools: [SimulatedTool] = []
        if !attachments.isEmpty {
            tools.append(
                SimulatedTool(
                    name: "attachment_inspector",
                    title: "Inspecting attached files",
                    arguments: """
                    {
                      "attachments": [\(attachments.map { "\"\($0)\"" }.joined(separator: ", "))],
                      "mode": "summarize"
                    }
                    """,
                    outputs: [
                        "Queued \(attachments.count) attachment(s) for inspection.",
                        "Previewed: \(attachments.prefix(3).joined(separator: ", "))."
                    ],
                    completion: "Attachment inspection complete"
                )
            )
        }

        if normalizedPrompt.contains("calendar") || normalizedPrompt.contains("meeting") || normalizedPrompt.contains("schedule") {
            tools.append(
                SimulatedTool(
                    name: "calendar_lookup",
                    title: "Checking schedule context",
                    arguments: """
                    {
                      "query": "\(compact(cleanedPrompt))",
                      "window": "next_7_days"
                    }
                    """,
                    outputs: [
                        "Found 3 upcoming events related to the request.",
                        "Detected a possible overlap on Thursday at 14:00."
                    ],
                    completion: "Calendar lookup complete"
                )
            )
        } else if normalizedPrompt.contains("inbox") || normalizedPrompt.contains("email") || normalizedPrompt.contains("mail") {
            tools.append(
                SimulatedTool(
                    name: "inbox_triage",
                    title: "Scanning inbox priorities",
                    arguments: """
                    {
                      "query": "\(compact(cleanedPrompt))",
                      "limit": 12
                    }
                    """,
                    outputs: [
                        "Ranked 12 messages by urgency and sender importance.",
                        "Marked 2 threads as needing a same-day reply."
                    ],
                    completion: "Inbox triage complete"
                )
            )
        } else {
            tools.append(
                SimulatedTool(
                    name: "workspace_search",
                    title: "Searching local workspace context",
                    arguments: """
                    {
                      "query": "\(compact(cleanedPrompt))",
                      "scope": "recent_files"
                    }
                    """,
                    outputs: [
                        "Matched 4 local notes and 1 recent project artifact.",
                        "Extracted the most relevant snippets for synthesis."
                    ],
                    completion: "Workspace search complete"
                )
            )
        }

        if tools.count == 1 {
            tools.append(
                SimulatedTool(
                    name: "answer_synthesizer",
                    title: "Summarizing the gathered context",
                    arguments: """
                    {
                      "goal": "draft_reply",
                      "target": "\(attachments.first ?? "collected findings")"
                    }
                    """,
                    outputs: [
                        "Condensed the findings into a short narrative.",
                        "Prepared a reply draft for the current request."
                    ],
                    completion: "Summary draft prepared"
                )
            )
        }

        let planningText = [
            "Planning the next steps…",
            "Breaking the request into live tasks…",
            "Building an execution path…"
        ].randomElement() ?? "Planning the next steps…"

        let reasoningSteps = [
            [
                "Scoping the request",
                "Choosing the fastest path",
                "Composing the response"
            ],
            [
                "Identifying the first useful tool",
                "Collecting structured inputs",
                "Merging the findings"
            ],
            [
                "Sizing up the context",
                "Waiting for tool output",
                "Turning the run into a final answer"
            ]
        ].randomElement() ?? [
            "Scoping the request",
            "Collecting structured inputs",
            "Composing the response"
        ]

        let opener = [
            "Here’s a streamed test response from the in-app simulator.",
            "The local testing transport just replayed a fake agent run.",
            "This is a simulated agent pass designed to exercise the realtime UI."
        ].randomElement() ?? "Here’s a streamed test response from the in-app simulator."

        let attachmentSummary = attachments.isEmpty
            ? ""
            : " I also noticed \(attachments.count) attachment(s): \(attachments.prefix(3).joined(separator: ", "))."

        let finalText =
            "\(opener) It walked through \(tools.map { $0.title.lowercased() }.joined(separator: ", ")), streamed tool progress, and then assembled this reply around “\(compact(cleanedPrompt))”.\(attachmentSummary)\n\nWhen the Python backend is ready, it can emit the same event types and the UI should behave the same way."

        return SimulatedScenario(
            planningText: planningText,
            reasoningSteps: reasoningSteps,
            tools: tools.prefix(2).map { $0 },
            finalText: finalText
        )
    }

    private func extractAttachments(from prompt: String) -> [String] {
        let lines = prompt.split(whereSeparator: \.isNewline).map(String.init)
        guard let startIndex = lines.firstIndex(of: "Attachments:") else { return [] }

        return lines[(startIndex + 1)...]
            .prefix { $0.hasPrefix("- ") }
            .map { $0.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces) }
    }

    private func chunkedText(_ text: String) -> [String] {
        var chunks: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let tentativeEnd = text.index(cursor, offsetBy: Int.random(in: 18...36), limitedBy: text.endIndex) ?? text.endIndex
            var end = tentativeEnd

            while end < text.endIndex && text[end] != " " && text[end] != "\n" {
                end = text.index(after: end)
            }

            chunks.append(String(text[cursor..<end]))
            cursor = end
        }

        return chunks.filter { !$0.isEmpty }
    }

    private func compact(_ text: String, limit: Int = 120) -> String {
        let compacted = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard compacted.count > limit else { return compacted }
        return String(compacted.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private struct SimulatedScenario {
    let planningText: String
    let reasoningSteps: [String]
    let tools: [SimulatedTool]
    let finalText: String
}

private struct SimulatedTool {
    let name: String
    let title: String
    let arguments: String
    let outputs: [String]
    let completion: String
}
