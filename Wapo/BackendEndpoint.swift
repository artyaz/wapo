//
//  BackendEndpoint.swift
//  Wapo
//
//  Centralizes the local backend loopback configuration so the app can probe
//  both 127.0.0.1 and localhost while still respecting optional environment
//  overrides for development.
//

import Foundation

enum BackendEndpoint {
    static var port: Int {
        if let rawValue = ProcessInfo.processInfo.environment["WAPO_BACKEND_PORT"],
           let parsed = Int(rawValue),
           parsed > 0 {
            return parsed
        }

        return 8765
    }

    static var hosts: [String] {
        let environment = ProcessInfo.processInfo.environment
        var orderedHosts: [String] = []

        if let preferred = environment["WAPO_BACKEND_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            orderedHosts.append(preferred)
        } else {
            orderedHosts.append("127.0.0.1")
        }

        if let fallback = environment["WAPO_BACKEND_FALLBACK_HOSTS"]?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {
            orderedHosts.append(contentsOf: fallback)
        }

        var deduped: [String] = []
        for host in orderedHosts where !deduped.contains(host) {
            deduped.append(host)
        }
        return deduped
    }

    static var healthURLs: [URL] {
        hosts.compactMap { URL(string: "http://\($0):\(port)/health") }
    }

    static var webSocketURLs: [URL] {
        hosts.compactMap { URL(string: "ws://\($0):\(port)/ws") }
    }
}
