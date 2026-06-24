//
//  SettingsWindow.swift
//  Wapo
//
//  Minimal SwiftUI settings window with a backend dropdown and the
//  credential/connection fields required by the selected backend. Hosted in
//  a borderless-titled NSWindow opened from the menu bar context menu.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(store: BackendSettingsStore.shared)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Wapo Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 360))
        window.center()
        window.delegate = SettingsWindowDelegate.shared

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidClose() {
        window = nil
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindowController.shared.windowDidClose()
        }
    }
}

// MARK: - SwiftUI

private struct SettingsView: View {
    @Bindable var store: BackendSettingsStore
    @State private var probeState: ProbeState = .idle
    @State private var modelsState: ModelsState = .idle
    @State private var modelLoadTask: Task<Void, Never>?

    private enum ProbeState: Equatable {
        case idle
        case probing
        case ok(String)
        case failure(String)
    }

    private enum ModelsState: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Backend", selection: $store.kind) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
            }

            switch store.kind {
            case .localLangGraph:
                Section {
                    Text("Uses the bundled Python backend on loopback (port \(BackendEndpoint.port)). No credentials required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .hermes:
                hermesSection
            }

            Section {
                HStack {
                    Button("Test Connection") { Task { await probe() } }
                        .disabled(probeState == .probing)
                    if case .probing = probeState {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    statusBadge
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 440, minHeight: 340)
    }

    private var hermesSection: some View {
        Section("Hermes Agent") {
            TextField("Base URL", text: $store.hermes.baseURL, prompt: Text("http://127.0.0.1:8642/v1"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: store.hermes.baseURL) { scheduleModelLoad() }
            SecureField("API Key", text: $store.hermesAPIKey, prompt: Text("API_SERVER_KEY"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: store.hermesAPIKey) { scheduleModelLoad() }

            modelPicker

            Text("On the Hermes host, run: `hermes config set API_SERVER_ENABLED true` and `hermes config set API_SERVER_KEY <key>`, then restart `hermes gateway`.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(store.hermes.baseURL)|\(store.hermesAPIKey)") {
            await loadModels()
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch modelsState {
            case .loaded(let ids) where !ids.isEmpty:
                Picker("Model", selection: $store.hermes.model) {
                    ForEach(ids, id: \.self) { id in
                        Text(id).tag(id)
                    }
                    if !ids.contains(store.hermes.model), !store.hermes.model.isEmpty {
                        Text("\(store.hermes.model) (custom)").tag(store.hermes.model)
                    }
                }
                .pickerStyle(.menu)

            default:
                TextField("Model", text: $store.hermes.model, prompt: Text("hermes-agent"))
                    .textFieldStyle(.roundedBorder)
            }

            switch modelsState {
            case .idle:
                Button("Load") { Task { await loadModels(force: true) } }
                    .buttonStyle(.borderless)
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let ids):
                Text("\(ids.count) available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Retry") { Task { await loadModels(force: true) } }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func scheduleModelLoad() {
        modelLoadTask?.cancel()
        modelLoadTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private func loadModels(force: Bool = false) async {
        guard store.kind == .hermes else { return }

        let trimmedURL = store.hermes.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let base = URL(string: trimmedURL) else {
            modelsState = .idle
            return
        }
        if case .loading = modelsState, !force { return }

        modelsState = .loading
        let apiKey = store.hermesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let ids = try await HermesBackend.fetchModels(baseURL: base, apiKey: apiKey)
            modelsState = .loaded(ids)
            // Auto-select if the current model isn't valid and exactly one is offered.
            if !ids.contains(store.hermes.model) {
                if let first = ids.first, ids.count == 1 || store.hermes.model.isEmpty {
                    store.hermes.model = first
                }
            }
        } catch {
            modelsState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch probeState {
        case .idle:
            EmptyView()
        case .probing:
            EmptyView()
        case .ok(let detail):
            Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func probe() async {
        probeState = .probing
        switch store.kind {
        case .localLangGraph:
            let ok = await BackendProcessController.shared.backendReady()
            probeState = ok ? .ok("Reachable") : .failure("Not reachable on loopback")

        case .hermes:
            guard let base = URL(string: store.hermes.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                probeState = .failure("Invalid base URL")
                return
            }
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let key = store.hermesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let code = http.statusCode
                    let finalURL = http.url?.absoluteString ?? url.absoluteString
                    probeState = (200...299).contains(code)
                        ? .ok("HTTP \(code) — \(finalURL)")
                        : .failure("HTTP \(code) at \(finalURL)\(code == 401 ? " (bad API key)" : "")")
                } else {
                    probeState = .failure("Unexpected response from \(url.absoluteString)")
                }
            } catch {
                probeState = .failure("\(error.localizedDescription) — tried \(url.absoluteString)")
            }
        }
    }
}
