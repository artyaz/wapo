//
//  WapoApp.swift
//  Wapo
//
//  Created by Artem Chmylenko on 28.03.2026.
//
//  Menu bar–only application. No dock icon, no main window.
//  All UI is presented through the FloatingPanel managed by AppDelegate.
//

import SwiftUI

@main
struct WapoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup — this is a menu bar–only application.
        // The FloatingPanel is managed entirely by AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
