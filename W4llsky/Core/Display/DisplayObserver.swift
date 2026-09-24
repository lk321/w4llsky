//
//  DisplayObserver.swift
//  W4llsky
//
//  Watches NSApplication.didChangeScreenParametersNotification — the one
//  umbrella notification covering connect/disconnect/resolution/scale/main
//  display/arrangement/mirroring. No polling.
//

import AppKit

@MainActor
final class DisplayObserver {
    private(set) var current: [DisplaySnapshot] = []
    var onChange: (([DisplaySnapshot]) -> Void)?

    private var token: NSObjectProtocol?

    init() {
        refresh(notify: false)
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread; the notification
            // closure's type isn't @MainActor-annotated, so tell the compiler explicitly.
            MainActor.assumeIsolated {
                self?.refresh(notify: true)
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Re-resolves a snapshot id back to a live NSScreen. Always queries fresh —
    /// NSScreen references are never cached across a screen-parameters change.
    func screen(forID id: String) -> NSScreen? {
        NSScreen.screens.first { DisplaySnapshotFactory.snapshot(for: $0).id == id }
    }

    /// Re-reads the displays now instead of waiting for the notification, which can land
    /// after a wake that already needs the new list.
    func resync() {
        current = NSScreen.screens.map(DisplaySnapshotFactory.snapshot)
    }

    /// macOS sends this notification in bursts — several per arrangement change, and
    /// more of them the more displays are attached — and most carry no actual change.
    /// The snapshot is Equatable precisely so the reconcile behind it can be skipped.
    private func refresh(notify: Bool) {
        let snapshots = NSScreen.screens.map(DisplaySnapshotFactory.snapshot)
        guard snapshots != current || !notify else { return }
        current = snapshots
        if notify {
            onChange?(current)
        }
    }
}

// claude --resume 18558e5c-f5f2-4d4f-914d-00525c238b64
