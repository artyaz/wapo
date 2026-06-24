//
//  ScreenshotSelectionController.swift
//  Wapo
//

import AppKit

final class ScreenshotSelectionController {
    typealias Completion = (_ url: URL?, _ cancelled: Bool) -> Void

    private let onComplete: Completion
    private var process: Process?
    private var outputURL: URL?
    private var isFinished = false

    init(screen: NSScreen?, onComplete: @escaping Completion) {
        self.onComplete = onComplete
    }

    func begin() {
        guard process == nil else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wapo-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-i",
            "-s",
            "-x",
            "-Jselection",
            outputURL.path
        ]
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleTermination(of: process)
            }
        }

        self.outputURL = outputURL
        self.process = process

        do {
            try process.run()
        } catch {
            cleanupOutputFile()
            finish(with: nil, cancelled: false)
        }
    }

    func cancel() {
        if let process, process.isRunning {
            process.interrupt()
        }

        cleanupOutputFile()
        finish(with: nil, cancelled: true)
    }

    @MainActor
    private func handleTermination(of process: Process) {
        self.process = nil

        guard !isFinished else {
            cleanupOutputFile()
            return
        }

        guard process.terminationStatus == 0,
              let outputURL,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            cleanupOutputFile()
            finish(with: nil, cancelled: true)
            return
        }

        finish(with: outputURL, cancelled: false)
    }

    private func cleanupOutputFile() {
        guard let outputURL else { return }

        try? FileManager.default.removeItem(at: outputURL)
        self.outputURL = nil
    }

    private func finish(with url: URL?, cancelled: Bool) {
        guard !isFinished else { return }
        isFinished = true
        onComplete(url, cancelled)
    }
}
