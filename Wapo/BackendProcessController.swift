//
//  BackendProcessController.swift
//  Wapo
//
//  Starts and monitors the local Python backend used by the menu bar app during
//  development. Prefers an already running backend and falls back to launching
//  `Backend/server.py` when needed.
//

import Foundation

@MainActor
final class BackendProcessController {
    static let shared = BackendProcessController()

    private var process: Process?
    private var logPipe: Pipe?
    private var isLaunching = false
    private(set) var lastLaunchIssue: String?
    private(set) var lastLogLine: String?

    func ensureRunning() async -> Bool {
        guard !isLaunching else {
            return await waitUntilHealthy()
        }

        if await isHealthy() {
            lastLaunchIssue = nil
            return true
        }

        guard process == nil else {
            return await waitUntilHealthy()
        }

        guard let serverScriptURL = resolveBackendServerScriptURL() else {
            let issue = "Could not locate the bundled backend server."
            NSLog("Wapo backend: %@", issue)
            lastLaunchIssue = issue
            return false
        }

        guard let pythonURL = resolvePythonExecutableURL() else {
            let issue = "Could not locate a sandbox-safe Python interpreter."
            NSLog("Wapo backend: %@", issue)
            lastLaunchIssue = issue
            return false
        }

        isLaunching = true
        defer { isLaunching = false }

        let process = Process()
        process.executableURL = pythonURL
        process.currentDirectoryURL = serverScriptURL.deletingLastPathComponent()
        process.arguments = [serverScriptURL.lastPathComponent]

        var environment = ProcessInfo.processInfo.environment
        if environment["WAPO_AGENT_ENGINE"] == nil {
            environment["WAPO_AGENT_ENGINE"] = "testing"
        }
        if environment["PYTHONDONTWRITEBYTECODE"] == nil {
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        }
        if environment["WAPO_BACKEND_PORT"] == nil {
            environment["WAPO_BACKEND_PORT"] = String(BackendEndpoint.port)
        }
        process.environment = environment

        let logPipe = Pipe()
        process.standardOutput = logPipe
        process.standardError = logPipe
        logPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("Wapo backend: %@", trimmed)
            Task { @MainActor [weak self] in
                self?.lastLogLine = trimmed
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            NSLog("Wapo backend exited with status %d", terminatedProcess.terminationStatus)
            Task { @MainActor [weak self] in
                if terminatedProcess.terminationStatus != 0 {
                    self?.lastLaunchIssue = self?.lastLogLine ?? "Backend exited with status \(terminatedProcess.terminationStatus)."
                }
                self?.process = nil
                self?.logPipe?.fileHandleForReading.readabilityHandler = nil
                self?.logPipe = nil
            }
        }

        do {
            NSLog("Wapo backend: launching with Python at %@", pythonURL.path)
            try process.run()
            self.process = process
            self.logPipe = logPipe
            let didBecomeHealthy = await waitUntilHealthy(timeoutSeconds: 8)
            if didBecomeHealthy {
                lastLaunchIssue = nil
                return true
            }

            lastLaunchIssue = lastLogLine ?? "The backend launched but never became healthy on loopback."
        } catch {
            NSLog("Wapo backend failed to launch: %@", error.localizedDescription)
            lastLaunchIssue = error.localizedDescription
            logPipe.fileHandleForReading.readabilityHandler = nil
            self.logPipe = nil
            self.process = nil
            return false
        }

        return false
    }

    func terminateIfNeeded() {
        isLaunching = false
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil

        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }

    func backendReady() async -> Bool {
        await isHealthy()
    }

    private func isHealthy() async -> Bool {
        for url in BackendEndpoint.healthURLs {
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.8

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }
                if httpResponse.statusCode == 200 {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    private func waitUntilHealthy(timeoutSeconds: Double = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if await isHealthy() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        return false
    }

    private func resolveBackendServerScriptURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        var candidates: [URL] = []

        if let bundledResources = Bundle.main.resourceURL {
            candidates.append(
                bundledResources
                    .appendingPathComponent("Backend")
                    .appendingPathComponent("server.py")
            )
        }

        if let explicitFile = environment["WAPO_BACKEND_SERVER_PATH"] {
            candidates.append(URL(fileURLWithPath: explicitFile))
        }

        if let projectRoot = environment["WAPO_PROJECT_ROOT"] {
            candidates.append(
                URL(fileURLWithPath: projectRoot)
                    .appendingPathComponent("Backend/server.py")
            )
        }

        var cursor = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            candidates.append(cursor.appendingPathComponent("Backend/server.py"))
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }

        let fallbackHomeCandidate = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("development/Wapo/Backend/server.py")
        candidates.append(fallbackHomeCandidate)

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func resolvePythonExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        var candidates: [URL] = []

        if let explicitPath = environment["WAPO_PYTHON_PATH"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"),
            URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
        ])

        for candidate in candidates {
            let resolvedPath = candidate.resolvingSymlinksInPath().path
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            if fileManager.isExecutableFile(atPath: resolvedPath) {
                return URL(fileURLWithPath: resolvedPath)
            }
        }

        return nil
    }
}
