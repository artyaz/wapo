//
//  HermesBackend.swift
//  Wapo
//
//  Talks to a Hermes Agent API server (https://hermes-agent.nousresearch.com)
//  via its OpenAI-compatible Responses endpoint (`POST /v1/responses`) with
//  SSE streaming. The Responses API emits spec-native `function_call` /
//  `function_call_output` items, which we translate into the same tool-call
//  chips the local LangGraph backend uses. The older `/v1/chat/completions`
//  endpoint hides tool calls behind the final text response.
//
//  Server-side requirements (run on the Hermes host):
//    hermes config set API_SERVER_ENABLED true
//    hermes config set API_SERVER_KEY <your-secret-key>
//    hermes gateway stop && hermes gateway
//
//  Then in this app's Settings panel:
//    Base URL: http://<hermes-host>:8642/v1
//    API Key:  <your-secret-key>
//    Model:    hermes-agent  (or your configured profile name)
//
//  This client:
//   • streams text deltas from `choices[].delta.content` (Chat Completions)
//     or `response.output_text.delta` (Responses API),
//   • surfaces tool calls as tool_start / tool_args / tool_end events that
//     the existing chat UI renders (the same path the local LangGraph
//     backend uses), supporting both Chat Completions tool_calls deltas and
//     Responses-API function_call / function_call_output items,
//   • inlines image attachments as base64 image_url parts and reads
//     text-like attachments inline as fenced code blocks. Other binaries
//     are mentioned by name + size (Hermes can't fetch local files).
//

import Foundation
import UniformTypeIdentifiers

actor HermesBackend: AgentBackend {
    private let session: URLSession
    private var settingsProvider: @Sendable () -> (base: URL?, apiKey: String, model: String)
    private var sink: BackendEventSink?

    init(settingsProvider: @escaping @Sendable () -> (base: URL?, apiKey: String, model: String)) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
        self.settingsProvider = settingsProvider
    }

    func setEventSink(_ sink: @escaping BackendEventSink) async {
        self.sink = sink
    }

    func disconnect() async {}

    func isReachable() async -> Bool {
        let (base, apiKey, _) = settingsProvider()
        return await Self.probe(base: base, apiKey: apiKey, session: session) != nil
    }

    /// Fetches `/v1/models` and returns the list of model ids. Returns nil
    /// if the call fails or the response isn't valid.
    static func fetchModels(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesModelsError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw HermesModelsError.http(status: http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw HermesModelsError.invalidResponse
        }
        return items.compactMap { $0["id"] as? String }
    }

    private static func probe(base: URL?, apiKey: String, session: URLSession) async -> Int? {
        guard let base else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 4
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode,
                  (200...299).contains(code) else { return nil }
            return code
        } catch {
            return nil
        }
    }
}

enum HermesModelsError: LocalizedError {
    case invalidResponse
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Unexpected response from /v1/models"
        case .http(let status): status == 401 ? "Unauthorized — check the API key" : "HTTP \(status) from /v1/models"
        }
    }
}

extension HermesBackend {

    func send(text: String, attachments: [AttachmentItem], history: [OutboundTurn]) async {
        guard let onEvent = sink else { return }
        let (base, apiKey, model) = settingsProvider()

        guard let base else {
            onEvent(BackendEventFactory.error("Hermes base URL is not configured. Open Settings and set it (e.g. http://127.0.0.1:8642/v1)."))
            return
        }

        // Use the Responses API (not /chat/completions) so Hermes streams
        // spec-native `function_call` / `function_call_output` items that
        // we surface as tool-call chips in the chat UI. The Chat Completions
        // endpoint hides tool calls behind the final text response.
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let input = Self.buildResponsesInput(
            history: history,
            latestUserText: text,
            latestAttachments: attachments
        )

        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "input": input,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            onEvent(BackendEventFactory.error("Failed to encode Hermes request: \(error.localizedDescription)"))
            return
        }

        let messageID = UUID()
        onEvent(BackendEventFactory.messageStart(id: messageID))

        var streamState = StreamState()

        do {
            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines {
                    body += line + "\n"
                    if body.count > 2048 { break }
                }
                let hint = http.statusCode == 401 ? " (check API key)" : ""
                onEvent(BackendEventFactory.error("Hermes returned HTTP \(http.statusCode)\(hint).\n\(body.prefix(1024))"))
                onEvent(BackendEventFactory.messageEnd(messageID: messageID))
                return
            }

            for try await line in bytes.lines {
                guard !Task.isCancelled else { break }
                guard line.hasPrefix("data:") else { continue }

                let payloadString = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)

                if payloadString.isEmpty { continue }
                if payloadString == "[DONE]" { break }

