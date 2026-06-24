//
//  BackendSettings.swift
//  Wapo
//
//  Persisted user-facing configuration for which agent backend the app talks
//  to and the credentials needed to reach it. Backed by UserDefaults today;
//  the API-key accessor is isolated so it can be promoted to Keychain later
//  without touching call sites.
//

import Foundation
import SwiftUI

enum BackendKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case localLangGraph
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localLangGraph: "Local (LangGraph)"
        case .hermes:         "Hermes Agent"
        }
    }
}

struct HermesSettings: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String

    static let `default` = HermesSettings(
        baseURL: "http://127.0.0.1:8642/v1",
        model: "hermes-agent"
    )
}

@Observable
final class BackendSettingsStore {
    static let shared = BackendSettingsStore()

    private enum Keys {
        static let backendKind   = "wapo.backend.kind"
        static let hermesBaseURL = "wapo.backend.hermes.baseURL"
        static let hermesModel   = "wapo.backend.hermes.model"
        static let hermesAPIKey  = "wapo.backend.hermes.apiKey" // TODO: migrate to Keychain
    }

    private let defaults: UserDefaults

    var kind: BackendKind {
        didSet {
            guard kind != oldValue else { return }
            defaults.set(kind.rawValue, forKey: Keys.backendKind)
            NotificationCenter.default.post(name: .backendSettingsChanged, object: nil)
        }
    }

    var hermes: HermesSettings {
        didSet {
            guard hermes != oldValue else { return }
            defaults.set(hermes.baseURL, forKey: Keys.hermesBaseURL)
            defaults.set(hermes.model,   forKey: Keys.hermesModel)
            NotificationCenter.default.post(name: .backendSettingsChanged, object: nil)
        }
    }

    /// API key kept out of the struct so we can swap UserDefaults → Keychain
    /// without breaking SwiftUI bindings on the rest of the settings.
    var hermesAPIKey: String {
        didSet {
            guard hermesAPIKey != oldValue else { return }
            defaults.set(hermesAPIKey, forKey: Keys.hermesAPIKey)
            NotificationCenter.default.post(name: .backendSettingsChanged, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawKind = defaults.string(forKey: Keys.backendKind)
        self.kind = rawKind.flatMap(BackendKind.init(rawValue:)) ?? .localLangGraph

        self.hermes = HermesSettings(
            baseURL: defaults.string(forKey: Keys.hermesBaseURL) ?? HermesSettings.default.baseURL,
            model:   defaults.string(forKey: Keys.hermesModel)   ?? HermesSettings.default.model
        )

        self.hermesAPIKey = defaults.string(forKey: Keys.hermesAPIKey) ?? ""
    }
}

extension Notification.Name {
    static let backendSettingsChanged = Notification.Name("wapo.backendSettingsChanged")
    static let openSettingsRequested  = Notification.Name("wapo.openSettingsRequested")
}
