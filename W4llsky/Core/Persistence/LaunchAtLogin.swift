//
//  LaunchAtLogin.swift
//  W4llsky
//
//  SMAppService.mainApp needs no separate login-item helper bundle for this case.
//

import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can be silently refused by the system; there's nothing to recover from,
    /// just don't crash and let the menu state reflect whatever `status` ends up being.
    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Intentionally silent: next menu open re-reads `status` and shows the real state.
        }
    }
}
