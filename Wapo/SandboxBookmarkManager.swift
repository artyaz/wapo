//
//  SandboxBookmarkManager.swift
//  Wapo
//
//  Manages Security-Scoped Bookmarks for persistent folder access across restarts.
//  Presents NSOpenPanel for user authorization, then persists bookmarks in UserDefaults.
//

import AppKit

@Observable
final class SandboxBookmarkManager {

    private static let bookmarksKey = "com.artya.wapo.securityBookmarks"

    var authorizedPaths: [URL] = []

    init() {
        restoreBookmarks()
    }

    // MARK: - Request Folder Access

    func requestFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Grant Wapo access to a folder for file management"
        panel.prompt = "Authorize"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            saveBookmark(bookmarkData, for: url.path)
            authorizedPaths.append(url)
        } catch {
            print("Failed to create security-scoped bookmark: \(error)")
        }
    }

    // MARK: - Access Scoped Resource

    func accessScopedResource(at url: URL, operation: (URL) throws -> Void) rethrows {
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security-scoped resource: \(url.path)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        try operation(url)
    }

    // MARK: - Persistence

    private func saveBookmark(_ data: Data, for path: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        bookmarks[path] = data
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func restoreBookmarks() {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] else { return }

        for (_, data) in bookmarks {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if !isStale {
                    authorizedPaths.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
    }
}