                guard let data = payloadString.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                Self.processChunk(
                    chunk,
                    messageID: messageID,
                    state: &streamState,
                    emit: onEvent
                )
            }

            // Close out any tool calls that didn't get an explicit completion.
            streamState.finalize(emit: onEvent)
            onEvent(BackendEventFactory.messageEnd(messageID: messageID))
        } catch {
            streamState.finalize(emit: onEvent)
            if (error as? URLError)?.code == .cancelled {
                onEvent(BackendEventFactory.messageEnd(messageID: messageID))
                return
            }
            onEvent(BackendEventFactory.error("Hermes request failed: \(error.localizedDescription)"))
            onEvent(BackendEventFactory.messageEnd(messageID: messageID))
        }
    }

    // MARK: - Stream state

    /// Tracks in-flight tool calls so we can emit a single tool_start / many
    /// tool_args / one tool_end pair per call across both Chat Completions
    /// and Responses-API event shapes.
    ///
    /// OpenAI's Responses API uses two distinct identifiers per tool call:
    ///   • `item.id` (e.g. `fc_…`) — the function_call item id, referenced
    ///     by `response.function_call_arguments.*` events via `item_id`
    ///   • `item.call_id` (e.g. `call_…`) — the call identifier, referenced
    ///     by `response.output_item.done(function_call_output)` via `call_id`
    /// We pick one canonical key per call (preferring `call_id` for stable
    /// matching with the matching output) and maintain an aliases map so a
    /// lookup with either id resolves to the same Call.
    private struct StreamState {
        struct Call {
            var id: String          // canonical id surfaced to the UI
            var name: String
            var argsBuffer: String = ""
            var startedEmitted: Bool = false
            var completed: Bool = false
        }

        // Chat Completions tool_calls are addressed by `index`.
        var byIndex: [Int: Call] = [:]
        // Responses API: canonical store keyed by call.id; aliases lets us
        // look up by any of (item.id, item.call_id).
        var callsByID: [String: Call] = [:]
        var aliases: [String: String] = [:]   // alias → canonical id

        mutating func registerAlias(_ alias: String, for canonicalID: String) {
            guard !alias.isEmpty, alias != canonicalID else { return }
            aliases[alias] = canonicalID
        }

        func resolveCanonical(_ anyID: String) -> String? {
            if callsByID[anyID] != nil { return anyID }
            if let canon = aliases[anyID], callsByID[canon] != nil { return canon }
            return nil
        }

        mutating func finalize(emit: BackendEventSink) {
            for (key, call) in byIndex where !call.completed {
                byIndex[key]?.completed = true
                emit(toolEndEvent(for: call))
            }
            for (key, call) in callsByID where !call.completed {
                callsByID[key]?.completed = true
                emit(toolEndEvent(for: call))
            }
        }
    }

    // MARK: - Chunk processing

    private nonisolated static func processChunk(
        _ chunk: [String: Any],
        messageID: UUID,
        state: inout StreamState,
        emit: BackendEventSink
    ) {
        // 1. Plain text delta — both APIs.
        if let delta = extractContentDelta(from: chunk), !delta.isEmpty {
            emit(BackendEventFactory.textDelta(delta, messageID: messageID))
        }

        // 2. Chat Completions: choices[].delta.tool_calls[]
        if let choices = chunk["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                processChatToolCallDelta(tc, state: &state, emit: emit)
            }
        }

        // 3. Responses API: typed events
        if let type = chunk["type"] as? String {
            processResponsesEvent(type: type, chunk: chunk, state: &state, emit: emit)
        }
    }

    private nonisolated static func processChatToolCallDelta(
        _ tc: [String: Any],
        state: inout StreamState,
        emit: BackendEventSink
    ) {
        guard let index = tc["index"] as? Int else { return }
        let id = tc["id"] as? String
        let function = tc["function"] as? [String: Any]
        let name = function?["name"] as? String
        let argsFragment = function?["arguments"] as? String

        var call = state.byIndex[index] ?? StreamState.Call(id: id ?? "tool_\(index)", name: "")
        if let id, !id.isEmpty { call.id = id }
        if let name, !name.isEmpty { call.name = name }

        if !call.startedEmitted, !call.name.isEmpty {
            emit(toolStartEvent(for: call))
            call.startedEmitted = true
        }

        if let argsFragment, !argsFragment.isEmpty {
            call.argsBuffer.append(argsFragment)
            emit(toolArgsEvent(for: call, fragment: argsFragment))
        }

        state.byIndex[index] = call

        if let finishReason = tc["finish_reason"] as? String, finishReason == "tool_calls" {
            call.completed = true
            emit(toolEndEvent(for: call))
            state.byIndex[index] = call
        }
    }

    private nonisolated static func processResponsesEvent(
        type: String,
        chunk: [String: Any],
        state: inout StreamState,
        emit: BackendEventSink
    ) {
        switch type {
        case "response.output_item.added":
            guard let item = chunk["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "function_call" else { return }

            // Prefer `call_id` as canonical so function_call_output can match
            // directly; fall back to `id` if not provided.
            let itemID = item["id"] as? String
            let callID = item["call_id"] as? String
            let canonical = callID ?? itemID ?? UUID().uuidString
            let name = item["name"] as? String ?? "tool"

            var call = StreamState.Call(id: canonical, name: name)
            emit(toolStartEvent(for: call))
            call.startedEmitted = true
            if let initialArgs = item["arguments"] as? String, !initialArgs.isEmpty {
                call.argsBuffer.append(initialArgs)
                emit(toolArgsEvent(for: call, fragment: initialArgs))
            }
            state.callsByID[canonical] = call
            if let itemID { state.registerAlias(itemID, for: canonical) }
            if let callID { state.registerAlias(callID, for: canonical) }

        case "response.function_call_arguments.delta":
            guard let itemID = chunk["item_id"] as? String,
                  let delta = chunk["delta"] as? String,
                  !delta.isEmpty else { return }
            let canonical = state.resolveCanonical(itemID) ?? itemID
            var call = state.callsByID[canonical]
                ?? StreamState.Call(id: canonical, name: "tool")
            if !call.startedEmitted {
                emit(toolStartEvent(for: call))
                call.startedEmitted = true
            }
            call.argsBuffer.append(delta)
            emit(toolArgsEvent(for: call, fragment: delta))
            state.callsByID[canonical] = call
            state.registerAlias(itemID, for: canonical)

        case "response.function_call_arguments.done":
            guard let itemID = chunk["item_id"] as? String,
                  let canonical = state.resolveCanonical(itemID),
                  var call = state.callsByID[canonical] else { return }
            if let final = chunk["arguments"] as? String, !final.isEmpty,
               final != call.argsBuffer {
                call.argsBuffer = final
            }
            state.callsByID[canonical] = call

        case "response.output_item.done":
            guard let item = chunk["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return }

            if itemType == "function_call_output" {
                let lookupID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                let output = (item["output"] as? String) ?? ""
                let canonical = state.resolveCanonical(lookupID) ?? lookupID
                var call = state.callsByID[canonical]
                    ?? StreamState.Call(id: canonical, name: "tool")
                if !output.isEmpty {
                    emit(toolOutputEvent(for: call, output: output))
                }
                if !call.completed {
                    call.completed = true
                    emit(toolEndEvent(for: call))
                }
                state.callsByID[canonical] = call
            } else if itemType == "function_call" {
                // The function_call item finishing means args are done; the
                // matching function_call_output (if any) will close the call.
                // Only emit tool_end here if we haven't already and no output
                // item is expected (some servers skip function_call_output).
                let itemID = item["id"] as? String
                let callID = item["call_id"] as? String
                let lookup = itemID ?? callID ?? ""
                if let canonical = state.resolveCanonical(lookup),
                   let call = state.callsByID[canonical],
                   !call.completed {
                    // Don't close yet — wait for function_call_output. The
                    // top-level `finalize` will close it at stream end if no
                    // output ever arrives. We just keep the entry around;
                    // no mutation needed here.
                    _ = call
                }
            }

        default:
            break
        }
    }

    // MARK: - WSIncoming factories for tool events

    private nonisolated static func toolStartEvent(for call: StreamState.Call) -> WSIncoming {
        WSIncoming(
            type: .toolStart,
            data: call.name,
            metadata: ["call_id": call.id, "tool": call.name]
        )
    }

    private nonisolated static func toolArgsEvent(
        for call: StreamState.Call,
        fragment: String
    ) -> WSIncoming {
        WSIncoming(
            type: .toolArgs,
            data: fragment,
            metadata: ["call_id": call.id, "tool": call.name]
        )
    }

    private nonisolated static func toolOutputEvent(
        for call: StreamState.Call,
        output: String
    ) -> WSIncoming {
        WSIncoming(
            type: .toolOutput,
            data: output,
            metadata: ["call_id": call.id, "tool": call.name]
        )
    }

    private nonisolated static func toolEndEvent(for call: StreamState.Call) -> WSIncoming {
        WSIncoming(
            type: .toolEnd,
            data: "",
            metadata: ["call_id": call.id, "tool": call.name]
        )
    }

    // MARK: - Message construction (Responses API `input` array)

    /// Builds the `input` array for `POST /v1/responses`. Each turn is a
    /// `message` item with role-specific content parts:
    ///   • user → `input_text` / `input_image`
    ///   • assistant → `output_text`
    private nonisolated static func buildResponsesInput(
        history: [OutboundTurn],
        latestUserText: String,
        latestAttachments: [AttachmentItem]
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []

        // Drop the latest user turn from history since we re-emit it below
        // with multimodal parts (view model already appended it).
        var historyTurns = history
        if let last = historyTurns.last, last.role == .user, last.content == latestUserText {
            historyTurns.removeLast()
        }

        for turn in historyTurns {
            switch turn.role {
            case .user:
                items.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": turn.content]],
                ])
            case .assistant:
                items.append([
                    "role": "assistant",
                    "content": [["type": "output_text", "text": turn.content]],
                ])
            }
        }

        items.append([
            "role": "user",
            "content": buildUserContentParts(text: latestUserText, attachments: latestAttachments),
        ])

        return items
    }

    /// Responses-API user content parts: `input_text` for text, `input_image`
    /// for images. Text-like attachments are inlined into the text part as
    /// fenced code blocks; other binaries are mentioned by name + size since
    /// the Hermes host can't fetch local files.
    private nonisolated static func buildUserContentParts(
        text: String,
        attachments: [AttachmentItem]
    ) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        var inlinedTextBlocks: [String] = []
        var unsupportedNotes: [String] = []

        for attachment in attachments {
            switch classify(attachment.url) {
            case .image(let mime):
                if let data = try? Data(contentsOf: attachment.url) {
                    let base64 = data.base64EncodedString()
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(mime);base64,\(base64)",
                    ])
                } else {
                    unsupportedNotes.append("\(attachment.displayName) (failed to read)")
                }

            case .text:
                if let data = try? Data(contentsOf: attachment.url),
                   let body = String(data: data, encoding: .utf8) {
                    let truncated = body.count > 64_000
                        ? String(body.prefix(64_000)) + "\n…(truncated)"
                        : body
                    inlinedTextBlocks.append(
                        "File: \(attachment.displayName)\n```\n\(truncated)\n```"
                    )
                } else {
                    unsupportedNotes.append("\(attachment.displayName) (couldn't decode as text)")
                }

            case .other(let sizeBytes):
                let size = sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size"
                unsupportedNotes.append("\(attachment.displayName) (\(size)) — binary not inlined")
            }
        }

        var finalText = text
        if !inlinedTextBlocks.isEmpty {
            finalText += (finalText.isEmpty ? "" : "\n\n") + inlinedTextBlocks.joined(separator: "\n\n")
        }
        if !unsupportedNotes.isEmpty {
            finalText += (finalText.isEmpty ? "" : "\n\n")
                + "Attached (not inlined):\n"
                + unsupportedNotes.map { "- \($0)" }.joined(separator: "\n")
        }

        // Text part comes first per OpenAI convention.
        if !finalText.isEmpty {
            parts.insert(["type": "input_text", "text": finalText], at: 0)
        } else if parts.isEmpty {
            // Responses API requires at least one content part; empty user
            // turn with no attachments is a no-op upstream but we still
            // need a valid array.
            parts.append(["type": "input_text", "text": ""])
        }

        return parts
    }

    private enum AttachmentClass {
        case image(mime: String)
        case text
        case other(sizeBytes: Int?)
    }

    private nonisolated static func classify(_ url: URL) -> AttachmentClass {
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)

        if let type, type.conforms(to: .image) {
            let mime = type.preferredMIMEType ?? "image/png"
            return .image(mime: mime)
        }

        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) {
            return .text
        }

        // Fallback: try common text-y extensions.
        let textExts: Set<String> = [
            "txt", "md", "markdown", "json", "yaml", "yml", "toml",
            "csv", "tsv", "log", "ini", "conf",
            "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb",
            "c", "cc", "cpp", "h", "hpp", "m", "mm", "java", "kt",
            "sh", "bash", "zsh", "html", "css", "xml",
        ]
        if textExts.contains(url.pathExtension.lowercased()) {
            return .text
        }

        return .other(sizeBytes: size)
    }

    /// Handles both Chat Completions (`choices[].delta.content`) and the
    /// Responses API (`response.output_text.delta`) streaming shapes.
    private nonisolated static func extractContentDelta(from chunk: [String: Any]) -> String? {
        if let choices = chunk["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }

        if let type = chunk["type"] as? String,
           type == "response.output_text.delta",
           let delta = chunk["delta"] as? String {
            return delta
        }

        return nil
    }
}
