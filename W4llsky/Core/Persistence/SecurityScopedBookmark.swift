//
//  SecurityScopedBookmark.swift
//  W4llsky
//
//  Persistent file references across launches. Plain (non-security-scoped)
//  bookmarks — the app doesn't run under App Sandbox, so there's no Powerbox
//  grant to broker; normal file permissions are enough.
//

import Foundation

enum SecurityScopedBookmark {
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
